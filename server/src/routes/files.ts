/**
 * File-management endpoints for the Cloudflare R2 object store.
 *
 *   POST /v1/projects/:id/files/upload-url   → issue presigned PUT URL
 *   POST /v1/projects/:id/files/commit       → record successful upload
 *   POST /v1/sync/files/check                → batch existence check
 *
 * All three require auth and project ownership. The actual binary
 * never flows through the server — clients PUT directly to R2 using
 * the presigned URL, then call commit to record the row in the
 * `files` table. The server is the access-control layer; R2 is the
 * data plane.
 */

import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import {
  FILE_MAX_BYTES,
  type UploadUrlResponse,
  type CommitUploadResponse,
  type SyncFilesCheckResponse,
  type ApiError,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { clientSession, sendTransactionError } from "../projectTransactions.js";
import { authPlugin } from "../middleware/auth.js";
import { assertProjectAccess, assertProjectMutable, isOrgAdmin, sendAccessError } from "../access.js";
import { buildObjectKey, inspectObject, presignedPut, presignedGet } from "../r2.js";

const FileKindSchema = z.enum([
  "photo",
  "thumb",
  "markup_png",
  "markup_drawing",
  "plan",
]);

const UploadUrlBodySchema = z.object({
  photoId: z.string().uuid(),
  kind: FileKindSchema,
  sizeBytes: z.number().int().positive().max(FILE_MAX_BYTES),
  sha256: z.string().optional(),
  contentType: z.string().min(1).max(255),
  sourceFilename: z.string().min(1).max(512).optional(),
  immutable: z.boolean().default(false),
});

const CommitUploadBodySchema = z.object({
  objectKey: z.string().min(1),
  photoId: z.string().uuid(),
  kind: FileKindSchema,
  sizeBytes: z.number().int().positive().max(FILE_MAX_BYTES),
  sha256: z.string().optional(),
  sourceFilename: z.string().min(1).max(512).optional(),
  immutable: z.boolean().default(false),
});

const SyncFilesCheckBodySchema = z.object({
  objectKeys: z.array(z.string().min(1)).max(500),
});

const UPLOAD_URL_TTL_SECONDS = 15 * 60;

/**
 * Confirm the calling user owns the named project. Returns `true` if
 * the project exists and is owned by the caller; `false` if not
 * (handler responds 404 — don't leak existence of someone else's
 * project).
 */
// Build #5.123.1: access checks moved to the central
// `assertProjectAccess` helper (editor for upload/commit; viewer for
// the sync/check endpoint).

export const filesRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  app.get<{ Params: { id: string; entityId: string; kind: string }; Querystring: { filename?: string } }>(
    "/v1/projects/:id/files/:entityId/:kind", async (request, reply) => {
      const { id, entityId, kind } = request.params;
      if (!FileKindSchema.safeParse(kind).success || !z.string().uuid().safeParse(id).success || !z.string().uuid().safeParse(entityId).success) {
        return reply.code(400).send({ error: "bad_request", message: "Invalid asset identifier" });
      }
      try { await assertProjectAccess(request.user.id, id, "viewer", request); }
      catch (err) { if (sendAccessError(reply, err)) return; throw err; }
      const { data, error } = await supabaseAdmin.from("current_project_files")
        .select("object_key, source_filename").eq("project_id", id).eq("photo_id", entityId).eq("kind", kind).maybeSingle();
      if (error) throw error;
      if (!data) return reply.code(404).send({ error: "not_found", message: "Asset is not registered for this manifest" });
      if (request.query.filename !== undefined && request.query.filename !== data.source_filename) {
        return reply.code(409).send({ error: "revision_mismatch", message: "The asset filename changed. Refresh the manifest before downloading." });
      }
      const url = await presignedGet({ objectKey: data.object_key as string, expiresInSeconds: 300 });
      return { url, expiresAt: new Date(Date.now() + 300000).toISOString() };
    }
  );

  // -----------------------------------------------------------------
  // POST /v1/projects/:id/files/upload-url
  // -----------------------------------------------------------------
  app.post<{
    Params: { id: string };
    Body: unknown;
    Reply: UploadUrlResponse | ApiError;
  }>("/v1/projects/:id/files/upload-url", async (request, reply) => {
    const projectId = request.params.id.toLowerCase();
    const parsed = UploadUrlBodySchema.safeParse(request.body);
    if (!parsed.success) {
      request.log.warn(
        { projectId, issues: parsed.error.issues },
        "POST /files/upload-url zod validation failed"
      );
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    if (!parsed.data.immutable || !parsed.data.sourceFilename) {
      reply.code(426).send({ error: "upgrade_required", message: "Update the app: immutable uploads with sourceFilename are required to protect evidence history." }); return;
    }
    const { kind, sizeBytes, contentType, immutable } = parsed.data;
    const photoId = parsed.data.photoId.toLowerCase();

    const objectKey = buildObjectKey({ projectId, photoId, kind, ...(immutable ? { uploadId: crypto.randomUUID() } : {}) });
    const { data: receipt, error: receiptError } = await supabaseAdmin.rpc("issue_upload_receipt", {
      pid: projectId, actor: request.user.id, entity: photoId, file_kind: kind,
      filename: parsed.data.sourceFilename, key: objectKey, bytes: sizeBytes,
      hash: parsed.data.sha256 ?? null, ttl_seconds: UPLOAD_URL_TTL_SECONDS,
      session: clientSession(request),
    });
    if (receiptError) throw receiptError;
    if (sendTransactionError(reply, receipt)) return;
    let uploadUrl: string;
    try {
      uploadUrl = await presignedPut({
        objectKey,
        contentType,
        contentLength: sizeBytes,
        expiresInSeconds: UPLOAD_URL_TTL_SECONDS,
        ...(immutable ? { ifNoneMatch: "*" } : {}),
      });
    } catch (err) {
      request.log.error({ err, objectKey }, "Failed to presign R2 PUT");
      reply.code(500).send({ error: "internal", message: "Storage error" });
      return;
    }

    const expiresAt = new Date(Date.now() + UPLOAD_URL_TTL_SECONDS * 1000).toISOString();
    return { uploadUrl, objectKey, expiresAt, ...(immutable ? { requiredHeaders: { "if-none-match": "*" } } : {}) };
  });

  // -----------------------------------------------------------------
  // POST /v1/projects/:id/files/commit
  // -----------------------------------------------------------------
  app.post<{
    Params: { id: string };
    Body: unknown;
    Reply: CommitUploadResponse | ApiError;
  }>("/v1/projects/:id/files/commit", async (request, reply) => {
    const projectId = request.params.id.toLowerCase();
    const parsed = CommitUploadBodySchema.safeParse(request.body);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    const body = { ...parsed.data, photoId: parsed.data.photoId.toLowerCase() };
    if (!body.immutable || !body.sourceFilename) {
      reply.code(426).send({ error: "upgrade_required", message: "Update the app: immutable uploads with sourceFilename are required to protect evidence history." }); return;
    }

    // The object key must match the project / photo / kind tuple
    // exactly. Prevents a caller from committing arbitrary keys
    // they don't own.
    const legacyKey = buildObjectKey({
      projectId,
      photoId: body.photoId,
      kind: body.kind,
    });
    const newKeyPrefix = `${legacyKey}/`;
    const isLegacyKey = body.objectKey === legacyKey;
    const isNewKey = body.objectKey.startsWith(newKeyPrefix) &&
      /^[0-9a-f-]{36}$/.test(body.objectKey.slice(newKeyPrefix.length));
    if (!isLegacyKey && !isNewKey) {
      reply.code(400).send({
        error: "bad_request",
        message: `Object key (${body.objectKey}) doesn't match the project/photo/kind upload scope`,
      });
      return;
    }
    if (body.immutable !== isNewKey) {
      reply.code(400).send({ error: "bad_request", message: "Immutable commits must use a versioned upload key." });
      return;
    }

    // Commit is an edit intent.
    try {
      await assertProjectMutable(request.user.id, projectId, request);
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      request.log.error({ err, projectId }, "files commit — access check failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    // HEAD distinguishes a missing object from an unavailable object store and
    // checks the declared length. Client sha256 is not a verified content hash.
    const object = await inspectObject(body.objectKey);
    if (object.state !== "available" || object.sizeBytes !== body.sizeBytes) {
      reply.code(409).send({ error: "not_uploaded", message: "Upload is missing, unverifiable, or its byte length does not match." }); return;
    }
    const { data, error } = await supabaseAdmin.rpc("commit_upload_receipt", {
      pid: projectId, actor: request.user.id, entity: body.photoId, file_kind: body.kind,
      filename: body.sourceFilename, key: body.objectKey, bytes: body.sizeBytes,
      hash: body.sha256 ?? null, session: clientSession(request),
    });
    if (error) throw error;
    if (!data) throw new Error("File commit returned no result");
    if (sendTransactionError(reply, data)) return;

    return { ok: true };
  });

  // -----------------------------------------------------------------
  // POST /v1/sync/files/check — batch existence
  // -----------------------------------------------------------------
  //
  // Implementation note: the client may send up to 500 object keys
  // per request (matching its `SyncFilesCheckBodySchema.objectKeys
  // .max(500)`). Supabase PostgREST URL-encodes the `.in(...)`
  // filter into the request URL, and at 500 × ~80-char keys the URL
  // overflows typical 8 KB length limits → 500 "Database error".
  // (Reported by PhotoSyncer's pre-check on Cabral / Manandhar in
  // Build #5.51.1 sessions; fixed in #5.55.1.) We chunk into smaller
  // sub-batches server-side and merge results. SUB_BATCH_SIZE is
  // chosen to keep the encoded URL well under 4 KB even at the
  // widest key shape we ship today.
  const SUB_BATCH_SIZE = 50;
  app.post<{
    Body: unknown;
    Reply: SyncFilesCheckResponse | ApiError;
  }>("/v1/sync/files/check", async (request, reply) => {
    const parsed = SyncFilesCheckBodySchema.safeParse(request.body);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    const { objectKeys } = parsed.data;
    if (objectKeys.length === 0) return { existing: [] };

    // Phase 3 (Build #5.123.1): the caller can verify file existence
    // for projects they OWN, are MEMBER of, or — if they're an org
    // admin — any project. Precompute the user's accessible-project
    // set once so the per-row filter is a Map lookup, not an
    // owner_id string compare.
    const uid = request.user.id;
    const callerIsAdmin = await isOrgAdmin(uid, request);
    let memberIds = new Set<string>();
    if (!callerIsAdmin) {
      const { data: memberRows, error: memberErr } = await supabaseAdmin
        .from("project_members")
        .select("project_id")
        .eq("user_id", uid);
      if (memberErr) {
        request.log.error({ err: memberErr }, "files/check member lookup failed");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
      memberIds = new Set((memberRows ?? []).map((r) => r.project_id as string));
    }

    const existing: string[] = [];
    for (let i = 0; i < objectKeys.length; i += SUB_BATCH_SIZE) {
      const chunk = objectKeys.slice(i, i + SUB_BATCH_SIZE);
      const { data, error } = await supabaseAdmin
        .from("files")
        .select("object_key, project_id, projects!inner(owner_id)")
        .in("object_key", chunk);
      if (error) {
        request.log.error(
          { err: error, chunkOffset: i, chunkSize: chunk.length },
          "Files-check sub-batch query failed"
        );
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
      for (const row of data ?? []) {
        const joined = (row as unknown as {
          projects: { owner_id: string } | { owner_id: string }[] | null;
        }).projects;
        const owner = Array.isArray(joined) ? joined[0] : joined;
        const ownerId = owner?.owner_id;
        const projectId = row.project_id as string;
        if (
          callerIsAdmin ||
          ownerId === uid ||
          memberIds.has(projectId)
        ) {
          existing.push(row.object_key as string);
        }
      }
    }

    return { existing };
  });
};
