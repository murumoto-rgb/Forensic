/**
 * REST API request/response shapes shared by server and clients.
 *
 * Phase 0 keeps this minimal — just a healthcheck and the eventual
 * shape of the manifest read/write. Real endpoints land in Phase 1.
 */

import type { Project } from "./manifest.ts";

export interface HealthzResponse {
  status: "ok";
  serverManifestSchemaVersion: number;
  /** Git commit SHA the running server was built from, if known
   *  (Render sets `RENDER_GIT_COMMIT`). Lets anyone confirm which
   *  build is live by hitting `/healthz` — e.g. after a deploy,
   *  check this matches the merge commit before testing. `null`
   *  when the env var isn't set (local dev). */
  gitSha: string | null;
  /** Short form of `gitSha` (first 7 chars) for quick eyeballing
   *  against GitHub's short SHAs. `null` when `gitSha` is. */
  gitShaShort: string | null;
}

export interface GetManifestResponse {
  project: Project;
  /** Opaque server-side revision string. Clients echo it on write to
   *  enable optimistic concurrency in Phase 1. */
  revision: string;
}

export interface PutManifestRequest {
  project: Project;
  /** Revision from the last GET. Server rejects with 409 on mismatch. */
  expectedRevision: string;
}

export interface PutManifestResponse {
  revision: string;
}

export interface ApiError {
  error: string;
  message: string;
  details?: unknown;
}

// ===========================================================================
// Phase 2 — Files (Cloudflare R2 via presigned URLs)
// ===========================================================================

/** Categories of binary we store. Mirrors the SQL CHECK constraint. */
export type FileKind =
  | "photo"
  | "thumb"
  | "markup_png"
  | "markup_drawing"
  | "plan";

/** Maximum size we'll accept for a single object (50 MB). */
export const FILE_MAX_BYTES = 50 * 1024 * 1024;

export interface UploadUrlRequest {
  photoId: string;
  kind: FileKind;
  sizeBytes: number;
  /** Optional content hash. Stored for future dedup / integrity. */
  sha256?: string;
  /** MIME type — clamped to the right family for the kind by the server. */
  contentType: string;
}

export interface UploadUrlResponse {
  uploadUrl: string;
  objectKey: string;
  expiresAt: string;
}

export interface CommitUploadRequest {
  objectKey: string;
  photoId: string;
  kind: FileKind;
  sizeBytes: number;
  sha256?: string;
}

export interface CommitUploadResponse {
  ok: true;
}

export interface SyncFilesCheckRequest {
  /** Object keys the client wants to verify against R2 + the registry. */
  objectKeys: string[];
}

export interface SyncFilesCheckResponse {
  /** Subset of input keys that already exist on the server. */
  existing: string[];
}

// ===========================================================================
// Phase 4 — AI tagging proxy (Build #5.32.1)
// ===========================================================================

/**
 * Models the server's `/v1/ai/tag-photo` endpoint accepts. iOS picks
 * from this list in the Settings sheet; the server validates against
 * it so a client typo can't bill cents per request to an unintended
 * model. Add new entries as Anthropic releases them — the underlying
 * Anthropic SDK call accepts any string the API recognizes.
 */
export type AITagPhotoModel =
  | "claude-sonnet-4-6"
  | "claude-haiku-4-5";

export interface AITagPhotoRequest {
  /** Project the photo lives in — used for ownership check + audit. */
  projectId: string;
  /** Photo whose bytes the server will fetch from R2 and pass to Anthropic. */
  photoId: string;
  /** Which Anthropic model to call. iOS Settings drives this. */
  model: AITagPhotoModel;
  /**
   * Full system prompt the client assembled (controlled vocabulary,
   * rules, output schema instructions, etc.).
   *
   * **Optional as of Build #5.46.1.** When omitted, the server
   * compiles the system prompt itself from the project's manifest
   * (read from the projects table) + the team's tag library and
   * AI rules template (read from `app_config`). Same
   * `compilePrompt(...)` shared logic the client uses, so the
   * output is byte-equivalent — the choice between client-side and
   * server-side compilation is a deployment / parity convenience,
   * not a behaviour difference.
   *
   * Clients that have their own customisation pipeline (current
   * iOS device-key path) keep sending the prompt themselves;
   * thin clients (future web admin tooling, ad-hoc CLIs) can
   * omit it and let the server do the work.
   */
  systemPrompt?: string;
  /**
   * User-message text accompanying the photo. Usually project
   * context + final per-photo instructions the client appends after
   * the system blocks.
   *
   * **Optional as of Build #5.46.1** for the same reason as
   * `systemPrompt`. When omitted, the server compiles the user
   * prompt via shared `compileUserPrompt(photo.imageFilename)`.
   */
  userText?: string;
  /**
   * Anthropic `max_tokens`. Optional — server defaults to 4096
   * (enough for a structured tag/analysis JSON; bump up for verbose
   * models). Capped server-side at 16384 so a client typo can't
   * force a 60-second response.
   */
  maxTokens?: number;
}

export interface AITagPhotoResponse {
  /**
   * Raw text the model emitted (concatenation of every `text`-type
   * content block). Client parses this into its own AIPhotoAnalysis
   * struct — server doesn't crack the schema open because iOS
   * already has a mature parser and we don't want to duplicate it.
   */
  rawText: string;
  /** Usage metrics straight from Anthropic, useful for cost tracking. */
  usage: {
    inputTokens: number;
    outputTokens: number;
    /**
     * Tokens that hit the Anthropic prompt cache (cheap, ~0.1×).
     * Will be 0 until iOS/web opt into prompt caching by adding
     * `cache_control` markers to the system prompt.
     */
    cacheReadTokens: number;
    /** Tokens written to the prompt cache this call (~1.25×). */
    cacheCreationTokens: number;
  };
  /** Wall-clock duration of the Anthropic call in milliseconds. */
  durationMs: number;
  /** Echoes back the model name for the client's audit log. */
  model: string;
}

export interface PhotoUrlResponse {
  /** Short-lived presigned R2 GET URL. Place into `<img src>` or
   *  fetch with URLSession directly — no auth header needed. */
  url: string;
  /** ISO date when the presigned URL stops working. */
  expiresAt: string;
}

/**
 * Batch counterpart of the single-photo URL endpoint. A photo grid
 * with N thumbnails would otherwise fire N parallel requests through
 * the server — on a free-tier Render instance with hundreds of
 * photos in a project that's a 502-storm waiting to happen
 * (Build #5.19.1 fix). This endpoint takes the photo IDs in one
 * round trip and returns a `{photoId: presignedUrl}` map.
 *
 * Up to 1000 photos per request. Server hard-caps any more.
 */
export interface PhotoUrlsBatchRequest {
  photoIds: string[];
  /** "thumb" returns thumbnails (falls back to the full photo if no
   *  separate thumb exists), "image" returns full-res originals. */
  kind: "thumb" | "image";
}

export interface PhotoUrlsBatchResponse {
  /** photoId → presigned URL. Missing IDs are simply absent from the
   *  map (no entry) — the client renders the same "pending" placeholder
   *  it would for an individual 404. */
  urls: Record<string, string>;
  /** ISO date when the presigned URLs in this response stop working.
   *  All URLs in one batch share the same expiry — the server uses
   *  the same TTL for every entry. */
  expiresAt: string;
}

// ===========================================================================
// Phase 4 — App-wide config sync (Build #5.35.1)
// ===========================================================================

import type { AppConfigKey, AppConfigValueByKey } from "./appConfig.js";

/**
 * Response shape for `GET /v1/config/:key`. The server returns 404
 * when no row exists yet (e.g. iOS hasn't pushed its tag library
 * yet on a fresh team), which clients treat as "fall back to
 * bundled defaults" rather than an error.
 */
export interface GetAppConfigResponse<K extends AppConfigKey = AppConfigKey> {
  key: K;
  value: AppConfigValueByKey[K];
  /** Opaque revision token. Clients echo on PUT for optimistic concurrency. */
  revision: string;
  /** ISO timestamp of the last write — useful for "X edited the tag
   *  library 2 minutes ago" UI affordances. */
  updatedAt: string;
}

/**
 * Bulk fetch — one round trip pulls every known key. Convenient on
 * iOS launch and on web first-load. Missing keys are absent from the
 * `entries` map (no 404 / null entry), letting clients merge with
 * their local defaults straight away.
 */
export interface GetAppConfigBundleResponse {
  entries: { [K in AppConfigKey]?: GetAppConfigResponse<K> };
}

export interface PutAppConfigRequest<K extends AppConfigKey = AppConfigKey> {
  value: AppConfigValueByKey[K];
  /** Last-known revision from a prior GET, or `null` for first push
   *  of this key. Mismatch → 409 so the caller pulls + merges
   *  rather than clobbering. */
  expectedRevision: string | null;
}

export interface PutAppConfigResponse {
  revision: string;
}
