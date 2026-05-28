-- 0003_files_table.sql — Phase 2, migration 3.
--
-- Registry for every binary stored in Cloudflare R2. The R2 bucket
-- holds the bytes; this table holds the metadata + access-control
-- layer. One row per (objectKey) → project / photo / kind.
--
-- Object key layout: <projectId>/<photoId>/<kind>
--   kind ∈ {'photo','thumb','markup_png','markup_drawing','plan'}
--
-- The server records a row here after every successful client-side
-- PUT to R2 (via the commit endpoint). Reads via the photo redirect
-- endpoints look up `files` to confirm the object exists + the caller
-- has access to its project before issuing a presigned GET URL.

create table public.files (
  object_key       text primary key,
  project_id       uuid not null references public.projects (id) on delete cascade,
  photo_id         uuid not null,
  kind             text not null check (kind in (
                     'photo', 'thumb', 'markup_png', 'markup_drawing', 'plan'
                   )),
  size_bytes       bigint not null check (size_bytes > 0),
  sha256           text,
  uploaded_by      uuid references auth.users (id) on delete set null,
  uploaded_at      timestamptz not null default now()
);

-- Lookup by project: powers the photo-list endpoint + sync-check
-- batch query.
create index files_project_id_idx on public.files (project_id);

-- Lookup by photo: powers the per-photo image / thumb redirects.
create index files_photo_id_idx on public.files (photo_id);

-- RLS defense-in-depth. The server uses the secret key and bypasses
-- RLS, but if a client somehow ends up reading this table directly
-- via the publishable key, restrict them to rows for projects they
-- own.
create policy "Users can read files for own projects"
  on public.files for select
  using (
    exists (
      select 1 from public.projects p
      where p.id = files.project_id
        and p.owner_id = auth.uid()
    )
  );
