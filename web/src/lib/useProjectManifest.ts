import { useCallback, useEffect, useRef, useState } from "react";
import type { Project, ProjectRole } from "@forensic/shared";
import { mergeManifest } from "@forensic/shared";
import { api, ApiError } from "./api";

export type SaveStatus =
  | { kind: "loading" | "idle" | "saving" | "saved" }
  | { kind: "conflict" | "error"; message: string };
export interface RestoreReview { project: Project; revision: string }
export interface ProjectManifestHook {
  project: Project | null;
  revision: string | null;
  role: ProjectRole | null;
  isOwner: boolean;
  hasWriteAccess: boolean;
  projectRef: React.MutableRefObject<Project | null>;
  revisionRef: React.MutableRefObject<string | null>;
  status: SaveStatus;
  restoring: boolean;
  hasPendingChanges: boolean;
  save: (next: Project) => void;
  saveAndWait: (next: Project) => Promise<void>;
  setProject: (next: Project) => void;
  setRevision: (next: string) => void;
  reload: () => Promise<void>;
  /** Review captures the current project/revision used to compare the target. */
  restoreVersion: (versionId: string, review: RestoreReview) => Promise<void>;
}
interface Waiter { resolve: () => void; reject: (error: unknown) => void }
interface PendingSave { project: Project; base: Project | null; waiters: Waiter[] }
const errorMessage = (error: unknown) => error instanceof Error ? error.message : "Request failed";

/** One writer owns the acknowledged base, revision and optimistic state.
 * Restores cannot interleave with saves, previews, or reloads. */
export function useProjectManifest(projectId: string | undefined): ProjectManifestHook {
  const [project, setProjectState] = useState<Project | null>(null);
  const [revision, setRevisionState] = useState<string | null>(null);
  const [role, setRole] = useState<ProjectRole | null>(null);
  const [isOwner, setIsOwner] = useState(false);
  const [status, setStatusState] = useState<SaveStatus>({ kind: "loading" });
  const [restoring, setRestoring] = useState(false);
  const projectRef = useRef<Project | null>(null);
  const revisionRef = useRef<string | null>(null);
  const baseRef = useRef<Project | null>(null);
  const statusRef = useRef<SaveStatus>({ kind: "loading" });
  const savingRef = useRef(false);
  const loadingRef = useRef(false);
  const restoringRef = useRef(false);
  const dirtyRef = useRef(false);
  const pendingRef = useRef<PendingSave | null>(null);
  const epochRef = useRef(0);
  const loadRequestRef = useRef(0);

  const setStatus = useCallback((next: SaveStatus) => {
    statusRef.current = next;
    setStatusState(next);
  }, []);
  const adopt = useCallback((next: Project, nextRevision: string) => {
    // These refs update synchronously before another event can enqueue a save.
    projectRef.current = next;
    baseRef.current = next;
    revisionRef.current = nextRevision;
    dirtyRef.current = false;
    setProjectState(next);
    setRevisionState(nextRevision);
  }, []);
  const setProject = useCallback((next: Project) => {
    if (restoringRef.current || loadingRef.current) return;
    projectRef.current = next;
    dirtyRef.current = next !== baseRef.current && JSON.stringify(next) !== JSON.stringify(baseRef.current);
    setProjectState(next);
  }, []);
  const setRevision = useCallback((next: string) => {
    if (restoringRef.current || loadingRef.current) return;
    revisionRef.current = next;
    setRevisionState(next);
  }, []);

  const load = useCallback(async () => {
    if (!projectId) return;
    if (savingRef.current || pendingRef.current || dirtyRef.current || restoringRef.current) {
      // A header refresh must never silently discard unsaved local evidence.
      setStatus({ kind: "error", message: "Unsaved changes were kept. Finish or retry the save before refreshing." });
      return;
    }
    const epoch = epochRef.current;
    const request = ++loadRequestRef.current;
    loadingRef.current = true;
    setStatus({ kind: "loading" });
    try {
      const response = await api.getProject(projectId);
      if (epoch !== epochRef.current || request !== loadRequestRef.current) return;
      adopt(response.project, response.revision);
      setRole(response.role ?? null);
      setIsOwner(response.isOwner === true);
      setStatus({ kind: "idle" });
    } catch (error) {
      if (epoch === epochRef.current && request === loadRequestRef.current) setStatus({ kind: "error", message: `Could not load project: ${errorMessage(error)}` });
    } finally {
      if (epoch === epochRef.current && request === loadRequestRef.current) loadingRef.current = false;
    }
  }, [projectId, adopt, setStatus]);

  useEffect(() => {
    epochRef.current++;
    projectRef.current = null; revisionRef.current = null; baseRef.current = null;
    dirtyRef.current = false; savingRef.current = false; restoringRef.current = false;
    setProjectState(null); setRevisionState(null); setRestoring(false); setRole(null); setIsOwner(false);
    void load();
    return () => {
      epochRef.current++;
      pendingRef.current?.waiters.forEach(waiter => waiter.reject(new Error("Project changed before the save completed")));
      pendingRef.current = null;
    };
  }, [load]);

  const runSaveLoop = useCallback(async () => {
    if (!projectId || savingRef.current || restoringRef.current) return;
    const epoch = epochRef.current;
    savingRef.current = true;
    setStatus({ kind: "saving" });
    while (pendingRef.current && revisionRef.current) {
      const queued = pendingRef.current;
      pendingRef.current = null;
      const base = queued.base ?? baseRef.current ?? queued.project;
      try {
        const response = await api.putProject(projectId, queued.project, revisionRef.current, base);
        if (epoch !== epochRef.current) {
          queued.waiters.forEach(waiter => waiter.reject(new Error("Project changed before the save completed")));
          return;
        }
        const acknowledged = response.project ?? queued.project;
        const pending = pendingRef.current as PendingSave | null;
        baseRef.current = acknowledged;
        revisionRef.current = response.revision;
        setRevisionState(response.revision);
        if (pending) {
          const rebased = mergeManifest(base, acknowledged, pending.project).merged;
          pendingRef.current = { ...pending, project: rebased, base: acknowledged };
          projectRef.current = rebased;
          setProjectState(rebased);
        } else {
          adopt(acknowledged, response.revision);
        }
        queued.waiters.forEach(waiter => waiter.resolve());
      } catch (error) {
        queued.waiters.forEach(waiter => waiter.reject(error));
        if (epoch !== epochRef.current) return;
        const newest = pendingRef.current as PendingSave | null;
        newest?.waiters.forEach(waiter => waiter.reject(error));
        // Preserve the newest edit for an explicit retry, including HTTP errors.
        pendingRef.current = { project: newest?.project ?? queued.project, base: newest?.base ?? base, waiters: [] };
        dirtyRef.current = true;
        savingRef.current = false;
        setStatus({ kind: error instanceof ApiError && error.status === 409 ? "conflict" : "error", message: `Change not saved: ${errorMessage(error)}. Your edits were kept; retry the save.` });
        return;
      }
    }
    if (epoch === epochRef.current) {
      savingRef.current = false;
      setStatus({ kind: "saved" });
    }
  }, [projectId, adopt, setStatus]);

  const enqueue = useCallback((next: Project): Promise<void> => {
    if (restoringRef.current || loadingRef.current || !revisionRef.current) return Promise.reject(new Error("Wait for the project operation to finish before editing."));
    if (!projectId || next.id.toLowerCase() !== projectId.toLowerCase()) return Promise.reject(new Error("Cannot save a different project."));
    projectRef.current = next;
    dirtyRef.current = true;
    setProjectState(next);
    const promise = new Promise<void>((resolve, reject) => {
      const existing = pendingRef.current;
      pendingRef.current = { project: next, base: baseRef.current, waiters: [...(existing?.waiters ?? []), { resolve, reject }] };
    });
    void runSaveLoop();
    return promise;
  }, [projectId, runSaveLoop]);
  const save = useCallback((next: Project) => { void enqueue(next).catch(() => undefined); }, [enqueue]);

  const restoreVersion = useCallback(async (versionId: string, review: RestoreReview) => {
    if (!projectId || loadingRef.current || restoringRef.current || savingRef.current || pendingRef.current || dirtyRef.current ||
        statusRef.current.kind === "error" || statusRef.current.kind === "conflict") {
      throw new Error("Finish or retry all pending saves before restoring a version.");
    }
    if (projectRef.current !== review.project || revisionRef.current !== review.revision) throw new Error("The project changed after this preview. Close it and review the version again.");
    if (projectRef.current?.isFrozen) throw new Error("Unlock the project before restoring a version.");
    const epoch = epochRef.current;
    restoringRef.current = true;
    setRestoring(true);
    try {
      const response = await api.restoreProjectVersion(projectId, { versionId, expectedRevision: review.revision });
      if (epoch !== epochRef.current) return;
      adopt(response.project, response.revision);
      if (response.role) setRole(response.role);
      if (response.isOwner !== undefined) setIsOwner(response.isOwner);
      setStatus({ kind: "saved" });
    } finally {
      if (epoch === epochRef.current) { restoringRef.current = false; setRestoring(false); }
    }
  }, [projectId, adopt, setStatus]);

  return { project, revision, role, isOwner, hasWriteAccess: role !== "viewer", projectRef, revisionRef, status,
    restoring, hasPendingChanges: dirtyRef.current || savingRef.current || pendingRef.current !== null,
    save, saveAndWait: enqueue, setProject, setRevision, reload: load, restoreVersion };
}
