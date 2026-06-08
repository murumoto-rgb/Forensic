/**
 * Unified exports route (Build #5.97.1).
 *
 * Replaces the in-flight-only PDF export surface with a durable
 * Exports registry covering all three kinds — PDF, Folder by
 * Bucket, AI Analysis CSV.
 *
 *   POST   /v1/projects/:id/exports        → enqueue a new export
 *   GET    /v1/projects/:id/exports        → list every export for project
 *   GET    /v1/exports/:exportId           → status + signed download URL
 *   DELETE /v1/exports/:exportId           → delete row + R2 blob
 *
 * The legacy `POST /v1/projects/:id/export/pdf` + `GET /v1/exports/:jobId`
 * routes (Build #5.62.1, `exports.ts`) stay alongside this — PDFs are
 * still routed through `pdf_export_jobs` for now to keep the existing
 * worker untouched. PR #2 unifies via a thin adapter on the client.
 */

import type { FastifyPluginAsync } from "fastify";
import {
  CreateProjectExportSchema,
  type ApiError,
  type CreateProjectExportResponse,
  type ExportStatus,
  type FolderExportManifestBucket,
  type FolderExportManifestPhoto,
  type FolderExportManifestPlan,
  type GetFolderExportManifestResponse,
  type GetProjectExportResponse,
  type ListProjectExportsResponse,
  type Photo,
  type Project,
  type ProjectExport,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";
import { deleteObjects, presignedGet } from "../r2.js";

const DOWNLOAD_URL_TTL_SECONDS = 300; // 5 min

interface ExportRow {
  id: string;
  project_id: string;
  created_by: string;
  kind: "pdf" | "folder" | "csv";
  status: ExportStatus;
  object_key: string | null;
  size_bytes: number | null;
  options: Record<string, unknown>;
  error_message: string | null;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  progress_done: number | null;
  progress_total: number | null;
}

/** Filesystem-safe filename — same shape as the server-side
 *  worker uses. */
function safeName(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return "untitled";
  return trimmed
    .replace(/[/\\?%*:|"<>]/g, "-")
    .replace(/\s+/g, " ")
    .slice(0, 80);
}

function photoManifestEntry(
  project: Project,
  photo: Photo,
  presignedUrl: string
): FolderExportManifestPhoto {
  const ts = new Date(photo.timestamp);
  const yy = String(ts.getUTCFullYear()).slice(2);
  const mm = String(ts.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(ts.getUTCDate()).padStart(2, "0");
  const dateStr = `${yy}${mm}${dd}`;
  const ext = photo.imageFilename.split(".").pop() ?? "jpg";
  const filename = `${safeName(project.name)} - ${photo.sequenceNumber} - ${dateStr}.${ext}`;
  const visibleTags = photo.tags
    .filter((t) => t.confidence >= 0.5)
    .map((t) => t.label);
  return {
    id: photo.id,
    presignedUrl,
    filename,
    bucketId: photo.bucketID,
    sequenceNumber: photo.sequenceNumber,
    timestamp: photo.timestamp,
    userCaption: photo.userCaption,
    userObservation: photo.userObservation,
    aiSummary: photo.aiAnalysis?.summaryObservation ?? null,
    tags: visibleTags,
  };
}

function rowToProjectExport(row: ExportRow): ProjectExport {
  return {
    id: row.id,
    projectId: row.project_id,
    kind: row.kind,
    status: row.status,
    objectKey: row.object_key,
    sizeBytes: row.size_bytes,
    progressDone: row.progress_done ?? null,
    progressTotal: row.progress_total ?? null,
    errorMessage: row.error_message,
    createdAt: row.created_at,
    startedAt: row.started_at,
    completedAt: row.completed_at,
  };
}

export const projectExportsRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  async function callerOwnsProject(
    projectId: string,
    userId: string
  ): Promise<boolean> {
    const { data, error } = await supabaseAdmin
      .from("projects")
      .select("id")
      .eq("id", projectId)
      .eq("owner_id", userId)
      .maybeSingle();
    if (error) throw error;
    return data != null;
  }

  // -----------------------------------------------------------------
  // POST /v1/projects/:id/exports — enqueue a new export.
  //
  // Body: `{ kind: "pdf" | "folder" | "csv", options?: Record<string, unknown> }`.
  //
  // Per-kind option shape is enforced by the corresponding worker
  // (loose validation here keeps the route from drifting every time a
  // worker gains a new toggle).
  // -----------------------------------------------------------------
  app.post<{
    Params: { id: string };
    Body: unknown;
    Reply: CreateProjectExportResponse | ApiError;
  }>("/v1/projects/:id/exports", async (request, reply) => {
    const projectId = request.params.id;
    const parsed = CreateProjectExportSchema.safeParse(request.body);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }

    try {
      if (!(await callerOwnsProject(projectId, request.user.id))) {
        reply.code(404).send({ error: "not_found", message: `Project ${projectId} not found` });
        return;
      }
    } catch (err) {
      request.log.error({ err, projectId }, "project_exports — ownership check failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from("project_exports")
      .insert({
        project_id: projectId,
        created_by: request.user.id,
        kind: parsed.data.kind,
        status: "queued" as ExportStatus,
        options: parsed.data.options ?? {},
      })
      .select("*")
      .maybeSingle();
    if (error || !data) {
      request.log.error({ err: error, projectId }, "project_exports — enqueue failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    request.log.info(
      { exportId: (data as ExportRow).id, projectId, kind: parsed.data.kind },
      "project_exports enqueued"
    );
    return { export: rowToProjectExport(data as ExportRow) };
  });

  // -----------------------------------------------------------------
  // GET /v1/projects/:id/exports — list every export for the project.
  // -----------------------------------------------------------------
  app.get<{
    Params: { id: string };
    Reply: ListProjectExportsResponse | ApiError;
  }>("/v1/projects/:id/exports", async (request, reply) => {
    const projectId = request.params.id;

    try {
      if (!(await callerOwnsProject(projectId, request.user.id))) {
        reply.code(404).send({ error: "not_found", message: `Project ${projectId} not found` });
        return;
      }
    } catch (err) {
      request.log.error({ err, projectId }, "project_exports — ownership check failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from("project_exports")
      .select("*")
      .eq("project_id", projectId)
      .eq("created_by", request.user.id)
      .order("created_at", { ascending: false });
    if (error) {
      request.log.error({ err: error, projectId }, "project_exports — list failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    return {
      exports: (data ?? []).map((r) => rowToProjectExport(r as ExportRow)),
    };
  });

  // -----------------------------------------------------------------
  // GET /v1/exports/v2/:exportId — single export + download URL.
  //
  // (`/v1/exports/:jobId` is the legacy PDF endpoint; this lives on
  // a `v2` segment to avoid colliding.)
  // -----------------------------------------------------------------
  app.get<{
    Params: { exportId: string };
    Reply: GetProjectExportResponse | ApiError;
  }>("/v1/exports/v2/:exportId", async (request, reply) => {
    const exportId = request.params.exportId;
    const { data, error } = await supabaseAdmin
      .from("project_exports")
      .select("*")
      .eq("id", exportId)
      .maybeSingle();
    if (error) {
      request.log.error({ err: error, exportId }, "project_exports — read failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    const row = data as ExportRow | null;
    if (!row || row.created_by !== request.user.id) {
      reply.code(404).send({ error: "not_found", message: `Export ${exportId} not found` });
      return;
    }

    let downloadUrl: string | null = null;
    let downloadUrlExpiresAt: string | null = null;
    if (row.status === "done" && row.object_key) {
      try {
        downloadUrl = await presignedGet({
          objectKey: row.object_key,
          expiresInSeconds: DOWNLOAD_URL_TTL_SECONDS,
        });
        downloadUrlExpiresAt = new Date(
          Date.now() + DOWNLOAD_URL_TTL_SECONDS * 1000
        ).toISOString();
      } catch (err) {
        request.log.error({ err, exportId }, "project_exports — presign failed");
      }
    }

    return {
      export: rowToProjectExport(row),
      downloadUrl,
      downloadUrlExpiresAt,
    };
  });

  // -----------------------------------------------------------------
  // GET /v1/projects/:id/folder-export-manifest — client-side ZIP
  // manifest (Build #5.110.1).
  //
  // Returns a flat list of presigned R2 URLs the browser uses to
  // download every photo + plan + sidecar metadata. The browser
  // builds the ZIP locally via JSZip — taking the streaming work
  // off the Render dyno entirely.
  //
  // No body. Optional `?scope=all|filtered|selected` + repeated
  // `?photoId=` for selected mode. For now this PR ships
  // `scope=all` only; filter/selected scoping comes from a
  // follow-on when the Photos tab wires it.
  //
  // Presigned URLs have a 15-minute TTL — long enough for slow
  // connections to finish a 1.5GB download; renew by re-calling
  // the endpoint.
  // -----------------------------------------------------------------
  app.get<{
    Params: { id: string };
    Reply: GetFolderExportManifestResponse | ApiError;
  }>("/v1/projects/:id/folder-export-manifest", async (request, reply) => {
    const projectId = request.params.id;

    try {
      if (!(await callerOwnsProject(projectId, request.user.id))) {
        reply.code(404).send({ error: "not_found", message: `Project ${projectId} not found` });
        return;
      }
    } catch (err) {
      request.log.error({ err, projectId }, "folder-export-manifest — ownership check failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    // Read manifest.
    const { data: projectRow, error: projErr } = await supabaseAdmin
      .from("projects")
      .select("manifest")
      .eq("id", projectId)
      .maybeSingle();
    if (projErr || !projectRow) {
      reply.code(500).send({ error: "internal", message: "Manifest read failed" });
      return;
    }
    const project = projectRow.manifest as unknown as Project;

    // Look up R2 keys for every photo + plan in one query each
    // (case-safe via lowercase compare).
    const photoIds = project.photos.map((p) => p.id);
    const planIds = project.floorPlans.map((p) => p.id);

    const { data: photoFileRows, error: photoErr } = await supabaseAdmin
      .from("files")
      .select("photo_id, object_key, size_bytes")
      .eq("project_id", projectId)
      .in("photo_id", photoIds)
      .eq("kind", "photo");
    if (photoErr) {
      request.log.error({ err: photoErr, projectId }, "manifest — photo files lookup failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    const { data: planFileRows, error: planErr } = await supabaseAdmin
      .from("files")
      .select("photo_id, object_key, size_bytes")
      .eq("project_id", projectId)
      .in("photo_id", planIds)
      .eq("kind", "plan");
    if (planErr) {
      request.log.error({ err: planErr, projectId }, "manifest — plan files lookup failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    interface FileLookup {
      objectKey: string;
      sizeBytes: number;
    }
    const photoFileByIdLower = new Map<string, FileLookup>();
    for (const row of photoFileRows ?? []) {
      const r = row as { photo_id: string; object_key: string; size_bytes: number | null };
      photoFileByIdLower.set(r.photo_id.toLowerCase(), {
        objectKey: r.object_key,
        sizeBytes: r.size_bytes ?? 0,
      });
    }
    const planFileByIdLower = new Map<string, FileLookup>();
    for (const row of planFileRows ?? []) {
      const r = row as { photo_id: string; object_key: string; size_bytes: number | null };
      planFileByIdLower.set(r.photo_id.toLowerCase(), {
        objectKey: r.object_key,
        sizeBytes: r.size_bytes ?? 0,
      });
    }

    // Build the bucket folder mapping (matches iOS naming).
    const bucketsSorted = [...project.buckets].sort(
      (a, b) => a.sortOrder - b.sortOrder
    );
    const buckets: FolderExportManifestBucket[] = bucketsSorted.map((b, idx) => ({
      id: b.id,
      name: b.name,
      folderName: `${String(idx + 1).padStart(2, "0")} ${safeName(b.name)}`,
    }));

    // Presign every URL with one promise per photo + plan, all in
    // parallel (presign is local — no R2 round-trip — so a few
    // hundred concurrent presigns are fine).
    const PRESIGN_TTL = 15 * 60;
    const photos: FolderExportManifestPhoto[] = [];
    let totalSizeBytes = 0;
    const photoPromises = project.photos.map(async (p) => {
      const lookup = photoFileByIdLower.get(p.id.toLowerCase());
      if (!lookup) return null; // not yet uploaded
      const url = await presignedGet({
        objectKey: lookup.objectKey,
        expiresInSeconds: PRESIGN_TTL,
      });
      return { p, url, lookup };
    });
    const photoResults = await Promise.all(photoPromises);
    for (const result of photoResults) {
      if (!result) continue;
      const { p, url, lookup } = result;
      totalSizeBytes += lookup.sizeBytes;
      photos.push(photoManifestEntry(project, p, url));
    }

    const plans: FolderExportManifestPlan[] = [];
    const planPromises = project.floorPlans.map(async (pl) => {
      const lookup = planFileByIdLower.get(pl.id.toLowerCase());
      if (!lookup) return null;
      const url = await presignedGet({
        objectKey: lookup.objectKey,
        expiresInSeconds: PRESIGN_TTL,
      });
      return { pl, url, lookup };
    });
    const planResults = await Promise.all(planPromises);
    for (const result of planResults) {
      if (!result) continue;
      const { pl, url, lookup } = result;
      totalSizeBytes += lookup.sizeBytes;
      plans.push({
        id: pl.id,
        presignedUrl: url,
        filename: `${safeName(pl.label)}.${(pl.imageFilename.split(".").pop() ?? "png")}`,
        label: pl.label,
        pixelsPerFoot: pl.pixelsPerFoot,
        calibrationDistanceFeet: pl.calibrationDistanceFeet,
        northDeg: pl.northDeg,
        distressMarkerCount: pl.distress.length,
      });
    }

    return {
      manifest: {
        projectName: project.name,
        buckets,
        unbucketedFolderName: "99 Unbucketed",
        photos,
        plans,
        totalSizeBytes,
        computedAt: new Date().toISOString(),
      },
    };
  });

  // -----------------------------------------------------------------
  // DELETE /v1/exports/v2/:exportId — delete row + reap R2 blob.
  // -----------------------------------------------------------------
  app.delete<{
    Params: { exportId: string };
    Reply: ApiError | null;
  }>("/v1/exports/v2/:exportId", async (request, reply) => {
    const exportId = request.params.exportId;
    const { data, error } = await supabaseAdmin
      .from("project_exports")
      .select("created_by, object_key, status")
      .eq("id", exportId)
      .maybeSingle();
    if (error) {
      request.log.error({ err: error, exportId }, "project_exports — pre-delete read failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if (!data || (data as { created_by: string }).created_by !== request.user.id) {
      reply.code(404).send({ error: "not_found", message: `Export ${exportId} not found` });
      return;
    }
    // Refuse to delete in-flight exports — the worker is still
    // pointing at the row. The user can wait or wait for failure.
    const row = data as { created_by: string; object_key: string | null; status: ExportStatus };
    if (row.status === "running") {
      reply.code(409).send({
        error: "precondition_failed",
        message: "Export is still running. Wait for it to finish before deleting.",
      });
      return;
    }

    if (row.object_key) {
      try {
        await deleteObjects([row.object_key]);
      } catch (err) {
        request.log.warn(
          { err, exportId, objectKey: row.object_key },
          "project_exports — R2 reap partial failure; continuing with row delete"
        );
      }
    }
    const { error: delErr } = await supabaseAdmin
      .from("project_exports")
      .delete()
      .eq("id", exportId)
      .eq("created_by", request.user.id);
    if (delErr) {
      request.log.error({ err: delErr, exportId }, "project_exports — row delete failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    reply.code(204);
    return null;
  });
};
