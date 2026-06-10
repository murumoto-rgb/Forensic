import { useCallback, useEffect, useRef, useState } from "react";
import type { ProjectLock } from "@forensic/shared";
import { api, ApiError } from "./api";
import { env } from "./env";
import { supabase } from "./supabase";

/**
 * Web client for the project edit-lock model (Build #5.60.1; extended
 * for per-tab session tokens in #5.120.1 to fix the "back-button
 * self-lock" bug).
 *
 * Statuses:
 *  - **free** — no live lock; "Edit" button calls `acquire`.
 *  - **holding** — this tab holds the lock. A 90s heartbeat runs;
 *    server TTL is 10 min.
 *  - **holding_elsewhere** — same user holds the lock from another
 *    tab/device. "Resume here" calls `acquire` to take it.
 *  - **read_only** — someone else holds it.
 *  - **lock_lost** — heartbeat returned 409.
 *  - **error** — fetch failure surfaces the message.
 *
 * The bug fix: each browser tab gets a stable UUID stored in
 * `sessionStorage` (semantics: persists across same-tab navigations,
 * unique per tab). The lock row records it. On mount the hook sends
 * the token to GET /lock; the server returns `heldByYou`:
 *   - "session" → resume `holding` (the bug fix — back-nav return).
 *   - "user"    → `holding_elsewhere` (another tab/device).
 *   - null      → other user / free (existing behaviour).
 *
 * Release: on `pagehide` we fire a `navigator.sendBeacon` to the
 * beacon-friendly POST endpoint so closing the tab frees the lock
 * reliably (more reliable than the unmount cleanup or `beforeunload`,
 * which is cancelled on SPA nav). Even if the beacon doesn't land,
 * the session-resume above makes return-to-project correct anyway.
 */

export type LockStatus =
  | { kind: "loading" }
  | { kind: "free" }
  | { kind: "holding"; lock: ProjectLock }
  | { kind: "holding_elsewhere"; lock: ProjectLock }
  | { kind: "read_only"; lock: ProjectLock }
  | { kind: "lock_lost" }
  | { kind: "error"; message: string };

/** How often to heartbeat while holding. 90s × 6.6 heartbeats fits
 *  inside the server's 10-min TTL with margin for a slow request. */
const HEARTBEAT_MS = 90_000;
/** How often a non-holder re-polls so the viewer banner updates
 *  promptly when the holder disconnects. */
const POLL_MS = 30_000;

const SESSION_KEY = "forensic.lockSession";

/** Read or create the per-tab session token. Stable across same-tab
 *  back/forward navigation; unique per tab. */
function getTabSessionToken(): string {
  try {
    const existing = sessionStorage.getItem(SESSION_KEY);
    if (existing) return existing;
    const token = crypto.randomUUID();
    sessionStorage.setItem(SESSION_KEY, token);
    return token;
  } catch {
    // sessionStorage unavailable (private browsing edge cases) —
    // fall back to a per-mount token. Worse UX (no resume on
    // back-nav) but safe.
    return crypto.randomUUID();
  }
}

export function useProjectLock(projectId: string | null | undefined): {
  status: LockStatus;
  acquire: () => Promise<void>;
  release: () => Promise<void>;
  force: () => Promise<boolean>;
  refresh: () => Promise<void>;
  acknowledgeLost: () => void;
} {
  const [status, setStatus] = useState<LockStatus>({ kind: "loading" });
  const statusRef = useRef<LockStatus>(status);
  useEffect(() => {
    statusRef.current = status;
  }, [status]);

  // One token per tab, computed on first render and reused.
  const sessionTokenRef = useRef<string>(getTabSessionToken());

  // Cache the latest Supabase access token so the pagehide handler
  // can fire a synchronous authenticated keepalive fetch. The
  // `request()` path's `getAuthHeader` is async and we can't await
  // inside the pagehide synchronous window.
  const accessTokenRef = useRef<string | null>(null);
  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      accessTokenRef.current = data.session?.access_token ?? null;
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, session) => {
      accessTokenRef.current = session?.access_token ?? null;
    });
    return () => {
      sub.subscription.unsubscribe();
    };
  }, []);

  const fetchOnce = useCallback(async () => {
    if (!projectId) return;
    try {
      const resp = await api.getProjectLock(
        projectId,
        sessionTokenRef.current
      );
      // Preserve a `holding` status across a poll (the holder's
      // heartbeat is the live signal; the GET would otherwise
      // demote it briefly).
      if (statusRef.current.kind === "holding") return;
      if (resp.lock == null) {
        setStatus({ kind: "free" });
        return;
      }
      // Cloud-first lock: the server tells us if it's ours and from
      // which tab. Old servers omit `heldByYou` → treat as null.
      const held = resp.heldByYou ?? null;
      if (held === "session") {
        // Same user, same tab — back-nav return, or a re-mount that
        // raced our own release. Resume holding silently.
        setStatus({ kind: "holding", lock: resp.lock });
      } else if (held === "user") {
        setStatus({ kind: "holding_elsewhere", lock: resp.lock });
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

  // pagehide release via authenticated keepalive fetch — fires
  // reliably on tab close and on real navigation. Scoped to this
  // tab's session so closing tab A doesn't free tab B's lock.
  // (sendBeacon would be even more reliable but can't set the
  // Authorization header, so the server would 401 it.)
  useEffect(() => {
    if (!projectId) return;
    function onPageHide(): void {
      if (statusRef.current.kind !== "holding") return;
      const token = accessTokenRef.current;
      if (!token) return; // not signed in — server'd 401 anyway
      const url = `${env.API_URL}/v1/projects/${projectId}/lock/release`;
      const body = JSON.stringify({
        clientSession: sessionTokenRef.current,
      });
      void fetch(url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          Authorization: `Bearer ${token}`,
        },
        body,
        keepalive: true,
      }).catch(() => {});
    }
    window.addEventListener("pagehide", onPageHide);
    return () => window.removeEventListener("pagehide", onPageHide);
  }, [projectId]);

  // Soft release on unmount (SPA navigation away). Best-effort — the
  // session-resume on next mount makes return-to-project correct even
  // when this is cancelled.
  useEffect(() => {
    return () => {
      if (!projectId) return;
      if (statusRef.current.kind !== "holding") return;
      void api
        .releaseProjectLock(projectId, sessionTokenRef.current)
        .catch(() => {});
    };
  }, [projectId]);

  const acquire = useCallback(async () => {
    if (!projectId) return;
    try {
      const resp = await api.acquireProjectLock(
        projectId,
        sessionTokenRef.current
      );
      setStatus({ kind: "holding", lock: resp.lock });
    } catch (e: unknown) {
      if (e instanceof ApiError && e.status === 409) {
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
      await api.releaseProjectLock(projectId, sessionTokenRef.current);
    } catch {
      // Idempotent server-side; best-effort.
    }
    setStatus({ kind: "free" });
  }, [projectId]);

  // Returns true on success so the caller (LockBanner) only chains
  // the follow-up acquire when the force actually landed — otherwise
  // the acquire's re-fetch would instantly overwrite the error
  // banner (e.g. the Build #6.11.1 owner-or-admin 403) before the
  // user could read it.
  const force = useCallback(async (): Promise<boolean> => {
    if (!projectId) return false;
    try {
      await api.forceReleaseProjectLock(projectId);
      setStatus({ kind: "free" });
      return true;
    } catch (e: unknown) {
      setStatus({
        kind: "error",
        message:
          e instanceof ApiError
            ? e.status === 403
              ? e.message
              : `${e.errorCode}: ${e.message}`
            : "Force-release failed",
      });
      return false;
    }
  }, [projectId]);

  const acknowledgeLost = useCallback(() => {
    setStatus({ kind: "free" });
  }, []);

  return { status, acquire, release, force, refresh: fetchOnce, acknowledgeLost };
}

