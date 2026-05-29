/**
 * Thin client for the Forensic server. Attaches the current
 * Supabase session JWT (if any) to every request as a Bearer
 * token, and parses JSON responses.
 *
 * On 401: triggers a sign-out so the UI reverts to the login
 * page; this is the right behaviour for an expired/revoked
 * session that the auto-refresh somehow missed.
 */

import { env } from "./env";
import { supabase } from "./supabase";
import type {
  Project,
  GetManifestResponse,
  PhotoUrlResponse,
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

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
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
      // Stale session — drop it so the UI rerenders to login.
      await supabase.auth.signOut();
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
};
