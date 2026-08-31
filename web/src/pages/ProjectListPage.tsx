import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { MANIFEST_SCHEMA_VERSION, SearchFilterSchema, type Project } from "@forensic/shared";
import type { SearchFilter, SavedSearch, WorkflowLibrary } from "@forensic/shared";
import { signOutLocal } from "../lib/supabase";
import { api, ApiError, type ProjectListItem } from "../lib/api";

interface Props {
  session: Session;
}

/**
 * Project list page.
 *
 * Active projects show top; trashed projects below in a collapsible
 * section that auto-hides when empty. The list is read-only on click
 * (links into the workspace); structural changes go through the "+
 * New project" modal at the top of the page or the per-row Restore
 * button in the trashed section.
 *
 * Permanent deletion is **not** wired here yet — it needs a server
 * DELETE endpoint that also reaps the project's blobs in storage.
 * Tracked as a separate PR; for now restored projects can be re-
 * trashed but never disposed of from the web side.
 */
export function ProjectListPage({ session }: Props) {
  const [projects, setProjects] = useState<ProjectListItem[] | null>(null);
  const [trashedProjects, setTrashedProjects] =
    useState<ProjectListItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [trashedOpen, setTrashedOpen] = useState(false);
  const [creatingOpen, setCreatingOpen] = useState(false);
  // Build #6.17.1: surface admin pages from the project list header.
  // Non-admins see only the two non-gated links (Tag library + AI
  // rules) as today; admins also get Team, Branding, Prompt templates.
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const [adminMenuOpen, setAdminMenuOpen] = useState(false);
  const [searchFilter, setSearchFilter] = useState<SearchFilter>({ query: "", fromDate: null, toDate: null, favoritesOnly: false });
  const [searchHits, setSearchHits] = useState<import("@forensic/shared").ProjectSearchHit[]>([]);
  const [searchLoading, setSearchLoading] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [nextOffset, setNextOffset] = useState<number | null>(null);
  const [library, setLibrary] = useState<WorkflowLibrary | null>(null);
  const [libraryRevision, setLibraryRevision] = useState<string | null>(null);
  const [filterName, setFilterName] = useState("");
  const [libraryError, setLibraryError] = useState<string | null>(null);
  const [libraryBusy, setLibraryBusy] = useState(false);
  const libraryRequest = useRef(0);
  const libraryWriting = useRef(false);
  const searchRequest = useRef(0);

  useEffect(() => {
    let cancelled = false;
    api
      .getMe()
      .then((me) => {
        if (!cancelled) setIsAdmin(me.isAdmin);
      })
      .catch(() => {
        if (!cancelled) setIsAdmin(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const reload = useCallback(() => {
    setError(null);
    api
      .listProjects()
      .then((res) => setProjects(sortByName(res.projects)))
      .catch((e: unknown) => {
        if (e instanceof ApiError) {
          setError(`${e.errorCode}: ${e.message}`);
        } else {
          setError("Failed to load projects");
        }
      });
    api
      .listProjects({ trashed: true })
      .then((res) => setTrashedProjects(sortByName(res.projects)))
      .catch(() => {
        // Trash is a nice-to-have; don't surface its errors over the
        // active list. They'll come back on next refresh.
        setTrashedProjects([]);
      });
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  const loadLibrary = useCallback(async () => {
    const request = ++libraryRequest.current;
    setLibraryBusy(true); setLibraryError(null);
    try {
      const response = await api.getWorkflowLibrary();
      if (request === libraryRequest.current) { setLibrary(response.library); setLibraryRevision(response.revision); }
    } catch (error) {
      if (request === libraryRequest.current) setLibraryError(`Could not load saved filters: ${error instanceof Error ? error.message : "Request failed"}`);
    } finally { if (request === libraryRequest.current) setLibraryBusy(false); }
  }, []);
  useEffect(() => { void loadLibrary(); return () => { libraryRequest.current++; searchRequest.current++; }; }, [loadLibrary]);
  function updateFilter(filter: SearchFilter) {
    searchRequest.current++;
    setSearchFilter(filter); setSearchLoading(false); setSearchHits([]); setNextOffset(null); setSearchError(null);
  }
  async function runSearch(filter = searchFilter, offset = 0) {
    const request = ++searchRequest.current;
    const parsed = SearchFilterSchema.safeParse(filter);
    if (!parsed.success || (filter.fromDate && filter.toDate && filter.fromDate > filter.toDate)) {
      setSearchError("Enter valid calendar dates with From on or before To."); setSearchLoading(false); return;
    }
    setSearchLoading(true); setSearchError(null);
    try {
      const response = await api.searchProjects(parsed.data, offset);
      if (request !== searchRequest.current) return;
      setSearchHits(current => offset ? [...current, ...response.hits] : response.hits);
      setNextOffset(response.nextOffset);
    } catch (error) {
      if (request === searchRequest.current) setSearchError(error instanceof Error ? error.message : "Search failed");
    } finally { if (request === searchRequest.current) setSearchLoading(false); }
  }
  async function persistLibrary(next: WorkflowLibrary): Promise<boolean> {
    if (libraryWriting.current) return false;
    libraryWriting.current = true; setLibraryBusy(true); setLibraryError(null);
    try {
      const response = await api.putWorkflowLibrary({ library: next, expectedRevision: libraryRevision });
      setLibrary(next); setLibraryRevision(response.revision); return true;
    } catch (error) {
      setLibraryError(`Saved filters were not changed: ${error instanceof Error ? error.message : "Request failed"}. Refresh the library before retrying. Your filter name was kept.`); return false;
    } finally { libraryWriting.current = false; setLibraryBusy(false); }
  }
  async function saveSearch() {
    const name = filterName.trim(); if (!name || !library || libraryBusy) return;
    const parsed = SearchFilterSchema.safeParse(searchFilter);
    if (!parsed.success || (searchFilter.fromDate && searchFilter.toDate && searchFilter.fromDate > searchFilter.toDate)) { setSearchError("Enter a valid date range before saving this filter."); return; }
    const next = { ...library, savedSearches: [...library.savedSearches.filter(saved => saved.name !== name), { id: crypto.randomUUID(), name, filter: parsed.data }] };
    if (await persistLibrary(next)) setFilterName(value => value.trim() === name ? "" : value);
  }
  async function deleteSearch(saved: SavedSearch) {
    if (!library || libraryBusy) return;
    await persistLibrary({ ...library, savedSearches: library.savedSearches.filter(current => current.id !== saved.id) });
  }

  return (
    <div className="mx-auto max-w-3xl px-6 py-10">
      <header className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Projects</h1>
          <p className="text-xs text-neutral-500">{session.user.email}</p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setCreatingOpen(true)}
            className="rounded border border-blue-700 bg-blue-900/40 px-3 py-1 text-sm text-blue-200 hover:bg-blue-900/60"
          >
            + New project
          </button>
          <div className="relative">
            <button
              type="button"
              onClick={() => setAdminMenuOpen((o) => !o)}
              className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
              aria-haspopup="menu"
              aria-expanded={adminMenuOpen}
              title={
                isAdmin
                  ? "Shared libraries and report settings"
                  : "Shared libraries (non-admin views are read-only)"
              }
            >
              Libraries ▾
            </button>
            {adminMenuOpen && (
              <>
                <div
                  className="fixed inset-0 z-40"
                  onClick={() => setAdminMenuOpen(false)}
                />
                <div
                  role="menu"
                  className="absolute right-0 z-50 mt-1 w-56 overflow-hidden rounded border border-neutral-700 bg-neutral-900 shadow-2xl"
                >
                  <Link
                    to="/admin/tag-library"
                    role="menuitem"
                    onClick={() => setAdminMenuOpen(false)}
                    className="block px-3 py-2 text-sm text-neutral-200 hover:bg-neutral-800"
                  >
                    Tag library
                  </Link>
                  <Link
                    to="/admin/ai-rules"
                    role="menuitem"
                    onClick={() => setAdminMenuOpen(false)}
                    className="block px-3 py-2 text-sm text-neutral-200 hover:bg-neutral-800"
                  >
                    AI rules template
                  </Link>
                  <Link
                    to="/admin/ai-prompt-templates"
                    role="menuitem"
                    onClick={() => setAdminMenuOpen(false)}
                    className="block px-3 py-2 text-sm text-neutral-200 hover:bg-neutral-800"
                  >
                    AI prompt templates
                  </Link>
                  <Link
                    to="/admin/report-branding"
                    role="menuitem"
                    onClick={() => setAdminMenuOpen(false)}
                    className="block px-3 py-2 text-sm text-neutral-200 hover:bg-neutral-800"
                  >
                    Report branding
                  </Link>
                  {isAdmin && (
                    <Link
                      to="/admin/users"
                      role="menuitem"
                      onClick={() => setAdminMenuOpen(false)}
                      className="block border-t border-neutral-800 px-3 py-2 text-sm text-blue-200 hover:bg-blue-900/30"
                    >
                      Team &amp; access →
                    </Link>
                  )}
                </div>
              </>
            )}
          </div>
          <Link
            to="/settings"
            className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
            title="Account + AI preferences + diagnostics"
          >
            ⚙ Settings
          </Link>
          <button
            type="button"
            onClick={() => signOutLocal()}
            className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
          >
            Sign out
          </button>
        </div>
      </header>

      <section className="mb-8 rounded border border-neutral-800 bg-neutral-900/40 p-4">
        <h2 className="mb-3 text-sm font-medium text-neutral-200">Search all projects</h2>
        <div className="flex flex-wrap items-end gap-2">
          <label className="flex flex-col gap-1 text-xs text-neutral-400">Query<input value={searchFilter.query} onChange={(e) => updateFilter({ ...searchFilter, query: e.target.value })} className="rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100" placeholder="project, caption, address" /></label>
          <label className="flex flex-col gap-1 text-xs text-neutral-400">From<input type="date" value={searchFilter.fromDate ?? ""} onChange={(e) => updateFilter({ ...searchFilter, fromDate: e.target.value || null })} className="rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100" /></label>
          <label className="flex flex-col gap-1 text-xs text-neutral-400">To<input type="date" value={searchFilter.toDate ?? ""} onChange={(e) => updateFilter({ ...searchFilter, toDate: e.target.value || null })} className="rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100" /></label>
          <label className="flex items-center gap-2 pb-2 text-xs text-neutral-300"><input type="checkbox" checked={searchFilter.favoritesOnly} onChange={(e) => updateFilter({ ...searchFilter, favoritesOnly: e.target.checked })} />Favorites only</label>
          <button type="button" onClick={() => void runSearch()} disabled={searchLoading} className="rounded border border-blue-700 px-3 py-1.5 text-sm text-blue-200 disabled:opacity-50">{searchLoading ? "Searching…" : "Search"}</button>
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-2"><input value={filterName} onChange={(e) => setFilterName(e.target.value)} aria-label="Filter name" placeholder="Name this filter" className="rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-xs text-neutral-100" /><button type="button" onClick={() => void saveSearch()} disabled={!filterName.trim() || !library || libraryBusy} className="rounded border border-neutral-700 px-2 py-1 text-xs text-neutral-200 disabled:opacity-50">Save filter</button>{library?.savedSearches.map((s) => <span key={s.id} className="inline-flex items-center gap-1 rounded border border-neutral-800 px-2 py-1 text-xs"><button type="button" onClick={() => { updateFilter(s.filter); void runSearch(s.filter); }}>{s.name}</button><button type="button" aria-label={`Delete ${s.name}`} disabled={libraryBusy} onClick={() => void deleteSearch(s)} className="text-red-300">×</button></span>)}</div>
        {libraryError && <div role="alert" className="mt-3 text-xs text-red-300">{libraryError}</div>}
        <button type="button" onClick={() => void loadLibrary()} disabled={libraryBusy} className="mt-2 text-xs text-blue-200">{libraryBusy ? "Loading filter library…" : "Refresh saved filters"}</button>
        {searchError && <div role="alert" className="mt-3 text-xs text-red-300">{searchError}</div>}
        {searchHits.length > 0 && <div className="mt-4 space-y-1">{searchHits.map((h) => <Link key={`${h.projectId}-${h.photoId ?? "project"}-${h.timestamp}`} to={`/projects/${h.projectId}/photos`} className="block rounded border border-neutral-800 px-3 py-2 text-xs hover:bg-neutral-800"><span className="font-medium text-neutral-100">{h.projectName}</span>{h.projectAddress && <span className="ml-2 text-neutral-500">{h.projectAddress}</span>}{h.caption && <span className="ml-2 text-neutral-300">{h.caption}</span>}</Link>)}{nextOffset !== null && <button type="button" onClick={() => void runSearch(searchFilter, nextOffset)} disabled={searchLoading} className="mt-2 rounded border border-neutral-700 px-2 py-1 text-xs">Load more</button>}</div>}
        {!searchLoading && searchHits.length === 0 && <div className="mt-3 text-xs text-neutral-500">No search results yet.</div>}
      </section>

      {error && (
        <div className="mb-6 rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          {error}
        </div>
      )}

      {projects === null && !error && (
        <div className="text-sm text-neutral-500">Loading…</div>
      )}

      {projects !== null && projects.length === 0 && (
        <div className="rounded border border-dashed border-neutral-800 p-10 text-center text-sm text-neutral-500">
          No projects yet. Click "+ New project" above or capture one
          on iOS — it will show up here once it syncs.
        </div>
      )}

      {projects !== null && projects.length > 0 && (
        <ul className="divide-y divide-neutral-800 rounded border border-neutral-800">
          {projects.map((p) => (
            <li key={p.id}>
              <Link
                to={`/projects/${p.id}`}
                className="flex items-center justify-between gap-4 px-4 py-3 transition hover:bg-neutral-900"
              >
                <div className="min-w-0 flex-1">
                  <div className="truncate font-medium text-neutral-100">
                    {p.name}
                  </div>
                  <div className="text-xs text-neutral-500">
                    Updated {new Date(p.updatedAt).toLocaleString()}
                  </div>
                </div>
                <div className="text-neutral-600">›</div>
              </Link>
            </li>
          ))}
        </ul>
      )}

      {trashedProjects && trashedProjects.length > 0 && (
        <section className="mt-8">
          <button
            type="button"
            onClick={() => setTrashedOpen((o) => !o)}
            className="flex items-center gap-2 text-sm text-neutral-400 hover:text-neutral-200"
          >
            <span>{trashedOpen ? "▾" : "▸"}</span>
            <span>
              Trashed projects · {trashedProjects.length}
            </span>
          </button>
          {trashedOpen && (
            <ul className="mt-3 divide-y divide-neutral-900 rounded border border-neutral-900 bg-neutral-950">
              {trashedProjects.map((p) => (
                <TrashedProjectRow
                  key={p.id}
                  project={p}
                  onRestored={reload}
                  onPermanentlyDeleted={reload}
                />
              ))}
            </ul>
          )}
          <p className="mt-2 text-xs text-neutral-600">
            Trashed projects are hidden from the active list and the
            iOS app's main list. Restore is reversible; "Delete
            permanently" reaps storage + manifest and cannot be
            undone.
          </p>
        </section>
      )}

      {creatingOpen && (
        <NewProjectModal onClose={() => setCreatingOpen(false)} />
      )}
    </div>
  );
}

/** Sort a project list alphabetically by name, case- and
 *  diacritic-insensitive (matches iOS `localizedCaseInsensitiveCompare`). */
function sortByName(list: ProjectListItem[]): ProjectListItem[] {
  return [...list].sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { sensitivity: "base" })
  );
}

function TrashedProjectRow({
  project,
  onRestored,
  onPermanentlyDeleted,
}: {
  project: ProjectListItem;
  onRestored: () => void;
  onPermanentlyDeleted: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);

  async function restore() {
    setBusy(true);
    setError(null);
    try {
      await api.restoreProject(project.id);
      onRestored();
    } catch (e: unknown) {
      setError(
        e instanceof ApiError
          ? `${e.errorCode}: ${e.message}`
          : "Restore failed"
      );
      setBusy(false);
    }
  }

  async function permanentlyDelete() {
    setBusy(true);
    setError(null);
    try {
      await api.hardDeleteProject(project.id);
      onPermanentlyDeleted();
    } catch (e: unknown) {
      setError(
        e instanceof ApiError
          ? `${e.errorCode}: ${e.message}`
          : "Delete failed"
      );
      setBusy(false);
      setConfirmDelete(false);
    }
  }

  return (
    <>
      <li className="flex items-center justify-between gap-4 px-4 py-3">
        <div className="min-w-0 flex-1">
          <div className="truncate text-sm text-neutral-300">{project.name}</div>
          <div className="text-xs text-neutral-600">
            Trashed at update {new Date(project.updatedAt).toLocaleString()}
          </div>
          {error && (
            <div className="mt-1 text-xs text-red-400">{error}</div>
          )}
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={restore}
            disabled={busy}
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-200 hover:bg-neutral-800 disabled:opacity-50"
          >
            {busy ? "Restoring…" : "Restore"}
          </button>
          <button
            type="button"
            onClick={() => setConfirmDelete(true)}
            disabled={busy}
            className="rounded border border-red-800 px-3 py-1 text-xs text-red-300 hover:bg-red-950/40 disabled:opacity-50"
            title="Permanently delete — drops every photo, plan, and manifest row."
          >
            Delete permanently
          </button>
        </div>
      </li>

      {confirmDelete && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-100">
              Permanently delete{" "}
              <span className="font-semibold">{project.name}</span>?
            </div>
            <div className="text-xs text-neutral-400">
              This drops the project row, every photo + floor plan
              binary in storage, and the registry entries. Cannot be
              undone. Restore (above) is reversible — this isn't.
            </div>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmDelete(false)}
                disabled={busy}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800 disabled:opacity-50"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={permanentlyDelete}
                disabled={busy}
                className="rounded border border-red-600 bg-red-700/40 px-4 py-1.5 text-sm text-red-100 hover:bg-red-700/60 disabled:opacity-50"
              >
                {busy ? "Deleting…" : "Delete permanently"}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

function NewProjectModal({ onClose }: { onClose: () => void }) {
  const navigate = useNavigate();
  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit() {
    const trimmed = name.trim();
    if (trimmed === "") {
      setError("Name is required.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const id = crypto.randomUUID();
      const project = buildEmptyProject(id, trimmed, address.trim() || null);
      await api.putProject(id, project, null);
      onClose();
      navigate(`/projects/${id}/photos`);
    } catch (e: unknown) {
      setError(
        e instanceof ApiError
          ? `${e.errorCode}: ${e.message}`
          : "Create failed (network?)"
      );
      setBusy(false);
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 px-4"
      onClick={onClose}
    >
      <div
        className="w-full max-w-md rounded border border-neutral-800 bg-neutral-950 p-5 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-3 text-lg font-semibold text-neutral-100">
          New project
        </h2>
        <label className="mb-3 block text-xs uppercase tracking-wide text-neutral-500">
          Name (required)
          <input
            type="text"
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") void submit();
            }}
            disabled={busy}
            placeholder="123 Main St inspection"
            className="mt-1 w-full rounded border border-neutral-700 bg-neutral-900 px-3 py-2 text-sm text-neutral-100 placeholder:text-neutral-600 focus:border-blue-600 focus:outline-none disabled:opacity-50"
          />
        </label>
        <label className="mb-4 block text-xs uppercase tracking-wide text-neutral-500">
          Address (optional)
          <input
            type="text"
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") void submit();
            }}
            disabled={busy}
            placeholder="123 Main St, San Francisco, CA"
            className="mt-1 w-full rounded border border-neutral-700 bg-neutral-900 px-3 py-2 text-sm text-neutral-100 placeholder:text-neutral-600 focus:border-blue-600 focus:outline-none disabled:opacity-50"
          />
        </label>
        {error && (
          <div className="mb-3 rounded border border-red-800 bg-red-950/40 p-2 text-xs text-red-300">
            {error}
          </div>
        )}
        <div className="flex justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={submit}
            disabled={busy || name.trim() === ""}
            className="rounded border border-blue-700 bg-blue-900/40 px-3 py-1.5 text-sm text-blue-100 hover:bg-blue-900/70 disabled:opacity-50"
          >
            {busy ? "Creating…" : "Create"}
          </button>
        </div>
        <p className="mt-3 text-xs text-neutral-600">
          The project is saved to the server immediately. You'll be
          taken to its Photos tab — upload photos from iOS today
          (web upload ships in a later PR).
        </p>
      </div>
    </div>
  );
}

/**
 * Build an empty Project struct that satisfies the canonical zod
 * schema. Mirrors the defaults `Project.init(name:)` uses on iOS so
 * round-trip across platforms is loss-free.
 */
function buildEmptyProject(
  id: string,
  name: string,
  projectAddress: string | null
): Project {
  return {
    id,
    name,
    createdAt: new Date().toISOString(),
    startedAt: null,
    lastResumedAt: null,
    lastStoppedAt: null,
    stopped: false,
    isDeleted: false,
    isFrozen: false,
    projectGPS: null,
    projectAddress,
    photos: [],
    trashedPhotos: [],
    floorPlans: [],
    activeFloorPlanID: null,
    folderName: null,
    aiInstructions: null,
    buckets: [],
    tagSelection: null,
    aiExtraVocabulary: null,
    inspectionChecklist: [],
    inspectionSessions: [],
    reportLayout: null,
    manifestSchemaVersion: MANIFEST_SCHEMA_VERSION,
  };
}
