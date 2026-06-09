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
import { z } from "zod";
import type {
  ApiError,
  CreatePdfExportResponse,
  GetPdfExportResponse,
  PdfExportJob,
  PdfExportOptions,
  PdfExportStatus,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";
import { assertProjectAccess, sendAccessError } from "../access.js";
import { presignedGet } from "../r2.js";
import { applyOptionDefaults } from "../exports/options.js";

// Schema accepts both the iOS-parity fields (Build #5.67.1) and the
// legacy #5.64.1 fields. Every field is optional — `applyOptionDefaults`
// fills in the rest. The renderer (PRs #5.68.1 — #5.71.1) prefers the
// new fields when present and falls back to the legacy ones so
// in-flight web UIs that haven't shipped the new modal yet (PR
// #5.73.1) keep working.
const PdfAnnotationOptionsSchema = z.object({
  includeTags: z.boolean().optional(),
  includeCaption: z.boolean().optional(),
  includeObservation: z.boolean().optional(),
  includeMeasurement: z.boolean().optional(),
  includeReviewerFlag: z.boolean().optional(),
});

const PdfExportOptionsSchema = z.object({
  // iOS parity fields.
  perPage: z.number().int().optional(),
  groupByBucket: z.boolean().optional(),
  includeMetadataTable: z.boolean().optional(),
  annotations: PdfAnnotationOptionsSchema.optional(),
  sectionOrder: z
    .array(z.enum(["plan", "contactSheets", "metadataTable"]))
    .optional(),
  selectedFloorIds: z.array(z.string()).nullable().optional(),
  planMode: z
    .enum(["photoOnly", "distressOnly", "photoAndDistressSeparate", "merged"])
    .optional(),

  // Web-specific carryover.
  pageSize: z.enum(["letter", "a4"]).optional(),
  includeTrashed: z.boolean().optional(),
  includeCoverPage: z.boolean().optional(),

  // Legacy fields — accepted for backwards compat.
  photosPerPage: z.union([z.literal(1), z.literal(2), z.literal(4)]).optional(),
  photoFilter: z.enum(["all", "favorites", "byFloorPlan"]).optional(),
  floorPlanId: z.string().nullable().optional(),
  includeFloorPlanPages: z.boolean().optional(),
});

const CreateBodySchema = z.object({
  options: PdfExportOptionsSchema.optional(),
});

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
  progress_done_chunks: number | null;
  progress_total_chunks: number | null;
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
    progressDoneChunks: row.progress_done_chunks ?? null,
    progressTotalChunks: row.progress_total_chunks ?? null,
  };
}

export const exportsRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  // Phase 3 (Build #5.123.1): legacy PDF export creation is an edit
  // intent → editor-or-above. Routed through `assertProjectAccess`.

  // -----------------------------------------------------------------
  // POST /v1/projects/:id/export/pdf — enqueue
  // -----------------------------------------------------------------
  app.post<{
    Params: { id: string };
    Body: unknown;
    Reply: CreatePdfExportResponse | ApiError;
  }>("/v1/projects/:id/export/pdf", async (request, reply) => {
    const projectId = request.params.id;

    // Body is fully optional — `{}` or even no body at all is fine.
    // When `options` is partial, the worker fills in defaults.
    const bodyToParse = request.body ?? {};
    const parsed = CreateBodySchema.safeParse(bodyToParse);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    // Cast through `unknown` because zod's nested-optional inference
    // produces a structurally-compatible-but-stricter type
    // (`{includeTags?: boolean | undefined; …}`) than
    // `Partial<PdfExportOptions>` (`{includeTags: boolean; …}` inside
    // `annotations?`). `applyOptionDefaults` is total — every nested
    // field has a `??` fallback — so the cast is safe.
    const options = applyOptionDefaults(
      (parsed.data.options ?? {}) as Partial<PdfExportOptions>
    );
    if (options.photoFilter === "byFloorPlan" && !options.floorPlanId) {
      reply.code(400).send({
        error: "bad_request",
        message: "floorPlanId is required when photoFilter is 'byFloorPlan'.",
      });
      return;
    }

    try {
      await assertProjectAccess(request.user.id, projectId, "editor");
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      request.log.error({ err, projectId }, "pdf export — access check failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from("pdf_export_jobs")
      .insert({
        project_id: projectId,
        requested_by: request.user.id,
        status: "queued" as PdfExportStatus,
        options,
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
