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
