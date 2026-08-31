-- Small durable limits for an owner-operated app. No service credentials or
-- billing system in clients. Counts include failed attempts to bound retry loops.
create table public.owner_work_budgets (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  kind text not null check(kind in ('ai','export')),
  calls integer not null default 0 check(calls >= 0),
  primary key(user_id, day, kind)
);
create table public.ai_work_leases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null
);
create index ai_work_leases_owner_expiry on public.ai_work_leases(user_id, expires_at);
alter table public.owner_work_budgets enable row level security;
alter table public.ai_work_leases enable row level security;
revoke all on public.owner_work_budgets, public.ai_work_leases from public, anon, authenticated;
grant all on public.owner_work_budgets, public.ai_work_leases to service_role;

create function public.reserve_ai_work(actor uuid, daily_limit integer, concurrent_limit integer)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := (now() at time zone 'UTC')::date; used integer; active integer; lease uuid;
begin
  if daily_limit < 1 or concurrent_limit < 1 then raise exception 'invalid_limits'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text, 0));
  insert into owner_work_budgets(user_id,day,kind) values(actor,today,'ai') on conflict do nothing;
  select calls into used from owner_work_budgets where user_id=actor and day=today and kind='ai' for update;
  delete from ai_work_leases where user_id=actor and expires_at <= now();
  select count(*) into active from ai_work_leases where user_id=actor;
  if used >= daily_limit then return jsonb_build_object('ok',false,'reason','daily','remaining',0); end if;
  if active >= concurrent_limit then return jsonb_build_object('ok',false,'reason','concurrency','remaining',daily_limit-used); end if;
  update owner_work_budgets set calls=calls+1 where user_id=actor and day=today and kind='ai';
  insert into ai_work_leases(user_id,expires_at) values(actor,now()+interval '5 minutes') returning id into lease;
  return jsonb_build_object('ok',true,'lease',lease,'remaining',daily_limit-used-1);
end $$;
create function public.release_ai_work(actor uuid, lease uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  delete from ai_work_leases where user_id=actor and id=lease;
$$;
revoke all on function public.reserve_ai_work(uuid,integer,integer), public.release_ai_work(uuid,uuid) from public, anon, authenticated;
grant execute on function public.reserve_ai_work(uuid,integer,integer), public.release_ai_work(uuid,uuid) to service_role;

-- Serialize both legacy and unified queue admissions. A job's own durable
-- status releases capacity; no in-memory semaphore is lost on a restart.
create function public.limit_export_queue()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare actor uuid; active integer; total_active integer; used integer; today date := (now() at time zone 'UTC')::date;
begin
  if new.status not in ('queued','running') then return new; end if;
  actor := case when tg_table_name='pdf_export_jobs' then (to_jsonb(new)->>'requested_by')::uuid else (to_jsonb(new)->>'created_by')::uuid end;
  perform pg_advisory_xact_lock(68432718);
  select count(*),count(*) filter(where uid=actor) into total_active,active from (
    select requested_by uid from pdf_export_jobs where status in ('queued','running')
    union all select created_by from project_exports where status in ('queued','running')
  ) jobs;
  if active >= 2 or total_active >= 5 then raise exception 'export_queue_full' using errcode='P0001'; end if;
  insert into owner_work_budgets(user_id,day,kind) values(actor,today,'export') on conflict do nothing;
  select calls into used from owner_work_budgets where user_id=actor and day=today and kind='export' for update;
  if used >= 50 then raise exception 'export_daily_limit' using errcode='P0001'; end if;
  update owner_work_budgets set calls=calls+1 where user_id=actor and day=today and kind='export';
  return new;
end $$;
revoke all on function public.limit_export_queue() from public, anon, authenticated;
create trigger limit_pdf_export_queue before insert on public.pdf_export_jobs
  for each row execute function public.limit_export_queue();
create trigger limit_project_export_queue before insert on public.project_exports
  for each row execute function public.limit_export_queue();
