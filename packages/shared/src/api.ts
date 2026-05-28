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
