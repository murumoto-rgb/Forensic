-- Upload leases bind the presign request to the later registry commit.
create table public.pending_uploads (
  object_key text primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  actor_id uuid not null references auth.users(id) on delete cascade,
  entity_id uuid not null,
  kind text not null,
  source_filename text not null,
  declared_sha256 text,
  size_bytes bigint not null check (size_bytes > 0),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  revoked_at timestamptz
);
create index pending_uploads_expiry on public.pending_uploads(expires_at);
alter table public.pending_uploads enable row level security;
grant all on public.pending_uploads to service_role;

create function public.issue_upload_receipt(
  pid uuid, actor uuid, entity uuid, file_kind text, filename text,
  key text, bytes bigint, hash text, ttl_seconds integer, session text default null
) returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare guard jsonb;
begin
  guard := public.project_write_guard(pid, actor, session);
  if guard ? 'error' then return guard; end if;
  if coalesce((select (manifest->>'isFrozen')::boolean from public.projects where id=pid),false)
     then return jsonb_build_object('error','project_frozen'); end if;
  if key !~ ('^'||pid::text||'/'||entity::text||'/'||file_kind||'/[0-9a-f-]{36}$')
     or filename is null or filename='' or bytes is null or bytes <= 0
     or ttl_seconds is null or ttl_seconds < 1 or ttl_seconds > 900
     or file_kind not in ('photo','thumb','markup_png','markup_drawing','plan') then
    return jsonb_build_object('error','bad_request');
  end if;
  insert into public.pending_uploads(object_key,project_id,actor_id,entity_id,kind,source_filename,declared_sha256,size_bytes,expires_at)
    values(key,pid,actor,entity,file_kind,filename,hash,bytes,clock_timestamp()+make_interval(secs=>ttl_seconds));
  return jsonb_build_object('ok',true,'expires_at',(select expires_at from public.pending_uploads where object_key=key));
end $$;

create function public.commit_upload_receipt(
  pid uuid, actor uuid, entity uuid, file_kind text, filename text,
  key text, bytes bigint, hash text, session text default null
) returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare r public.pending_uploads; result jsonb; guard jsonb;
begin
  -- Same order as freeze/revocation: project first, then pending_uploads.
  -- Authorize even consumed retries; revoked members cannot replay receipts.
  guard := public.project_write_guard(pid, actor, session);
  if guard ? 'error' then return guard; end if;
  select * into r from public.pending_uploads where object_key=key for update;
  if found and r.revoked_at is not null then return jsonb_build_object('error','upload_receipt_invalid'); end if;
  if not found or r.project_id is distinct from pid or r.actor_id is distinct from actor or r.entity_id is distinct from entity
     or r.kind is distinct from file_kind or r.source_filename is distinct from filename or r.size_bytes is distinct from bytes
     or r.declared_sha256 is distinct from hash then
    return jsonb_build_object('error','upload_receipt_invalid');
  end if;
  -- Exact authorized replay is a no-op even after its original expiry or a
  -- later freeze; it must not resurrect a replaced current-file pointer.
  if r.consumed_at is not null then return jsonb_build_object('ok',true); end if;
  if r.expires_at <= clock_timestamp() then return jsonb_build_object('error','upload_receipt_expired'); end if;
  result := public.commit_project_file(pid,actor,entity,file_kind,filename,key,bytes,hash,session);
  if result ? 'error' then return result; end if;
  update public.pending_uploads set consumed_at=clock_timestamp() where object_key=key;
  return result;
end $$;

create function public.revoke_project_upload_receipts() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
  if coalesce((new.manifest->>'isFrozen')::boolean,false)
     and not coalesce((old.manifest->>'isFrozen')::boolean,false) then
    update public.pending_uploads set revoked_at=clock_timestamp()
      where project_id=new.id and consumed_at is null and revoked_at is null;
  end if;
  return new;
end $$;
create trigger revoke_project_upload_receipts
  after update of manifest on public.projects
  for each row execute function public.revoke_project_upload_receipts();

do $$ declare f record; begin
  for f in select oid::regprocedure as signature from pg_proc
    where pronamespace='public'::regnamespace and proname in ('issue_upload_receipt','commit_upload_receipt','revoke_project_upload_receipts') loop
    execute format('revoke all on function %s from public, anon, authenticated',f.signature);
    execute format('grant execute on function %s to service_role',f.signature);
  end loop;
end $$;
