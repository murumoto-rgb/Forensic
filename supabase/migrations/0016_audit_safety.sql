-- 0016_audit_safety.sql — close audit findings F01, F02 and F09.

-- RLS must be explicit in migration history.  The original tables relied
-- on a project-level automatic-RLS setting that is not present on a fresh
-- database.
alter table public.profiles enable row level security;
alter table public.projects enable row level security;
alter table public.files enable row level security;
alter table public.files add column if not exists source_filename text;

-- A profile may change its display name, but never its authorization flag.
revoke update on table public.profiles from authenticated;
grant update (display_name) on table public.profiles to authenticated;
drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own display name"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- The server uses service_role for these RPCs; clients have no direct
-- mutation grant on shared configuration or preference rows.
create or replace function public.cas_app_config(
  p_key text,
  p_value jsonb,
  p_expected_revision text,
  p_new_revision text,
  p_updated_by uuid
)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  current_revision text;
  changed integer;
begin
  if p_expected_revision is null then
    insert into public.app_config (key, value, revision, updated_by)
      values (p_key, p_value, p_new_revision, p_updated_by)
      on conflict (key) do nothing;
    get diagnostics changed = row_count;
    if changed = 1 then
      return jsonb_build_object('ok', true, 'revision', p_new_revision);
    end if;
  else
    update public.app_config
      set value = p_value, revision = p_new_revision, updated_by = p_updated_by
      where key = p_key and revision = p_expected_revision;
    get diagnostics changed = row_count;
    if changed = 1 then
      return jsonb_build_object('ok', true, 'revision', p_new_revision);
    end if;
  end if;

  select revision into current_revision from public.app_config where key = p_key;
  return jsonb_build_object('ok', false, 'current_revision', current_revision);
end;
$$;

create or replace function public.cas_user_prefs(
  p_user_id uuid,
  p_prefs jsonb,
  p_expected_revision text,
  p_new_revision text
)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  current_revision text;
  changed integer;
begin
  if p_expected_revision is null then
    insert into public.user_prefs (user_id, prefs, revision)
      values (p_user_id, p_prefs, p_new_revision)
      on conflict (user_id) do nothing;
    get diagnostics changed = row_count;
    if changed = 1 then
      return jsonb_build_object('ok', true, 'revision', p_new_revision);
    end if;
  else
    update public.user_prefs
      set prefs = p_prefs, revision = p_new_revision
      where user_id = p_user_id and revision = p_expected_revision;
    get diagnostics changed = row_count;
    if changed = 1 then
      return jsonb_build_object('ok', true, 'revision', p_new_revision);
    end if;
  end if;

  select revision into current_revision from public.user_prefs where user_id = p_user_id;
  return jsonb_build_object('ok', false, 'current_revision', current_revision);
end;
$$;

revoke all on function public.cas_app_config(text, jsonb, text, text, uuid) from public, anon, authenticated;
revoke all on function public.cas_user_prefs(uuid, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.cas_app_config(text, jsonb, text, text, uuid) to service_role;
grant execute on function public.cas_user_prefs(uuid, jsonb, text, text) to service_role;
