/**
 * Thin client for the Forensic server. Attaches the current
 * Supabase session JWT (if any) to every request as a Bearer
 * token, and parses JSON responses.
 *
 * On 401: triggers a sign-out so the UI reverts to the login
 * page; this is the right behaviour for an expired/revoked
 * session that the auto-refresh somehow missed.
 *
 * Retry policy: every request retries up to 3 times on a
 * network-level failure (fetch threw — no HTTP response received).
 * Backoff: 2s → 5s → 10s. This covers Render free-tier
 * cold-starts where the container takes ~20-30 sec to spin up
 * after 15 min of idle. HTTP errors (4xx/5xx) are NEVER retried
 * — they're deterministic responses from a live server. Apply
 * at the centralized `request<T>` layer so every endpoint —
 * GET, POST, PUT — benefits without per-call wrapping.
 */

import { env } from "./env";
import { supabase, signOutLocal } from "./supabase";
import type {
  Project,
  GetManifestResponse,
  PhotoUrlResponse,
  PutManifestResponse,
} from "@forensic/shared";

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly errorCode: string,
    message: string,
    public readonly details?: unknown
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function getAuthHeader(): Promise<Record<string, string>> {
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  return jwt ? { Authorization: `Bearer ${jwt}` } : {};
}

// One attempt — never retries. Returns the parsed body on success;
// throws ApiError on HTTP error; lets the underlying fetch error
// propagate as a non-ApiError (network failure) so the outer retry
// loop can distinguish.
async function requestOnce<T>(path: string, init: RequestInit): Promise<T> {
  const auth = await getAuthHeader();
  const res = await fetch(`${env.API_URL}${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...auth,
      ...(init.headers ?? {}),
    },
  });

  let body: unknown = null;
  try {
    body = await res.json();
  } catch {
    // Some 5xx responses won't be JSON; leave body as null.
  }

  if (!res.ok) {
    if (res.status === 401) {
      // Stale session — drop it (this browser only) so the UI
      // rerenders to login. Local scope so an expired token here
      // doesn't revoke the user's iPhone session too.
      await signOutLocal();
    }
    const apiErr = body as { error?: string; message?: string; details?: unknown } | null;
    throw new ApiError(
      res.status,
      apiErr?.error ?? "unknown",
      apiErr?.message ?? `HTTP ${res.status}`,
      apiErr?.details
    );
  }

  return body as T;
}

// Backoff schedule applied to every request. First attempt is
// immediate (0ms); subsequent attempts wait. ApiErrors (HTTP) skip
// the retry loop entirely. Total ceiling: ~57 sec across 5 tries,
// which covers the worst-case Render free-tier cold-start (the
// keepalive cron should prevent these in practice; this is the
// safety net for when the cron itself misses a beat).
const RETRY_BACKOFFS_MS = [0, 2000, 5000, 10000, 15000, 25000];

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 0; attempt < RETRY_BACKOFFS_MS.length; attempt++) {
    const delay = RETRY_BACKOFFS_MS[attempt] ?? 0;
    if (delay > 0) {
      await new Promise((r) => setTimeout(r, delay));
    }
    try {
      return await requestOnce<T>(path, init);
    } catch (e: unknown) {
      if (e instanceof ApiError) throw e; // deterministic — don't retry
      lastErr = e;
      // Else: network-level (fetch threw). Try again after the next
      // backoff unless we've exhausted attempts.
    }
  }
  throw lastErr;
}

export interface ProjectListItem {
  id: string;
  name: string;
  manifestSchemaVersion: number;
  revision: string;
  createdAt: string;
  updatedAt: string;
}

export interface ProjectListResponse {
  projects: ProjectListItem[];
}

export type { Project, GetManifestResponse, PhotoUrlResponse };

export const api = {
  healthz: () =>
    request<{ status: string; serverManifestSchemaVersion: number }>(
      "/healthz"
    ),
  listProjects: () => request<ProjectListResponse>("/v1/projects"),
  getProject: (id: string) =>
    request<GetManifestResponse>(`/v1/projects/${id}`),
  getPhotoImageUrl: (projectId: string, photoId: string) =>
    request<PhotoUrlResponse>(
      `/v1/projects/${projectId}/photos/${photoId}/image`
    ),
  getPhotoThumbUrl: (projectId: string, photoId: string) =>
    request<PhotoUrlResponse>(
      `/v1/projects/${projectId}/photos/${photoId}/thumb`
    ),
  getPlanImageUrl: (projectId: string, planId: string) =>
    request<PhotoUrlResponse>(
      `/v1/projects/${projectId}/plans/${planId}/image`
    ),
  /**
   * Write a mutated project manifest. Server uses `expectedRevision`
   * for optimistic concurrency — pass the revision from the last
   * GET; server returns 409 if the row has moved (someone else
   * wrote in the meantime). On success, the response carries the
   * new revision; echo it on the next PUT.
   */
  putProject: (
    projectId: string,
    project: Project,
    expectedRevision: string
  ) =>
    request<PutManifestResponse>(`/v1/projects/${projectId}`, {
      method: "PUT",
      body: JSON.stringify({ project, expectedRevision }),
    }),
};
