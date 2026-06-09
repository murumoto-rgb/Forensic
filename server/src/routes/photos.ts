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
import { z } from "zod";
import type {
  ApiError,
  PhotoUrlResponse,
  PhotoUrlsBatchResponse,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";
import { presignedGet } from "../r2.js";
import { assertProjectAccess, sendAccessError } from "../access.js";

const DOWNLOAD_URL_TTL_SECONDS = 5 * 60;

// Hard cap on batch size. Picked to comfortably hold real-world
// inspection projects (Manandhar's ~1000) in one request while still
// bounding signing CPU per call. Clients with more photos should
// chunk; the web app does this automatically.
const MAX_BATCH_PHOTO_IDS = 1000;

const PhotoUrlsBatchBodySchema = z.object({
  photoIds: z.array(z.string().uuid()).min(1).max(MAX_BATCH_PHOTO_IDS),
  kind: z.enum(["thumb", "image"]),
});

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
  try {
    await assertProjectAccess(args.userId, args.projectId, "viewer");
  } catch (err) {
    if (err && typeof err === "object" && "status" in err && "code" in err) {
      const e = err as { status: number; code: string; message: string };
      return {
        ok: false,
        status: e.status,
        error: { error: e.code, message: e.message },
      };
    }
    return {
      ok: false,
      status: 500,
      error: { error: "internal", message: "Database error" },
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

  // -----------------------------------------------------------------
  // POST /v1/projects/:projectId/photo-urls
  //
  // Batch URL minting. Body: `{ photoIds: string[], kind: "thumb" | "image" }`.
  // Returns `{ urls: {photoId: url}, expiresAt }`. Up to 1000 IDs per
  // call. The single-photo GET endpoints above still exist for the
  // lightbox / single-photo paths; this is the high-throughput
  // sibling for grid renders.
  //
  // Replaces what was previously N parallel GETs from the web photo
  // grid (each one a separate auth + DB-lookup + R2-sign round trip)
  // with a single auth + single DB lookup + N local crypto sigs.
  // Crucial on Render's free tier where N=1000 concurrent requests
  // OOM'd the server and surfaced as 502s with stripped CORS headers
  // (Build #5.19.1 diagnosis).
  // -----------------------------------------------------------------
  app.post<{
    Params: { projectId: string };
    Body: unknown;
    Reply: PhotoUrlsBatchResponse | ApiError;
  }>("/v1/projects/:projectId/photo-urls", async (request, reply) => {
    const { projectId } = request.params;
    const parsed = PhotoUrlsBatchBodySchema.safeParse(request.body);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    const { photoIds, kind } = parsed.data;

    // Project-access gate. viewer is the lowest read role.
    try {
      await assertProjectAccess(request.user.id, projectId, "viewer");
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      request.log.error({ err, projectId }, "Project access check failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    // For `thumb` kind we want thumb-or-fallback-to-photo, same as
    // the single-photo endpoint. We fetch both kinds in one query
    // and pick per-photo below. For `image` we only need `photo`.
    const wantedKinds = kind === "thumb" ? ["thumb", "photo"] : ["photo"];

    // Fetch the file rows in chunks of photo IDs rather than one giant
    // `.in("photo_id", [all 944 ids])`. Two reasons (Build #5.20.1 hotfix
    // for the 500 "Database error" the single `.in()` produced on
    // Manandhar):
    //   1. supabase-js encodes `.in()` as a PostgREST query-string filter
    //      (`photo_id=in.(uuid,uuid,…)`). ~944 UUIDs is a ~35 KB URL,
    //      which blows past PostgREST/Kong's request-URI length limit and
    //      fails the request outright.
    //   2. PostgREST defaults to a 1000-row response cap. thumb+photo for
    //      ~1000 photos is up to ~2000 rows, so even if the URL fit, the
    //      tail would be silently truncated. Chunking at 100 photo IDs
    //      keeps each result set at ≤200 rows — comfortably under the cap.
    // Chunks run concurrently (server→Supabase, same region, fast).
    const DB_IN_CHUNK = 100;
    const idChunks: string[][] = [];
    for (let i = 0; i < photoIds.length; i += DB_IN_CHUNK) {
      idChunks.push(photoIds.slice(i, i + DB_IN_CHUNK));
    }

    type FileRow = { object_key: string; photo_id: string; kind: string };
    let files: FileRow[];
    try {
      const chunkResults = await Promise.all(
        idChunks.map(async (idChunk) => {
          const { data, error } = await supabaseAdmin
            .from("files")
            .select("object_key, photo_id, kind")
            .eq("project_id", projectId)
            .in("photo_id", idChunk)
            .in("kind", wantedKinds);
          if (error) throw error;
          return (data ?? []) as FileRow[];
        })
      );
      files = chunkResults.flat();
    } catch (err) {
      request.log.error({ err, projectId }, "Files lookup failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    // Map the DB's photo_id back to the EXACT id string the client
    // requested, preserving case. `files.photo_id` is a Postgres
    // `uuid` column, which returns its value in lowercase canonical
    // form (`a5f6e276-…`). But iOS manifests store photo IDs in
    // uppercase (`A5F6E276-…`), so the web sends uppercase IDs and
    // looks the response map up with `urls[photo.id]`. If we keyed
    // the response by the DB's lowercase id, every client lookup
    // would miss and the whole grid would show "pending" — which is
    // exactly the bug this fixes (Build #5.21.1). The DB match itself
    // is case-insensitive (uuid comparison), so the rows come back
    // fine; only the response key needs the requester's case.
    const requestedByLower = new Map<string, string>();
    for (const pid of photoIds) requestedByLower.set(pid.toLowerCase(), pid);

    // Pick the best key per photo: prefer "thumb" when present,
    // fall back to "photo" if not. For kind="image" this just picks
    // the "photo" row (the only one in `wantedKinds`).
    const preferred = new Map<string, string>(); // requestedPhotoId → object_key
    for (const row of files ?? []) {
      const rowPhotoId = row.photo_id as string;
      // Resolve back to the client's original-case id; fall back to
      // the DB value if somehow not in the request set (shouldn't
      // happen — we only queried ids the client sent).
      const photoId =
        requestedByLower.get(rowPhotoId.toLowerCase()) ?? rowPhotoId;
      const rowKind = row.kind as string;
      const objectKey = row.object_key as string;
      if (kind === "thumb") {
        const existing = preferred.get(photoId);
        // Promote thumb over photo; keep photo only if no thumb seen.
        if (rowKind === "thumb" || existing == null) {
          preferred.set(photoId, objectKey);
        }
      } else {
        if (rowKind === "photo") preferred.set(photoId, objectKey);
      }
    }

    // Sign URLs in parallel. `presignedGet` is local crypto — no
    // network — so Promise.all is fine; it just lets the SDK's
    // internal async hops interleave with each other. Microseconds
    // per call; even 1000 fits well inside Render's request budget.
    const entries = await Promise.all(
      Array.from(preferred.entries()).map(async ([photoId, key]) => {
        const url = await presignedGet({
          objectKey: key,
          expiresInSeconds: DOWNLOAD_URL_TTL_SECONDS,
        });
        return [photoId, url] as const;
      })
    );

    const urls: Record<string, string> = {};
    for (const [photoId, url] of entries) urls[photoId] = url;

    return {
      urls,
      expiresAt: new Date(Date.now() + DOWNLOAD_URL_TTL_SECONDS * 1000).toISOString(),
    };
  });
};
