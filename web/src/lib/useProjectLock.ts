import { useCallback, useEffect, useRef, useState } from "react";
import type { ProjectLock } from "@forensic/shared";
import { api, ApiError } from "./api";

/**
 * Web client for the project edit-lock model (Build #5.60.1; backed
 * by the server endpoints from #5.59.1).
 *
 * Three roles a page can be in for a given project:
 *  - **free** — no live lock; anyone can take it. Edit controls
 *    show an "Edit" button that calls `acquire`.
 *  - **holding** — this client holds the lock. Edit controls are
 *    enabled. A 90-second heartbeat runs (server TTL is 10 min so
 *    a few missed beats don't lose the lock). A "Release" button
 *    is available.
 *  - **read-only** — someone else holds it. Edit controls are
 *    disabled. A banner names the holder.
 *
 * The hook auto-fetches the current state on mount and re-polls on
 * a slow cadence (30s) so a viewer notices when the holder
 * disconnects. The holder doesn't poll — its heartbeat IS the
 * polling signal (responses carry the updated lock state).
 *
 * On unmount + on `beforeunload` we attempt a release via
 * `navigator.sendBeacon` so closing the tab frees the lock without
 * waiting for the TTL. If the beacon fails (offline, blocked), the
 * 10-min server expiry catches up.
 *
 * 409 handling:
 *   - acquire 409 `locked` → store the holder, surface via `lock`,
 *     UI shows the "currently editing: X" banner.
 *   - heartbeat 409 `lock_lost` → we silently dropped the lock
 *     (someone forced it or the TTL elapsed during a hot-page
 *     pause). Caller sees `status === "lock_lost"` and can prompt
 *     the user to re-acquire.
 */

export type LockStatus =
  | { kind: "loading" }
  | { kind: "free" }
  | { kind: "holding"; lock: ProjectLock }
  | { kind: "read_only"; lock: ProjectLock }
  | { kind: "lock_lost" }
  | { kind: "error"; message: string };

/** How often to heartbeat while holding. 90s × 6.6 heartbeats fits
 *  inside the server's 10-min TTL with margin for a slow request. */
const HEARTBEAT_MS = 90_000;
/** How often a non-holder re-polls so the viewer banner updates
 *  promptly when the holder disconnects. */
const POLL_MS = 30_000;

export function useProjectLock(projectId: string | null | undefined): {
  status: LockStatus;
  acquire: () => Promise<void>;
  release: () => Promise<void>;
  force: () => Promise<void>;
  /** Refetch the current lock state. */
  refresh: () => Promise<void>;
  /** Clear a `lock_lost` status after the user dismisses the
   *  re-acquire prompt. */
  acknowledgeLost: () => void;
} {
  const [status, setStatus] = useState<LockStatus>({ kind: "loading" });
  const statusRef = useRef<LockStatus>(status);
  useEffect(() => {
    statusRef.current = status;
  }, [status]);

  const fetchOnce = useCallback(async () => {
    if (!projectId) return;
    try {
      const resp = await api.getProjectLock(projectId);
      // Preserve a "holding" status across a poll — that's only set
      // by acquire/heartbeat, never by GET (the server doesn't know
      // which client is asking, so two of our own browsers would
      // both see the same lock and would both think they hold it).
      // GET is informational; it's how a viewer learns about other
      // people's locks.
      if (statusRef.current.kind === "holding") return;
      if (resp.lock == null) {
        setStatus({ kind: "free" });
      } else {
        setStatus({ kind: "read_only", lock: resp.lock });
      }
    } catch (e: unknown) {
      setStatus({
        kind: "error",
        message:
          e instanceof ApiError ? `${e.errorCode}: ${e.message}` : "Lock state fetch failed",
      });
    }
  }, [projectId]);

  // Initial load + slow polling.
  useEffect(() => {
    if (!projectId) return;
    void fetchOnce();
    const id = window.setInterval(() => {
      // Only poll when we're not the holder (holder's heartbeat is
      // the live signal).
      if (statusRef.current.kind !== "holding") void fetchOnce();
    }, POLL_MS);
    return () => window.clearInterval(id);
  }, [projectId, fetchOnce]);

  // Heartbeat while holding.
  useEffect(() => {
    if (!projectId) return;
    if (status.kind !== "holding") return;
    const id = window.setInterval(async () => {
      try {
        const resp = await api.heartbeatProjectLock(projectId);
        setStatus({ kind: "holding", lock: resp.lock });
      } catch (e: unknown) {
        if (e instanceof ApiError && e.status === 409) {
          setStatus({ kind: "lock_lost" });
        }
        // Network errors fall through — next beat retries. The
        // server TTL is much longer than this interval so a brief
        // hiccup is fine.
      }
    }, HEARTBEAT_MS);
    return () => window.clearInterval(id);
  }, [projectId, status.kind]);

  // beforeunload + cleanup release: closing the tab fires the
  // beacon so the next user doesn't wait the full TTL. Beacon is
  // best-effort — if it fails the server eventually expires us.
  useEffect(() => {
    if (!projectId) return;
    function onBeforeUnload() {
      if (statusRef.current.kind !== "holding") return;
      const url = `${import.meta.env.VITE_API_URL ?? ""}/v1/projects/${projectId}/lock`;
      // sendBeacon doesn't support DELETE directly, but we can hit
      // a POST-shaped variant. The server treats any authenticated
      // call to its DELETE handler as release; for the beacon we
      // POST to the same path with a body the server ignores. To
      // avoid that nuance, just fire a release via fetch with
      // keepalive — works on every modern browser.
      void fetch(url, { method: "DELETE", keepalive: true }).catch(() => {});
    }
    window.addEventListener("beforeunload", onBeforeUnload);
    return () => window.removeEventListener("beforeunload", onBeforeUnload);
  }, [projectId]);

  // Hard release on unmount (page navigation away).
  useEffect(() => {
    return () => {
      if (!projectId) return;
      if (statusRef.current.kind !== "holding") return;
      void api.releaseProjectLock(projectId).catch(() => {});
    };
  }, [projectId]);

  const acquire = useCallback(async () => {
    if (!projectId) return;
    try {
      const resp = await api.acquireProjectLock(projectId);
      setStatus({ kind: "holding", lock: resp.lock });
    } catch (e: unknown) {
      if (e instanceof ApiError && e.status === 409) {
        // Server returned the holder in `details.lock`.
        const detail = (e.details as { lock?: ProjectLock } | undefined)?.lock;
        if (detail) {
          setStatus({ kind: "read_only", lock: detail });
          return;
        }
      }
      setStatus({
        kind: "error",
        message:
          e instanceof ApiError ? `${e.errorCode}: ${e.message}` : "Acquire failed",
      });
    }
  }, [projectId]);

  const release = useCallback(async () => {
    if (!projectId) return;
    try {
      await api.releaseProjectLock(projectId);
    } catch {
      // Idempotent server-side; best-effort.
    }
    setStatus({ kind: "free" });
  }, [projectId]);

  const force = useCallback(async () => {
    if (!projectId) return;
    try {
      await api.forceReleaseProjectLock(projectId);
      setStatus({ kind: "free" });
    } catch (e: unknown) {
      setStatus({
        kind: "error",
        message:
          e instanceof ApiError ? `${e.errorCode}: ${e.message}` : "Force-release failed",
      });
    }
  }, [projectId]);

  const acknowledgeLost = useCallback(() => {
    setStatus({ kind: "free" });
  }, []);

  return { status, acquire, release, force, refresh: fetchOnce, acknowledgeLost };
}
