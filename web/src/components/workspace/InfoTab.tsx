import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import type { AdminUser, Project } from "@forensic/shared";
import { api, ApiError } from "../../lib/api";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { ProjectRecoveryPanel } from "./ProjectRecoveryPanel";
import { ProjectWorkflowPanel } from "./ProjectWorkflowPanel";

/**
 * Info tab — project metadata + editable name + editable address +
 * trash button.
 *
 * Address editing landed in Build #5.83.1 (Path P #8/8). Name editing
 * + trash landed in the project-management round (PR #1).
 *
 * Name commits on blur (same pattern as address). Trash writes
 * `isDeleted: true` via `manifest.save` and navigates back to the
 * project list — the server's GET endpoint returns 404 for trashed
 * projects, so the workspace becomes unloadable as soon as the save
 * lands. Restore happens from the project list's Trashed section.
 *
 * Forward-geocoding (resolving the typed address into lat/long and
 * stamping `projectGPS`) is iOS-only — web stores the literal string
 * and lets the next iOS sync pick a fix if the user wants one.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function InfoTab({ projectId, manifest, canEdit }: Props) {
  // The Lock/Unlock toggle is exempt from `canEdit` (otherwise you
  // couldn't unfreeze a frozen project) and exempt from the edit-
  // lock gate.
  //
  // Build #6.34.1: admin-only. The server gate on this PUT path
  // (server/src/routes/projects.ts) returns 403 unless the caller
  // is an org admin OR the project owner — the editor role is NOT
  // allowed. Before this build the UI showed the control to
  // editors too, so they could tap it and get a 403. Editors now
  // see no control. Owners-who-aren't-admins also see no control
  // from here (documented gap — they can lock/unlock from the iOS
  // More tab, #6.1.1, and the change syncs back); surfacing
  // per-project ownership to `/v1/me` is a separate follow-on
  // tracked in `docs/deferred-work.md`.
  const canToggleFreeze = manifest.role === "admin" || manifest.isOwner;
  const project = manifest.project;
  const navigate = useNavigate();
  const [name, setName] = useState(project?.name ?? "");
  const [address, setAddress] = useState(project?.projectAddress ?? "");
  const [editError, setEditError] = useState<string | null>(null);
  const [actionBusy, setActionBusy] = useState(false);

  useEffect(() => {
    setName(project?.name ?? "");
  }, [project?.name]);
  useEffect(() => {
    setAddress(project?.projectAddress ?? "");
  }, [project?.projectAddress]);

  if (!project) return null;
  const gps = project.projectGPS;

  async function persist(next: Project): Promise<boolean> {
    setActionBusy(true); setEditError(null);
    try { await manifest.saveAndWait(next); return true; }
    catch (error) { setEditError(error instanceof Error ? error.message : "Change not saved. Your edits were kept."); return false; }
    finally { setActionBusy(false); }
  }

  function commitName() {
    if (!project) return;
    const next = name.trim();
    if (next === "" || next === project.name) {
      setName(project.name);
      return;
    }
    void persist({ ...project, name: next });
  }

  function commitAddress() {
    if (!project) return;
    const next = address.trim();
    const cur = project.projectAddress ?? "";
    if (next === cur.trim()) return;
    void persist({
      ...project,
      projectAddress: next === "" ? null : next,
    });
  }

  async function moveToTrash() {
    if (!project) return;
    const confirmed = window.confirm(
      `Move "${project.name}" to trash?\n\n` +
        `You can restore it from the project list's Trashed section. ` +
        `It won't appear in your active projects until you do.`
    );
    if (!confirmed) return;
    if (await persist({ ...project, isDeleted: true })) navigate("/projects");
  }

  return (
    <section className="flex flex-col gap-4">
      {editError && <p role="alert" className="text-sm text-red-300">{editError}</p>}
      <dl className="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm">
        <dt className="text-neutral-500">Name</dt>
        <dd>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            onBlur={commitName}
            disabled={!canEdit}
            placeholder="Project name"
            className="w-full max-w-md rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-600 disabled:opacity-50"
          />
        </dd>

        <dt className="text-neutral-500">Created</dt>
        <dd className="text-neutral-200">
          {new Date(project.createdAt).toLocaleString()}
        </dd>

        <dt className="text-neutral-500">Address</dt>
        <dd>
          <input
            type="text"
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            onBlur={commitAddress}
            disabled={!canEdit}
            placeholder="(no address set)"
            className="w-full max-w-md rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-600 disabled:opacity-50"
          />
        </dd>

        <dt className="text-neutral-500">GPS</dt>
        <dd className="font-mono text-xs text-neutral-200">
          {gps ? (
            <>
              {gps.latitude.toFixed(5)}, {gps.longitude.toFixed(5)}
              {gps.accuracyFeet != null && (
                <span className="text-neutral-500">
                  {" "}
                  · ±{gps.accuracyFeet.toFixed(0)} ft
                </span>
              )}
            </>
          ) : (
            <span className="font-sans text-neutral-500">(no fix)</span>
          )}
        </dd>

        <dt className="text-neutral-500">Photo count</dt>
        <dd className="text-neutral-200">
          {project.photos.length}{" "}
          <span className="text-neutral-500">
            ({project.trashedPhotos.length} in trash)
          </span>
        </dd>

        <dt className="text-neutral-500">Floor plans</dt>
        <dd className="text-neutral-200">{project.floorPlans.length}</dd>

        <dt className="text-neutral-500">Buckets</dt>
        <dd className="text-neutral-200">{project.buckets.length}</dd>

        <dt className="text-neutral-500">Manifest schema</dt>
        <dd className="text-neutral-500">v{project.manifestSchemaVersion}</dd>
      </dl>
      <p className="text-xs text-neutral-500">
        Forward-geocoding (resolving the address to GPS coordinates)
        stays on iOS — when you next open the project there, iOS can
        pick a fix and stamp `projectGPS`.
      </p>

      <ProjectWorkflowPanel manifest={manifest} canEdit={canEdit} />
      <ProjectRecoveryPanel projectId={projectId} manifest={manifest} canEdit={canEdit} />

      <div className="mt-6 rounded border border-neutral-800 bg-neutral-900/40 p-4">
        <div className="mb-2 text-sm font-medium text-neutral-200">
          Tools
        </div>
        <button
          type="button"
          onClick={renumberByDate}
          disabled={!canEdit || project.photos.length === 0}
          className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-200 transition hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
        >
          Renumber photos by date
        </button>
        <p className="mt-2 text-xs text-neutral-500">
          Sort all photos by capture timestamp ascending, then
          reassign sequence numbers 1..N. Useful after importing a
          backlog of photos that landed out of order. Mirrors iOS's
          "Renumber by date" action.
        </p>
      </div>

      {canToggleFreeze && (
        <div className="mt-3 rounded border border-amber-800/60 bg-amber-950/20 p-4">
          <div className="mb-2 text-sm font-medium text-amber-200">
            {project.isFrozen ? "🔒 Project is locked" : "Lock project"}
          </div>
          <button
            type="button"
            onClick={toggleFreeze}
            disabled={manifest.restoring || actionBusy}
            className="rounded border border-amber-700 px-3 py-1.5 text-sm text-amber-100 transition hover:bg-amber-900/40"
          >
            {project.isFrozen ? "Unlock project" : "Lock project (finalize)"}
          </button>
          <p className="mt-2 text-xs text-neutral-500">
            {project.isFrozen
              ? "Every edit affordance is disabled until you unlock. Use Unlock to make further changes."
              : "Lock the project to finalize the report — disables every edit on web and iOS until an owner or admin unlocks it. Distinct from the transient edit-lock that prevents simultaneous editors."}
          </p>
        </div>
      )}

      <div className="mt-3 rounded border border-red-900/40 bg-red-950/20 p-4">
        <div className="mb-2 text-sm font-medium text-red-300">
          Danger zone
        </div>
        <button
          type="button"
          onClick={moveToTrash}
          disabled={!canEdit}
          className="rounded border border-red-800 px-3 py-1.5 text-sm text-red-300 transition hover:bg-red-900/30 disabled:cursor-not-allowed disabled:opacity-50"
        >
          Move to trash
        </button>
        <p className="mt-2 text-xs text-neutral-500">
          Soft-delete — the project disappears from the active list
          but you can restore it from the Trashed section.
          Permanent deletion is a separate action on the trash row.
        </p>
      </div>

      <MembersSection projectId={projectId} />
    </section>
  );

  function toggleFreeze() {
    if (!project) return;
    const next = !project.isFrozen;
    if (next) {
      if (
        !window.confirm(
          `Lock "${project.name}"?\n\nNo one can edit the project on web or iOS until it's unlocked. Use this when the report is finalized.`
        )
      ) {
        return;
      }
    }
    void persist({ ...project, isFrozen: next });
  }

  function renumberByDate() {
    if (!project) return;
    if (
      !window.confirm(
        `Renumber every photo in this project by capture date?\n\nReassigns sequence numbers 1..${project.photos.length} in ascending timestamp order. This change syncs to iOS on next pull.`
      )
    ) {
      return;
    }
    const sorted = [...project.photos].sort((a, b) => {
      const ta = new Date(a.timestamp).getTime();
      const tb = new Date(b.timestamp).getTime();
      if (Number.isNaN(ta) || Number.isNaN(tb)) return 0;
      return ta - tb;
    });
    const renumbered = sorted.map((p, i) => ({
      ...p,
      sequenceNumber: i + 1,
    }));
    void persist({ ...project, photos: renumbered });
  }
}

// ---------------------------------------------------------------------------
// Per-project member assignment (Build #5.125.1)
// ---------------------------------------------------------------------------

interface MembersSectionProps {
  projectId: string;
}

/**
 * Per-project member assignment editor. Admin-only — checks
 * `getMe().isAdmin` on mount and hides the section entirely for
 * non-admins. The owner is the implicit editor and never appears
 * in the picker.
 *
 * Lives on the Info tab so admins manage access in the same place
 * they look at project metadata, avoiding an N×M user-projects
 * matrix on AdminUsersPage. Reads the full user list once on mount
 * and projects the current project's assignments onto it.
 */
function MembersSection({ projectId }: MembersSectionProps) {
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const [users, setUsers] = useState<AdminUser[] | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  // assignments: userId -> role | undefined (no membership)
  const [assignments, setAssignments] = useState<Record<string, "editor" | "viewer" | undefined>>({});

  const load = useCallback(async () => {
    setError(null);
    try {
      const me = await api.getMe();
      setIsAdmin(me.isAdmin);
      if (!me.isAdmin) return;
      const list = await api.listAdminUsers();
      setUsers(list.users);
      // Derive this project's current member assignments from the
      // user list — `AdminUser.assignments` already includes them.
      // The project owner is silently stripped from any PUT by the
      // server (they're the implicit editor), so we don't need to
      // know which row is the owner to keep the picker honest.
      const next: Record<string, "editor" | "viewer" | undefined> = {};
      for (const u of list.users) {
        for (const a of u.assignments) {
          if (a.projectId === projectId) next[u.id] = a.role;
        }
      }
      setAssignments(next);
    } catch (e: unknown) {
      setError(
        e instanceof ApiError ? `${e.errorCode}: ${e.message}` : "Failed to load users"
      );
    }
  }, [projectId]);

  useEffect(() => {
    void load();
  }, [load]);

  if (isAdmin === null) return null;
  if (!isAdmin) return null;

  async function save(next: Record<string, "editor" | "viewer" | undefined>) {
    setAssignments(next);
    setSaving(true);
    setError(null);
    try {
      const members = Object.entries(next)
        .filter(([, role]) => role !== undefined)
        .map(([userId, role]) => ({ userId, role: role as "editor" | "viewer" }));
      await api.setProjectMembers(projectId, members);
      setSavedAt(Date.now());
    } catch (e: unknown) {
      setError(
        e instanceof ApiError ? `${e.errorCode}: ${e.message}` : "Save failed"
      );
    } finally {
      setSaving(false);
    }
  }

  function toggleRole(userId: string, role: "editor" | "viewer" | undefined) {
    const next = { ...assignments };
    if (role === undefined) {
      delete next[userId];
    } else {
      next[userId] = role;
    }
    void save(next);
  }

  return (
    <div className="mt-3 rounded border border-neutral-800 bg-neutral-900/40 p-4">
      <div className="mb-2 flex items-center justify-between text-sm">
        <span className="font-medium text-neutral-200">Project members</span>
        <span className="text-xs text-neutral-500">
          {saving && "Saving…"}
          {!saving && savedAt && Date.now() - savedAt < 5000 && (
            <span className="text-emerald-400">Saved ✓</span>
          )}
        </span>
      </div>
      <p className="mb-3 text-xs text-neutral-500">
        The project owner has implicit Editor access. Add other
        users as Editor (can edit) or Viewer (read-only).
      </p>
      {error && (
        <div className="mb-2 rounded border border-red-800 bg-red-950/40 p-2 text-xs text-red-300">
          {error}
        </div>
      )}
      {users === null ? (
        <div className="text-xs text-neutral-500">Loading users…</div>
      ) : (
        <ul className="divide-y divide-neutral-800">
          {users
            .filter((u) => !u.isAdmin) // admins see everything anyway
            .map((u) => {
              const role = assignments[u.id];
              return (
                <li
                  key={u.id}
                  className="flex items-center justify-between gap-3 py-2 text-sm"
                >
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-neutral-200">{u.email}</div>
                    {u.pending && (
                      <div className="text-[10px] text-amber-300">
                        Invited (pending)
                      </div>
                    )}
                  </div>
                  <div className="flex flex-shrink-0 items-center gap-1">
                    <RoleButton
                      label="None"
                      active={role === undefined}
                      onClick={() => toggleRole(u.id, undefined)}
                      disabled={saving}
                    />
                    <RoleButton
                      label="Viewer"
                      active={role === "viewer"}
                      onClick={() => toggleRole(u.id, "viewer")}
                      disabled={saving}
                    />
                    <RoleButton
                      label="Editor"
                      active={role === "editor"}
                      onClick={() => toggleRole(u.id, "editor")}
                      disabled={saving}
                    />
                  </div>
                </li>
              );
            })}
          {users.filter((u) => !u.isAdmin).length === 0 && (
            <li className="py-2 text-xs text-neutral-500">
              No other users to assign yet. Invite some on the{" "}
              <span className="text-neutral-300">Team &amp; access</span>{" "}
              page.
            </li>
          )}
        </ul>
      )}
    </div>
  );
}

interface RoleButtonProps {
  label: string;
  active: boolean;
  onClick: () => void;
  disabled: boolean;
}
function RoleButton({ label, active, onClick, disabled }: RoleButtonProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={
        active
          ? "rounded border border-blue-500 bg-blue-600/80 px-2 py-1 text-xs font-medium text-white disabled:opacity-50"
          : "rounded border border-neutral-700 px-2 py-1 text-xs text-neutral-300 hover:bg-neutral-800 disabled:opacity-50"
      }
    >
      {label}
    </button>
  );
}
