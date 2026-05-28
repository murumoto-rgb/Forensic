/**
 * Photo download endpoints.
 *
 *   GET /v1/projects/:projectId/photos/:photoId/image  → JSON {url, expiresAt}
 *   GET /v1/projects/:projectId/photos/:photoId/thumb  → JSON {url, expiresAt}
 *
 * Server validates ownership of the project, looks up the registered
 * object key in the `files` table, and returns a JSON envelope with
 * a 5-minute presigned R2 GET URL. The client (web `<img>` or iOS
 * URLSession) then fetches the bytes directly from R2 — no auth
 * header needed on the second hop.
 *
 * We deliberately return JSON instead of a 302 redirect because
 * browsers don't include `Authorization` headers on the initial
 * `<img src>` request, which would 401 the redirect endpoint.
 * JSON-with-URL is the simpler representation for both clients.
 *
 * If a thumb wasn't uploaded separately, falls back to the full image.
 * iOS Phase 2 uploads only `photo`; thumb generation lands in a
 * later phase if performance becomes an issue.
 */

import type { FastifyPluginAsync } from "fastify";
import type { ApiError, PhotoUrlResponse } from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";
import { presignedGet } from "../r2.js";

const DOWNLOAD_URL_TTL_SECONDS = 5 * 60;

interface PhotoParams {
  projectId: string;
  photoId: string;
}

/**
 * Validate the caller owns the project, then look up an object key
 * for the given photo + kind. Returns the key on success or sends
 * the appropriate error reply (caller must `return` immediately).
 *
 * Strategy: try the preferred kind first; if it doesn't exist and a
 * fallback is provided, try that. Used by the thumb endpoint to fall
 * back to the full image.
 */
async function resolveObjectKey(args: {
  projectId: string;
  photoId: string;
  userId: string;
  preferredKind: string;
  fallbackKind?: string;
}): Promise<{ ok: true; key: string } | { ok: false; status: number; error: ApiError }> {
  const { data: project, error: projectErr } = await supabaseAdmin
    .from("projects")
    .select("id")
    .eq("id", args.projectId)
    .eq("owner_id", args.userId)
    .maybeSingle();
  if (projectErr) {
    return {
      ok: false,
      status: 500,
      error: { error: "internal", message: "Database error" },
    };
  }
  if (!project) {
    return {
      ok: false,
      status: 404,
      error: { error: "not_found", message: `Project ${args.projectId} not found` },
    };
  }

  // Preferred kind first.
  const kinds = args.fallbackKind
    ? [args.preferredKind, args.fallbackKind]
    : [args.preferredKind];

  const { data: files, error: filesErr } = await supabaseAdmin
    .from("files")
    .select("object_key, kind")
    .eq("project_id", args.projectId)
    .eq("photo_id", args.photoId)
    .in("kind", kinds);
  if (filesErr) {
    return {
      ok: false,
      status: 500,
      error: { error: "internal", message: "Database error" },
    };
  }

  for (const kind of kinds) {
    const match = (files ?? []).find((f) => f.kind === kind);
    if (match) return { ok: true, key: match.object_key as string };
  }

  return {
    ok: false,
    status: 404,
    error: {
      error: "not_found",
      message: `Photo ${args.photoId} has no ${args.preferredKind} object in storage`,
    },
  };
}

async function presignedUrlEnvelope(objectKey: string): Promise<PhotoUrlResponse> {
  const url = await presignedGet({
    objectKey,
    expiresInSeconds: DOWNLOAD_URL_TTL_SECONDS,
  });
  const expiresAt = new Date(Date.now() + DOWNLOAD_URL_TTL_SECONDS * 1000).toISOString();
  return { url, expiresAt };
}

export const photosRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  app.get<{ Params: PhotoParams; Reply: PhotoUrlResponse | ApiError }>(
    "/v1/projects/:projectId/photos/:photoId/image",
    async (request, reply) => {
      const resolved = await resolveObjectKey({
        projectId: request.params.projectId,
        photoId: request.params.photoId,
        userId: request.user.id,
        preferredKind: "photo",
      });
      if (!resolved.ok) {
        reply.code(resolved.status).send(resolved.error);
        return;
      }
      return await presignedUrlEnvelope(resolved.key);
    }
  );

  app.get<{ Params: PhotoParams; Reply: PhotoUrlResponse | ApiError }>(
    "/v1/projects/:projectId/photos/:photoId/thumb",
    async (request, reply) => {
      const resolved = await resolveObjectKey({
        projectId: request.params.projectId,
        photoId: request.params.photoId,
        userId: request.user.id,
        preferredKind: "thumb",
        fallbackKind: "photo", // thumb missing? serve full image
      });
      if (!resolved.ok) {
        reply.code(resolved.status).send(resolved.error);
        return;
      }
      return await presignedUrlEnvelope(resolved.key);
    }
  );
};
