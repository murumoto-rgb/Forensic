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
