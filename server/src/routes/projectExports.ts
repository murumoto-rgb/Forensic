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
  type GetProjectExportResponse,
  type ListProjectExportsResponse,
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
}

function rowToProjectExport(row: ExportRow): ProjectExport {
  return {
    id: row.id,
    projectId: row.project_id,
    kind: row.kind,
    status: row.status,
    objectKey: row.object_key,
    sizeBytes: row.size_bytes,
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
