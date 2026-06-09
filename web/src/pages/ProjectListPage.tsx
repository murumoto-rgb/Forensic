import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { MANIFEST_SCHEMA_VERSION, type Project } from "@forensic/shared";
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
          <Link
            to="/admin/tag-library"
            className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
            title="Edit the team's app-wide AI tag library"
          >
            Tag library
          </Link>
          <Link
            to="/admin/ai-rules"
            className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
            title="Edit the team's app-wide AI rules / schema template"
          >
            AI rules
          </Link>
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
    manifestSchemaVersion: MANIFEST_SCHEMA_VERSION,
  };
}
