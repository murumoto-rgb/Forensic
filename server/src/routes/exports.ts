/**
 * Server-side PDF export endpoints (Build #5.62.1, plan item #3).
 *
 *   POST  /v1/projects/:id/export/pdf  → enqueue a render job
 *   GET   /v1/exports/:jobId           → status + download URL
 *
 * Both routes go through the shared `authPlugin` so only signed-in
 * users hit them. POST is gated on ownership of the project (same
 * shape the other project routes use). GET is gated on ownership of
 * the job (the requester must match `requested_by`).
 *
 * The render itself happens in `exports/pdfWorker.ts` — this route
 * file is just the queue interface. Rows transition queued →
 * running → done|failed; the GET endpoint surfaces whichever state
 * the row currently sits at, plus a 5-minute presigned download URL
 * when status is "done".
 *
 * This is the SKELETON PR — the worker emits a fixed cover-page
 * layout. Real per-photo + per-plan pages land in PR #2, options
 * sheet in PR #3.
 */

import type { FastifyPluginAsync } from "fastify";
import type {
  ApiError,
  CreatePdfExportResponse,
  GetPdfExportResponse,
  PdfExportJob,
  PdfExportStatus,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";
import { presignedGet } from "../r2.js";

const DOWNLOAD_URL_TTL_SECONDS = 300; // 5 min

interface JobRow {
  id: string;
  project_id: string;
  requested_by: string;
  status: PdfExportStatus;
  pdf_object_key: string | null;
  error_message: string | null;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
}

function rowToJob(row: JobRow): PdfExportJob {
  return {
    id: row.id,
    projectId: row.project_id,
    status: row.status,
    pdfObjectKey: row.pdf_object_key,
    errorMessage: row.error_message,
    createdAt: row.created_at,
    startedAt: row.started_at,
    completedAt: row.completed_at,
  };
}

export const exportsRoute: FastifyPluginAsync = async (app) => {
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
  // POST /v1/projects/:id/export/pdf — enqueue
  // -----------------------------------------------------------------
  app.post<{
    Params: { id: string };
    Reply: CreatePdfExportResponse | ApiError;
  }>("/v1/projects/:id/export/pdf", async (request, reply) => {
    const projectId = request.params.id;

    try {
      if (!(await callerOwnsProject(projectId, request.user.id))) {
        reply.code(404).send({ error: "not_found", message: `Project ${projectId} not found` });
        return;
      }
    } catch (err) {
      request.log.error({ err, projectId }, "pdf export — ownership check failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from("pdf_export_jobs")
      .insert({
        project_id: projectId,
        requested_by: request.user.id,
        status: "queued" as PdfExportStatus,
      })
      .select("*")
      .maybeSingle();
    if (error || !data) {
      request.log.error({ err: error, projectId }, "pdf export — enqueue failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    request.log.info(
      { jobId: (data as JobRow).id, projectId },
      "pdf export enqueued"
    );
    return { job: rowToJob(data as JobRow) };
  });

  // -----------------------------------------------------------------
  // GET /v1/exports/:jobId — status + download URL
  // -----------------------------------------------------------------
  app.get<{
    Params: { jobId: string };
    Reply: GetPdfExportResponse | ApiError;
  }>("/v1/exports/:jobId", async (request, reply) => {
    const jobId = request.params.jobId;
    const { data, error } = await supabaseAdmin
      .from("pdf_export_jobs")
      .select("*")
      .eq("id", jobId)
      .maybeSingle();
    if (error) {
      request.log.error({ err: error, jobId }, "pdf export — read failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    const row = data as JobRow | null;
    if (!row) {
      reply.code(404).send({ error: "not_found", message: `Export job ${jobId} not found` });
      return;
    }
    if (row.requested_by !== request.user.id) {
      // Don't leak existence; treat as not-found from the caller's view.
      reply.code(404).send({ error: "not_found", message: `Export job ${jobId} not found` });
      return;
    }

    let downloadUrl: string | null = null;
    let downloadUrlExpiresAt: string | null = null;
    if (row.status === "done" && row.pdf_object_key) {
      try {
        downloadUrl = await presignedGet({
          objectKey: row.pdf_object_key,
          expiresInSeconds: DOWNLOAD_URL_TTL_SECONDS,
        });
        downloadUrlExpiresAt = new Date(
          Date.now() + DOWNLOAD_URL_TTL_SECONDS * 1000
        ).toISOString();
      } catch (err) {
        request.log.error({ err, jobId }, "pdf export — presign failed");
        // Keep returning the job — the URL just isn't ready right
        // now. Caller can refetch.
      }
    }

    return {
      job: rowToJob(row),
      downloadUrl,
      downloadUrlExpiresAt,
    };
  });
};
