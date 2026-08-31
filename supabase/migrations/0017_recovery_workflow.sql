-- Immutable evidence versions. No automatic retention/garbage collection.
-- Deploy before the server; require updated upload clients afterward.
alter table public.files add column is_current boolean not null default true;
alter table public.files add column immutable boolean not null default false;

create function public.manifest_assets(m jsonb)
returns table(entity_id uuid, kind text, filename text)
language sql immutable set search_path = public, pg_temp as $$
  select (p->>'id')::uuid, k.kind, p->>k.field
  from jsonb_array_elements(coalesce(m->'photos','[]') || coalesce(m->'trashedPhotos','[]')) p
  cross join (values ('photo','imageFilename'), ('thumb','thumbnailFilename'),
    ('markup_png','markupOverlayFilename'), ('markup_drawing','markupDrawingFilename')) k(kind,field)
  where nullif(p->>k.field,'') is not null
  union
  select (p->>'id')::uuid, 'plan', p->>'imageFilename'
  from jsonb_array_elements(coalesce(m->'floorPlans','[]')) p where nullif(p->>'imageFilename','') is not null;
$$;
-- Match legacy records only to the current manifest. They remain non-immutable.
update public.files f set source_filename = a.filename
from public.projects p, lateral public.manifest_assets(p.manifest) a
where f.project_id=p.id and f.photo_id=a.entity_id and f.kind=a.kind and f.source_filename is null;
-- Existing duplicate versioned tuples are conservatively left non-restorable.
with ranked as (select object_key,row_number() over(partition by project_id,photo_id,kind,source_filename order by uploaded_at desc,object_key desc) n from public.files)
update public.files f set is_current=false from ranked r where f.object_key=r.object_key and r.n>1;
create unique index files_current_asset on public.files(project_id,photo_id,kind,source_filename) where is_current;

create view public.current_project_files with (security_invoker=true) as
select f.* from public.files f join public.projects p on p.id=f.project_id
where f.is_current and exists (select 1 from public.manifest_assets(p.manifest) a
  where a.entity_id=f.photo_id and a.kind=f.kind and a.filename=f.source_filename);
grant select on public.current_project_files to service_role;

create table public.project_versions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  revision text not null,
  manifest jsonb not null,
  assets jsonb not null,
  created_at timestamptz not null default now()
);
create index project_versions_project_time on public.project_versions(project_id,created_at desc);
alter table public.project_versions enable row level security;
grant all on public.project_versions to service_role;

create function public.snapshot_assets(pid uuid, m jsonb) returns jsonb
language sql stable set search_path=public,pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('entityId',a.entity_id,'kind',a.kind,'filename',a.filename,
    'objectKey',f.object_key,'immutable',coalesce(f.immutable,false),'sizeBytes',f.size_bytes) order by a.entity_id,a.kind,a.filename), '[]')
  from public.manifest_assets(m) a left join public.files f
    on f.project_id=pid and f.photo_id=a.entity_id and f.kind=a.kind
    and f.source_filename=a.filename and f.is_current;
$$;
create function public.capture_project_version() returns trigger
language plpgsql set search_path=public,pg_temp as $$ begin
  insert into public.project_versions(project_id,revision,manifest,assets)
  values(new.id,new.revision,new.manifest,public.snapshot_assets(new.id,new.manifest));
  return new;
end $$;
create trigger capture_project_version after insert or update of manifest,revision on public.projects
for each row execute function public.capture_project_version();
insert into public.project_versions(project_id,revision,manifest,assets,created_at)
select id,revision,manifest,public.snapshot_assets(id,manifest),updated_at from public.projects;

create function public.protect_project_version() returns trigger
language plpgsql set search_path=public,pg_temp as $$ begin
  if tg_op='UPDATE' or exists(select 1 from public.projects where id=old.project_id) then
    raise exception 'Historical versions are immutable' using errcode='23514';
  end if;
  return old;
end $$;
create trigger protect_project_version before update or delete on public.project_versions
for each row execute function public.protect_project_version();
create function public.protect_file_evidence() returns trigger
language plpgsql set search_path=public,pg_temp as $$ begin
  if tg_op='DELETE' then
    if exists(select 1 from public.projects where id=old.project_id) then
      raise exception 'Evidence retained until project is permanently deleted' using errcode='23514';
    end if;
    return old;
  end if;
  if (to_jsonb(new)-'is_current'-'uploaded_by') is distinct from (to_jsonb(old)-'is_current'-'uploaded_by') then
    raise exception 'Registered evidence is immutable' using errcode='23514';
  end if;
  return new;
end $$;
create trigger protect_file_evidence before update or delete on public.files
for each row execute function public.protect_file_evidence();

-- All write RPCs lock the parent first, serializing saves, uploads, restores,
-- edit-lock acquisition, and project deletion. Invoker rights; service-only.
create function public.project_write_guard(pid uuid, actor uuid, session text default null) returns jsonb
language plpgsql set search_path=public,pg_temp as $$
declare p public.projects; admin boolean; member_role text; l public.project_locks;
begin
  select * into p from public.projects where id=pid for update;
  if not found then return jsonb_build_object('error','not_found'); end if;
  select is_admin into admin from public.profiles where id=actor;
  select role into member_role from public.project_members where project_id=pid and user_id=actor;
  if not coalesce(admin,false) and p.owner_id<>actor and member_role is null then return jsonb_build_object('error','not_found'); end if;
  if not coalesce(admin,false) and p.owner_id<>actor and member_role<>'editor' then return jsonb_build_object('error','forbidden'); end if;
  select * into l from public.project_locks where project_id=pid;
  if found and l.expires_at>clock_timestamp() and (l.user_id<>actor or
    (l.client_session is not null and l.client_session is distinct from session)) then
    return jsonb_build_object('error','locked');
  end if;
  return jsonb_build_object('ok',true,'owner',p.owner_id=actor,'admin',coalesce(admin,false));
end $$;

create function public.cas_project(pid uuid, actor uuid, expected text, next_revision text, body jsonb, session text default null) returns jsonb
language plpgsql set search_path=public,pg_temp as $$
declare p public.projects; guard jsonb; changed integer;
begin
  if lower(body->>'id')<>pid::text then return jsonb_build_object('error','bad_request'); end if;
  if expected is null then
    insert into public.projects(id,owner_id,name,manifest,manifest_schema_version,revision)
    values(pid,actor,body->>'name',body,(body->>'manifestSchemaVersion')::int,next_revision) on conflict(id) do nothing;
    get diagnostics changed=row_count;
    if changed=1 then return jsonb_build_object('ok',true,'revision',next_revision); end if;
    return jsonb_build_object('error','revision_mismatch');
  end if;
  guard=public.project_write_guard(pid,actor,session);
  if guard ? 'error' then return guard; end if;
  select * into p from public.projects where id=pid;
  if p.revision<>expected then return jsonb_build_object('error','revision_mismatch'); end if;
  if coalesce((p.manifest->>'isFrozen')::boolean,false) and jsonb_strip_nulls((jsonb_build_object('inspectionChecklist','[]'::jsonb,'inspectionSessions','[]'::jsonb,'isDeleted',false)||p.manifest)-'isFrozen') is distinct from jsonb_strip_nulls((jsonb_build_object('inspectionChecklist','[]'::jsonb,'inspectionSessions','[]'::jsonb,'isDeleted',false)||body)-'isFrozen') then
    return jsonb_build_object('error','project_frozen');
  end if;
  if coalesce((p.manifest->>'isFrozen')::boolean,false)<>coalesce((body->>'isFrozen')::boolean,false)
     and not ((guard->>'owner')::boolean or (guard->>'admin')::boolean) then return jsonb_build_object('error','forbidden'); end if;
  update public.projects set manifest=body,name=body->>'name',manifest_schema_version=(body->>'manifestSchemaVersion')::int,revision=next_revision where id=pid;
  return jsonb_build_object('ok',true,'revision',next_revision);
end $$;

create function public.commit_project_file(pid uuid, actor uuid, entity uuid, file_kind text, filename text,
  key text, bytes bigint, hash text default null, session text default null) returns jsonb
language plpgsql set search_path=public,pg_temp as $$
declare guard jsonb; existing public.files; p public.projects; captured jsonb;
begin
  guard=public.project_write_guard(pid,actor,session);
  if guard ? 'error' then return guard; end if;
  if (select coalesce((manifest->>'isFrozen')::boolean,false) from public.projects where id=pid) then return jsonb_build_object('error','project_frozen'); end if;
  if filename is null or filename='' or key !~ ('^'||pid::text||'/'||entity::text||'/'||file_kind||'/[0-9a-f-]{36}$') then
    return jsonb_build_object('error','bad_request'); end if;
  select * into existing from public.files where object_key=key;
  if found then
    if existing.project_id<>pid or existing.photo_id<>entity or existing.kind<>file_kind or existing.source_filename<>filename or existing.size_bytes<>bytes or existing.sha256 is distinct from hash then
      return jsonb_build_object('error','object_conflict');
    end if;
    -- A stale upload retry must never undo a later replacement/restore.
    return jsonb_build_object('ok',true);
  end if;
  update public.files set is_current=false where project_id=pid and photo_id=entity and kind=file_kind and source_filename=filename and is_current;
  insert into public.files(object_key,project_id,photo_id,kind,source_filename,size_bytes,sha256,uploaded_by,immutable)
  values(key,pid,entity,file_kind,filename,bytes,hash,actor,true);
  -- A completed upload gets a recovery checkpoint without a metadata edit.
  -- Large initial uploads checkpoint only when the final required file lands.
  select * into p from public.projects where id=pid;
  captured=public.snapshot_assets(pid,p.manifest);
  if not exists(select 1 from jsonb_array_elements(captured) a where a->>'objectKey' is null or not (a->>'immutable')::boolean)
    and not exists(select 1 from public.project_versions where project_id=pid and revision=p.revision and assets=captured) then
    insert into public.project_versions(project_id,revision,manifest,assets) values(pid,p.revision,p.manifest,captured);
  end if;
  return jsonb_build_object('ok',true);
end $$;

create function public.restore_project_version(pid uuid, actor uuid, version_id uuid, expected text,
 next_revision text, verified_keys jsonb, session text default null) returns jsonb
language plpgsql set search_path=public,pg_temp as $$
declare guard jsonb; p public.projects; v public.project_versions; a jsonb;
begin
  guard=public.project_write_guard(pid,actor,session);
  if guard ? 'error' then return guard; end if;
  select * into p from public.projects where id=pid;
  if p.revision<>expected then return jsonb_build_object('error','revision_mismatch'); end if;
  if coalesce((p.manifest->>'isFrozen')::boolean,false) then return jsonb_build_object('error','project_frozen'); end if;
  select * into v from public.project_versions where project_id=pid and id=version_id;
  if not found then return jsonb_build_object('error','not_found'); end if;
  if coalesce((v.manifest->>'isFrozen')::boolean,false) and not ((guard->>'owner')::boolean or (guard->>'admin')::boolean) then
    return jsonb_build_object('error','forbidden'); end if;
  -- Check every reference before any pointer changes; incomplete metadata history remains readable.
  for a in select value from jsonb_array_elements(v.assets) loop
    if not coalesce((a->>'immutable')::boolean,false) or a->>'objectKey' is null
      or not coalesce(verified_keys ? (a->>'objectKey'),false)
      or not exists(select 1 from public.files f where f.object_key=a->>'objectKey' and f.project_id=pid
        and f.photo_id=(a->>'entityId')::uuid and f.kind=a->>'kind' and f.source_filename=a->>'filename'
        and f.immutable and f.size_bytes=(a->>'sizeBytes')::bigint) then
      return jsonb_build_object('error','assets_unavailable');
    end if;
  end loop;
  -- Do not allow a missing/malformed snapshot reference set to pass vacuously.
  if exists(select 1 from public.manifest_assets(v.manifest) m where not exists(
      select 1 from jsonb_array_elements(v.assets) asset where (asset->>'entityId')::uuid=m.entity_id and asset->>'kind'=m.kind and asset->>'filename'=m.filename)) then
    return jsonb_build_object('error','assets_unavailable'); end if;
  update public.files set is_current=false where project_id=pid and is_current;
  update public.files set is_current=true where project_id=pid and object_key in (select asset->>'objectKey' from jsonb_array_elements(v.assets) asset);
  update public.projects set manifest=v.manifest,name=v.manifest->>'name',manifest_schema_version=(v.manifest->>'manifestSchemaVersion')::int,revision=next_revision where id=pid;
  return jsonb_build_object('ok',true,'revision',next_revision,'project',v.manifest);
end $$;

create function public.lock_project_parent() returns trigger language plpgsql set search_path=public,pg_temp as $$ begin
  perform 1 from public.projects where id=coalesce(new.project_id,old.project_id) for update;
  if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger lock_project_parent before insert or update or delete on public.project_locks for each row execute function public.lock_project_parent();
create function public.acquire_project_lock(pid uuid, actor uuid, email text, client_kind text, session text default null) returns jsonb
language plpgsql set search_path=public,pg_temp as $$
declare guard jsonb; l public.project_locks;
begin
  guard=public.project_write_guard(pid,actor,session);
  if guard ? 'error' then return guard; end if;
  if (select coalesce((manifest->>'isFrozen')::boolean,false) from public.projects where id=pid) then return jsonb_build_object('error','project_frozen'); end if;
  insert into public.project_locks(project_id,user_id,user_email,client,client_session,acquired_at,last_heartbeat,expires_at)
  values(pid,actor,email,client_kind,session,clock_timestamp(),clock_timestamp(),clock_timestamp()+interval '10 minutes')
  on conflict(project_id) do update set user_id=excluded.user_id,user_email=excluded.user_email,client=excluded.client,
    client_session=excluded.client_session,acquired_at=excluded.acquired_at,last_heartbeat=excluded.last_heartbeat,expires_at=excluded.expires_at returning * into l;
  return jsonb_build_object('ok',true,'lock',to_jsonb(l));
end $$;

create table public.user_workflow(user_id uuid primary key references auth.users(id) on delete cascade,
 library jsonb not null, revision text not null, updated_at timestamptz not null default now());
alter table public.user_workflow enable row level security;
grant all on public.user_workflow to service_role;
create function public.cas_user_workflow(actor uuid, body jsonb, expected text, next_revision text) returns jsonb
language plpgsql set search_path=public,pg_temp as $$ declare changed integer; begin
  if expected is null then
    insert into public.user_workflow(user_id,library,revision) values(actor,body,next_revision) on conflict(user_id) do nothing;
  else update public.user_workflow set library=body,revision=next_revision,updated_at=now() where user_id=actor and revision=expected;
  end if;
  get diagnostics changed=row_count;
  if changed=0 then return jsonb_build_object('error','revision_mismatch'); end if;
  return jsonb_build_object('ok',true,'revision',next_revision);
end $$;

create function public.search_project_evidence(actor uuid, term text, from_date text, to_date text,
 favorites boolean, page_offset integer, page_limit integer) returns jsonb
language sql stable set search_path=public,pg_temp as $$
with accessible as (
 select p.* from public.projects p where coalesce(p.manifest->>'isDeleted','false')<>'true' and
 (p.owner_id=actor or exists(select 1 from public.profiles where id=actor and is_admin)
 or exists(select 1 from public.project_members where project_id=p.id and user_id=actor))
), hits as (
 select p.id,p.name,p.manifest->>'projectAddress' address,ph.value photo,coalesce(ph.value->>'timestamp',p.created_at::text) stamp
 from accessible p left join lateral jsonb_array_elements(coalesce(p.manifest->'photos','[]')) ph on true
 where (not favorites or coalesce((ph.value->>'isFavorite')::boolean,false))
 and (from_date is null or left(coalesce(ph.value->>'timestamp',p.created_at::text),10)>=from_date)
 and (to_date is null or left(coalesce(ph.value->>'timestamp',p.created_at::text),10)<=to_date)
 and (term='' or position(lower(term) in lower(concat_ws(' ',p.name,p.manifest->>'projectAddress',
 ph.value->>'userCaption',ph.value->>'userObservation',ph.value->>'aiDescription',ph.value->>'aiObservation',ph.value->'tags'))) > 0)
), page as (select * from hits order by stamp desc,id,photo->>'id' offset greatest(page_offset,0) limit least(page_limit,100)+1)
select coalesce(jsonb_agg(jsonb_build_object('projectId',id,'projectName',name,'projectAddress',address,
 'photoId',photo->>'id','sequenceNumber',(photo->>'sequenceNumber')::int,'caption',coalesce(photo->>'userCaption',photo->>'aiDescription'),'timestamp',stamp)), '[]') from page;
$$;

-- PostgreSQL grants EXECUTE to PUBLIC by default. Restrict every new function.
do $$ declare f record; begin
 for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace
 and proname in ('manifest_assets','snapshot_assets','capture_project_version','protect_project_version','protect_file_evidence',
 'project_write_guard','cas_project','commit_project_file','restore_project_version','lock_project_parent','acquire_project_lock','cas_user_workflow','search_project_evidence') loop
 execute format('revoke all on function %s from public, anon, authenticated',f.signature);
 execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;

create function public.project_health_snapshot(pid uuid) returns jsonb
language sql stable set search_path=public,pg_temp as $$
 select jsonb_build_object('revision',revision,'assets',public.snapshot_assets(id,manifest)) from public.projects where id=pid;
$$;
revoke all on function public.project_health_snapshot(uuid) from public,anon,authenticated;
grant execute on function public.project_health_snapshot(uuid) to service_role;

create function public.delete_project_evidence(pid uuid,actor uuid,expected text,session text default null) returns jsonb
language plpgsql set search_path=public,pg_temp as $$ declare guard jsonb; p public.projects; keys jsonb; begin
 guard=public.project_write_guard(pid,actor,session);
 if guard ? 'error' then return guard; end if;
 select * into p from public.projects where id=pid;
 if p.revision<>expected then return jsonb_build_object('error','revision_mismatch'); end if;
 if coalesce((p.manifest->>'isFrozen')::boolean,false) then return jsonb_build_object('error','project_frozen'); end if;
 if not coalesce((p.manifest->>'isDeleted')::boolean,false) then return jsonb_build_object('error','precondition_failed'); end if;
 select coalesce(jsonb_agg(object_key),'[]') into keys from public.files where project_id=pid;
 delete from public.projects where id=pid;
 return jsonb_build_object('ok',true,'objectKeys',keys);
end $$;
revoke all on function public.delete_project_evidence(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.delete_project_evidence(uuid,uuid,text,text) to service_role;

-- Listing metadata must not transfer up to 100 large manifests to the API.
create function public.list_project_versions(pid uuid) returns jsonb
language sql stable set search_path=public,pg_temp as $$
 select coalesce(jsonb_agg(summary order by created_at desc,id desc),'[]') from (
  select id,created_at,jsonb_build_object('id',id,'revision',revision,'createdAt',created_at,
   'photoCount',jsonb_array_length(coalesce(manifest->'photos','[]')),
   'planCount',jsonb_array_length(coalesce(manifest->'floorPlans','[]')),
   'restorable',not exists(select 1 from jsonb_array_elements(assets) a where a->>'objectKey' is null or not coalesce((a->>'immutable')::boolean,false)),
   'missingAssetCount',(select count(*) from jsonb_array_elements(assets) a where a->>'objectKey' is null or not coalesce((a->>'immutable')::boolean,false))) summary
  from public.project_versions where project_id=pid order by created_at desc,id desc limit 100
 ) v;
$$;
revoke all on function public.list_project_versions(uuid) from public,anon,authenticated;
grant execute on function public.list_project_versions(uuid) to service_role;
