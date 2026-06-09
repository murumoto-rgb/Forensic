import { useCallback, useEffect, useRef, useState } from "react";
import type { Project, ProjectRole } from "@forensic/shared";
import { api, ApiError } from "./api";

/**
 * Shared manifest-state hook (Build #5.76.1 — Path P #1/8).
 *
 * Owns load + optimistic save + revision tracking for a project
 * across every tab of `ProjectWorkspacePage`. Replaces the
 * save-loop pattern that was duplicated in `ProjectPlanPage.tsx`
 * (pin drag / distress edit) and `ProjectDetailPage.tsx` (batch
 * re-tag) — keeping one canonical implementation means a write
 * triggered in (say) the Photos tab is visible to the Floor Plan
 * tab without a round-trip.
 *
 * Save semantics (cloud-first, Build #5.118.1):
 *   - One PUT in flight at a time. Rapid `save(next)` calls
 *     coalesce — the latest snapshot wins (`pendingRef`).
 *   - Every save sends `baseManifest` = the last manifest the
 *     server confirmed we held (`baseRef`). The server runs a
 *     3-way merge against current truth and returns the merged
 *     manifest, which we adopt: `project` + `projectRef` + `baseRef`
 *     all advance to the merged value. Concurrent edits from
 *     another tab or iOS no longer clobber the user's work.
 *   - If the user kept typing while the PUT was in flight,
 *     `pendingRef` holds the newer edit; the loop re-sends with
 *     `base = merged`. Idempotent merge converges.
 *   - 409 from the server is now an unusual case (legacy path or
 *     `merge_cas_exhausted` after server-side retries). Still
 *     surfaced as `status.kind === "conflict"` for defensive
 *     visibility.
 *   - Network errors (fetch threw) re-stash the snapshot so the
 *     next mutation retries it. ApiErrors (4xx/5xx) bail.
 *
 * `save(next)` is fire-and-forget — it returns synchronously,
 * the loop persists in the background. Tab components read
 * `status` (loading | idle | saving | saved | conflict | error)
 * to render the auto-save pill / banner.
 */

export type SaveStatus =
  | { kind: "loading" }
  | { kind: "idle" }
  | { kind: "saving" }
  | { kind: "saved" }
  | { kind: "conflict"; message: string }
  | { kind: "error"; message: string };

export interface ProjectManifestHook {
  project: Project | null;
  revision: string | null;
  /**
   * Caller's effective role on this project (Build #5.125.1).
   * `null` while the manifest is loading or when the response
   * predates server-side role plumbing.
   */
  role: ProjectRole | null;
  /**
   * Convenience derived from `role`. `null`/`"admin"`/`"editor"`
   * pass; `"viewer"` blocks. Combine with `lock.status === "holding"`
   * + `!project.isFrozen` at the workspace level for the final
   * `canEdit` decision.
   */
  hasWriteAccess: boolean;
  /** Read-only mirror refs for callers (e.g. `useBatchRetag`) that
   *  need to grab the latest project/revision from inside a long-
   *  running task without re-rendering. */
  projectRef: React.MutableRefObject<Project | null>;
  revisionRef: React.MutableRefObject<string | null>;
  status: SaveStatus;
  /** Replace project state (optimistic) and queue a PUT. Fire-and-
   *  forget; status updates as the save loop progresses. */
  save: (next: Project) => void;
  /** Setter exposed for the legacy `useBatchRetag` callers that
   *  manipulate the project state directly. New code should prefer
   *  `save(next)`. */
  setProject: (next: Project) => void;
  setRevision: (next: string) => void;
  /** Re-fetch from the server. Useful after a 409 conflict. */
  reload: () => Promise<void>;
}

export function useProjectManifest(
  projectId: string | undefined
): ProjectManifestHook {
  const [project, setProjectState] = useState<Project | null>(null);
  const [revision, setRevisionState] = useState<string | null>(null);
  const [role, setRoleState] = useState<ProjectRole | null>(null);
  const [status, setStatus] = useState<SaveStatus>({ kind: "loading" });

  const projectRef = useRef<Project | null>(null);
  const revisionRef = useRef<string | null>(null);
  const savingRef = useRef<boolean>(false);
  const pendingRef = useRef<Project | null>(null);
  /** The manifest the server last confirmed we hold. Sent on every
   *  PUT as `baseManifest` so the server can run a 3-way merge.
   *  Advances to the server's returned `merged` after each successful
   *  save (or to `resp.project` on load). */
  const baseRef = useRef<Project | null>(null);
  useEffect(() => {
    projectRef.current = project;
  }, [project]);
  useEffect(() => {
    revisionRef.current = revision;
  }, [revision]);

  const setProject = useCallback((next: Project) => {
    setProjectState(next);
  }, []);
  const setRevision = useCallback((next: string) => {
    setRevisionState(next);
  }, []);

  const load = useCallback(async () => {
    if (!projectId) return;
    setStatus({ kind: "loading" });
    try {
      const resp = await api.getProject(projectId);
      setProjectState(resp.project);
      setRevisionState(resp.revision);
      setRoleState(resp.role ?? null);
      projectRef.current = resp.project;
      revisionRef.current = resp.revision;
      baseRef.current = resp.project;
      setStatus({ kind: "idle" });
    } catch (e: unknown) {
      setStatus({
        kind: "error",
        message:
          e instanceof ApiError
            ? `${e.errorCode}: ${e.message}`
            : "Failed to load project",
      });
    }
  }, [projectId]);

  useEffect(() => {
    void load();
  }, [load]);

  const runSaveLoop = useCallback(async () => {
    if (!projectId) return;
    if (savingRef.current) return;
    savingRef.current = true;
    setStatus({ kind: "saving" });

    while (pendingRef.current && revisionRef.current) {
      const toSave = pendingRef.current;
      pendingRef.current = null;
      const base = baseRef.current ?? toSave;
      try {
        const resp = await api.putProject(
          projectId,
          toSave,
          revisionRef.current,
          base
        );
        revisionRef.current = resp.revision;
        setRevisionState(resp.revision);
        // Cloud-first: adopt the server's merged manifest so future
        // edits (from this tab or another) base on what the server
        // now holds. If the user kept typing during the PUT,
        // `pendingRef` already holds the newer snapshot; the loop
        // re-sends with `base = merged` next iteration.
        if (resp.project) {
          baseRef.current = resp.project;
          // Only adopt into UI state when no fresher edit is queued.
          // Otherwise the merged value would briefly flash over the
          // user's just-typed text before the next loop iteration
          // re-applied it.
          if (pendingRef.current === null) {
            setProjectState(resp.project);
            projectRef.current = resp.project;
          }
        } else {
          // Legacy response (server pre-#5.117.1 or for some reason
          // skipped merge): base advances to what we just pushed.
          baseRef.current = toSave;
        }
      } catch (e: unknown) {
        if (e instanceof ApiError && e.status === 409) {
          setStatus({
            kind: "conflict",
            message: "Project was modified elsewhere — reload to sync.",
          });
        } else if (e instanceof ApiError) {
          setStatus({
            kind: "error",
            message: `${e.status} ${e.errorCode}: ${e.message}`,
          });
        } else {
          // Network-level failure (no HTTP response). Re-stash so a
          // later mutation re-triggers the save with the latest
          // local state.
          pendingRef.current = toSave;
          setStatus({
            kind: "error",
            message:
              "Couldn't reach the server (network or server waking up). " +
              "Your change isn't saved yet — edit again to retry.",
          });
        }
        savingRef.current = false;
        return;
      }
    }

    savingRef.current = false;
    setStatus({ kind: "saved" });
    // Auto-clear "Saved" after a couple of seconds so the pill
    // doesn't permanently dominate the chrome.
    setTimeout(() => {
      setStatus((s) => (s.kind === "saved" ? { kind: "idle" } : s));
    }, 2000);
  }, [projectId]);

  const save = useCallback(
    (next: Project) => {
      setProjectState(next);
      projectRef.current = next;
      pendingRef.current = next;
      void runSaveLoop();
    },
    [runSaveLoop]
  );

  // hasWriteAccess: viewer blocks; null/admin/editor pass. Null
  // covers (a) initial loading and (b) an older server that doesn't
  // populate `role` — fall back to today's permissive behaviour
  // rather than locking the user out unexpectedly.
  const hasWriteAccess = role !== "viewer";

  return {
    project,
    revision,
    role,
    hasWriteAccess,
    projectRef,
    revisionRef,
    status,
    save,
    setProject,
    setRevision,
    reload: load,
  };
}
