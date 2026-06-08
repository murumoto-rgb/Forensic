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
  PhotoUrlsBatchResponse,
  PutManifestResponse,
  AITagPhotoModel,
  AITagPhotoRequest,
  AITagPhotoResponse,
  GetAppConfigResponse,
  GetAppConfigBundleResponse,
  TagLibrary,
  AIRulesTemplate,
  LockResponse,
  GetLockResponse,
  CreatePdfExportResponse,
  GetPdfExportResponse,
  PdfExportOptions,
  UploadUrlRequest,
  UploadUrlResponse,
  CommitUploadRequest,
  CommitUploadResponse,
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

export interface ListProjectsOptions {
  /** When true, returns trashed (soft-deleted) projects instead of
   *  active ones. Default false — list omits trashed projects, same
   *  as before this option existed. */
  trashed?: boolean;
}

export type { Project, GetManifestResponse, PhotoUrlResponse };

// Match the server's MAX_BATCH_PHOTO_IDS in routes/photos.ts. Anything
// over this is chunked transparently below.
const MAX_BATCH_PHOTO_IDS = 1000;

export const api = {
  healthz: () =>
    request<{ status: string; serverManifestSchemaVersion: number }>(
      "/healthz"
    ),
  listProjects: (opts: ListProjectsOptions = {}) =>
    request<ProjectListResponse>(
      `/v1/projects${opts.trashed ? "?trashed=true" : ""}`
    ),
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
   * Batch-fetch presigned URLs for a set of photos in one project.
   * Returns a `photoId → url` map; photos with no file in storage
   * are absent from the map (caller renders the same "pending"
   * placeholder it would for an individual 404).
   *
   * Chunks at 1000 (matches server's hard cap) so a project of any
   * size goes through transparently. Each chunk is one server
   * round-trip; results are merged client-side.
   */
  getPhotoUrlsBatch: async (
    projectId: string,
    photoIds: string[],
    kind: "thumb" | "image"
  ): Promise<{ urls: Record<string, string>; expiresAt: string }> => {
    if (photoIds.length === 0) {
      return { urls: {}, expiresAt: new Date().toISOString() };
    }
    const merged: Record<string, string> = {};
    let expiresAt = new Date().toISOString();
    for (let i = 0; i < photoIds.length; i += MAX_BATCH_PHOTO_IDS) {
      const chunk = photoIds.slice(i, i + MAX_BATCH_PHOTO_IDS);
      const resp = await request<PhotoUrlsBatchResponse>(
        `/v1/projects/${projectId}/photo-urls`,
        {
          method: "POST",
          body: JSON.stringify({ photoIds: chunk, kind }),
        }
      );
      Object.assign(merged, resp.urls);
      expiresAt = resp.expiresAt;
    }
    return { urls: merged, expiresAt };
  },
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
    expectedRevision: string | null
  ) =>
    request<PutManifestResponse>(`/v1/projects/${projectId}`, {
      method: "PUT",
      body: JSON.stringify({ project, expectedRevision }),
    }),
  /**
   * Restore a trashed project. Server reads the manifest, flips
   * `isDeleted` back to false, and returns the new revision.
   * No body. 404 if the project doesn't exist or isn't owned.
   */
  restoreProject: (projectId: string) =>
    request<PutManifestResponse>(`/v1/projects/${projectId}/restore`, {
      method: "POST",
    }),
  /**
   * Permanently delete a trashed project — reaps every blob, drops
   * the `files` rows, drops the `projects` row. Server returns 204
   * on success and 409 if the project isn't already trashed.
   */
  hardDeleteProject: async (projectId: string): Promise<void> => {
    const { data } = await supabase.auth.getSession();
    const jwt = data.session?.access_token;
    const resp = await fetch(
      `${env.API_URL}/v1/projects/${projectId}`,
      {
        method: "DELETE",
        headers: jwt ? { Authorization: `Bearer ${jwt}` } : {},
      }
    );
    if (resp.status === 204) return;
    let body: { error?: string; message?: string } | null = null;
    try {
      body = (await resp.json()) as { error?: string; message?: string };
    } catch {
      // 5xx may not be JSON.
    }
    throw new ApiError(
      resp.status,
      body?.error ?? "unknown",
      body?.message ?? `HTTP ${resp.status}`
    );
  },
  /**
   * Request a presigned PUT URL for a photo/plan/markup binary.
   * Caller uploads the file directly to R2, then calls
   * `commitUpload` to record the row.
   */
  requestUploadUrl: (
    projectId: string,
    req: UploadUrlRequest
  ): Promise<UploadUrlResponse> =>
    request<UploadUrlResponse>(
      `/v1/projects/${projectId}/files/upload-url`,
      { method: "POST", body: JSON.stringify(req) }
    ),
  /**
   * Record a completed upload in the server's `files` registry.
   * Server HEADs R2 to confirm the bytes landed before persisting.
   */
  commitUpload: (
    projectId: string,
    req: CommitUploadRequest
  ): Promise<CommitUploadResponse> =>
    request<CommitUploadResponse>(
      `/v1/projects/${projectId}/files/commit`,
      { method: "POST", body: JSON.stringify(req) }
    ),
  /**
   * Forward an AI-tagging request through the team-server proxy
   * (Build #5.37.1). Server fetches the photo bytes from R2 by
   * `photoId`, calls Anthropic with the team key, and returns the
   * concatenated text response. Caller parses via
   * `parseAIPhotoAnalysis` from `@forensic/shared`.
   */
  tagPhoto: (req: {
    projectId: string;
    photoId: string;
    model: AITagPhotoModel;
    systemPrompt: string;
    userText: string;
    maxTokens?: number;
  }) => {
    const body: AITagPhotoRequest = req;
    return request<AITagPhotoResponse>("/v1/ai/tag-photo", {
      method: "POST",
      body: JSON.stringify(body),
    });
  },
  /**
   * Bulk fetch every known app_config key. Used at app load so the
   * Re-tag button can compile the same vocabulary-scoped prompt iOS
   * produces — without round-tripping per key.
   */
  getAppConfigBundle: () =>
    request<GetAppConfigBundleResponse>("/v1/config"),
  /** Single-key fetch. Returns null on 404 (no value pushed yet). */
  getTagLibraryConfig: async (): Promise<GetAppConfigResponse<"tagLibrary"> | null> => {
    try {
      return await request<GetAppConfigResponse<"tagLibrary">>(
        "/v1/config/tagLibrary"
      );
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) return null;
      throw e;
    }
  },
  getAIRulesTemplateConfig: async (): Promise<GetAppConfigResponse<"aiRulesTemplate"> | null> => {
    try {
      return await request<GetAppConfigResponse<"aiRulesTemplate">>(
        "/v1/config/aiRulesTemplate"
      );
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) return null;
      throw e;
    }
  },
  getReportBrandingConfig: async (): Promise<GetAppConfigResponse<"reportBranding"> | null> => {
    try {
      return await request<GetAppConfigResponse<"reportBranding">>(
        "/v1/config/reportBranding"
      );
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) return null;
      throw e;
    }
  },
  /**
   * Read-only bundled-defaults snapshot pushed by iOS at every
   * launch (Build #5.48.1). Used by the admin editors' "Restore
   * default" button. 404 when the iOS app has never connected
   * since the new build — caller should fall back to a friendly
   * "no default available yet; open the iOS app once" message.
   */
  getTagLibraryDefaultConfig: async (): Promise<GetAppConfigResponse<"tagLibraryDefault"> | null> => {
    try {
      return await request<GetAppConfigResponse<"tagLibraryDefault">>(
        "/v1/config/tagLibraryDefault"
      );
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) return null;
      throw e;
    }
  },
  getAIRulesTemplateDefaultConfig: async (): Promise<GetAppConfigResponse<"aiRulesTemplateDefault"> | null> => {
    try {
      return await request<GetAppConfigResponse<"aiRulesTemplateDefault">>(
        "/v1/config/aiRulesTemplateDefault"
      );
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) return null;
      throw e;
    }
  },
  // -------------------- Project edit lock (Build #5.60.1) --------------------
  /** Current lock state for a project. `lock` is null when free. */
  getProjectLock: (projectId: string) =>
    request<GetLockResponse>(`/v1/projects/${projectId}/lock`),
  /** Acquire — 409 ApiError when held live by another user; the
   *  envelope's `details.lock` carries the holder for the conflict
   *  banner. */
  acquireProjectLock: (projectId: string) =>
    request<LockResponse>(`/v1/projects/${projectId}/lock`, {
      method: "POST",
      body: JSON.stringify({ client: "web" }),
    }),
  /** Bump expiry — 409 `lock_lost` if we're no longer the holder. */
  heartbeatProjectLock: (projectId: string) =>
    request<LockResponse>(`/v1/projects/${projectId}/lock/heartbeat`, {
      method: "POST",
    }),
  /** Release (holder-only on the server; idempotent). */
  releaseProjectLock: (projectId: string) =>
    request<{ ok: true }>(`/v1/projects/${projectId}/lock`, {
      method: "DELETE",
    }),
  /** Force-release — any signed-in user for now (no admin role
   *  yet). Server logs at warn so it's traceable. */
  forceReleaseProjectLock: (projectId: string) =>
    request<{ ok: true }>(`/v1/projects/${projectId}/lock/force`, {
      method: "POST",
    }),
  // -------------------- PDF export (Build #5.62.1) ------------------
  /** Enqueue a PDF render. Returns immediately with a job handle the
   *  caller polls via `getPdfExport`. `options` is optional — the
   *  server fills in defaults when fields are omitted. */
  createPdfExport: (projectId: string, options?: Partial<PdfExportOptions>) =>
    request<CreatePdfExportResponse>(
      `/v1/projects/${projectId}/export/pdf`,
      { method: "POST", body: JSON.stringify({ options: options ?? {} }) }
    ),
  /** Poll for status. When `job.status === "done"`, `downloadUrl` is
   *  a short-lived presigned R2 URL the browser can hit directly. */
  getPdfExport: (jobId: string) =>
    request<GetPdfExportResponse>(`/v1/exports/${jobId}`),
};

// Re-export for callers that need the wire types.
export type { TagLibrary, AIRulesTemplate };
