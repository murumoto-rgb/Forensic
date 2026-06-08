/**
 * Background worker for "AI Analysis CSV" exports (Build #5.97.1).
 *
 * Mirrors iOS's `AIAnalysisCSVExportRunner`: one row per primary tag
 * per photo, with the AI's context / observation / caption /
 * measurement / reviewer flag. Opens directly in Excel / Google
 * Sheets.
 *
 * Polls the `project_exports` table for `kind='csv'` queued rows.
 */

import type { FastifyBaseLogger } from "fastify";
import type {
  AiAnalysisCsvOptions,
  ExportStatus,
  Photo,
  Project,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { putObjectBytes } from "../r2.js";
import { captureException } from "../sentry.js";

const POLL_MS = 5_000;
const CSV_PREFIX = "exports/csv";

let workerStarted = false;

interface ExportRow {
  id: string;
  project_id: string;
  created_by: string;
  kind: "pdf" | "folder" | "csv";
  status: ExportStatus;
  object_key: string | null;
  size_bytes: number | null;
  options: Partial<AiAnalysisCsvOptions>;
  error_message: string | null;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
}

async function claimNextJob(log: FastifyBaseLogger): Promise<ExportRow | null> {
  const { data: candidate, error } = await supabaseAdmin
    .from("project_exports")
    .select("*")
    .eq("status", "queued")
    .eq("kind", "csv")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (error) {
    log.error({ err: error }, "csv export worker — candidate scan failed");
    return null;
  }
  if (!candidate) return null;

  const { data: claimed, error: claimErr } = await supabaseAdmin
    .from("project_exports")
    .update({ status: "running", started_at: new Date().toISOString() })
    .eq("id", (candidate as ExportRow).id)
    .eq("status", "queued")
    .select("*")
    .maybeSingle();
  if (claimErr) {
    log.error({ err: claimErr, jobId: (candidate as ExportRow).id }, "csv export worker — claim failed");
    return null;
  }
  return (claimed as ExportRow | null) ?? null;
}

async function markFailed(jobId: string, message: string): Promise<void> {
  await supabaseAdmin
    .from("project_exports")
    .update({
      status: "failed",
      error_message: message.slice(0, 1000),
      completed_at: new Date().toISOString(),
    })
    .eq("id", jobId);
}

async function markDone(jobId: string, objectKey: string, sizeBytes: number): Promise<void> {
  await supabaseAdmin
    .from("project_exports")
    .update({
      status: "done",
      object_key: objectKey,
      size_bytes: sizeBytes,
      completed_at: new Date().toISOString(),
    })
    .eq("id", jobId);
}

/** RFC-4180 escape: wrap in quotes if the value contains comma /
 *  quote / newline; double any internal quotes. */
function csvField(raw: string | number | null | undefined): string {
  if (raw == null) return "";
  const s = String(raw);
  if (/[",\n\r]/.test(s)) {
    return `"${s.replace(/"/g, '""')}"`;
  }
  return s;
}

/**
 * Build the CSV body. One header row + one data row per primary tag
 * per photo. Photos without an `aiAnalysis` are skipped when
 * `onlyAnalyzed` is true; otherwise they emit a single row with
 * blank AI fields so the user can see them in the export.
 */
function buildCsv(project: Project, opts: AiAnalysisCsvOptions): string {
  const lines: string[] = [];
  lines.push(
    [
      "Sequence",
      "Photo ID",
      "Captured",
      "User caption",
      "User observation",
      "Primary tag",
      "Confidence",
      "Secondary tags",
      "AI summary observation",
      "AI caption",
      "Scale present",
      "Measurement",
      "Recommended use",
      "Reviewer flag",
      "Floor plan",
      "Bucket",
    ].join(",")
  );

  const floorPlanLabelById = new Map(
    project.floorPlans.map((p) => [p.id, p.label])
  );
  const bucketNameById = new Map(project.buckets.map((b) => [b.id, b.name]));

  function appendPhotoRow(
    photo: Photo,
    primaryTag: string | null,
    confidence: number | null,
    secondaryTags: string[]
  ): void {
    lines.push(
      [
        csvField(photo.sequenceNumber),
        csvField(photo.id),
        csvField(photo.timestamp),
        csvField(photo.userCaption),
        csvField(photo.userObservation),
        csvField(primaryTag),
        csvField(confidence == null ? "" : confidence.toFixed(2)),
        csvField(secondaryTags.join("; ")),
        csvField(photo.aiAnalysis?.summaryObservation ?? null),
        csvField(photo.aiAnalysis?.captionDraft ?? null),
        csvField(photo.aiAnalysis?.scalePresent ?? null),
        csvField(photo.aiAnalysis?.measurementVisible ?? null),
        csvField(photo.aiAnalysis?.recommendedUse ?? null),
        csvField(photo.aiAnalysis?.reviewerFlag ?? null),
        csvField(
          photo.floorPlanID
            ? floorPlanLabelById.get(photo.floorPlanID) ?? null
            : null
        ),
        csvField(
          photo.bucketID ? bucketNameById.get(photo.bucketID) ?? null : null
        ),
      ].join(",")
    );
  }

  for (const photo of project.photos) {
    const analysis = photo.aiAnalysis;
    if (!analysis) {
      if (opts.onlyAnalyzed) continue;
      // Emit a single row with blank AI fields.
      appendPhotoRow(photo, null, null, []);
      continue;
    }
    if (analysis.primaryTags.length === 0) {
      appendPhotoRow(photo, null, null, []);
      continue;
    }
    for (const primary of analysis.primaryTags) {
      const confidence = analysis.tagConfidences[primary] ?? null;
      if (confidence != null && confidence < opts.minConfidence) continue;
      const secondaries = (analysis.secondaryTagsByPrimary[primary] ?? []).filter(
        (s) => (analysis.tagConfidences[s] ?? 1) >= opts.minConfidence
      );
      appendPhotoRow(photo, primary, confidence, secondaries);
    }
  }

  return lines.join("\n");
}

async function runJob(job: ExportRow, log: FastifyBaseLogger): Promise<void> {
  const { data: projectRow, error: projErr } = await supabaseAdmin
    .from("projects")
    .select("manifest")
    .eq("id", job.project_id)
    .maybeSingle();
  if (projErr || !projectRow) {
    throw new Error(`Manifest read failed: ${projErr?.message ?? "not_found"}`);
  }
  const project = projectRow.manifest as unknown as Project;

  const opts: AiAnalysisCsvOptions = {
    onlyAnalyzed: job.options.onlyAnalyzed ?? true,
    minConfidence: job.options.minConfidence ?? 0.5,
  };

  const csv = buildCsv(project, opts);
  // BOM so Excel recognizes UTF-8.
  const bytes = Buffer.from("﻿" + csv, "utf-8");
  const objectKey = `${CSV_PREFIX}/${job.id}.csv`;

  await putObjectBytes({
    objectKey,
    body: bytes,
    contentType: "text/csv; charset=utf-8",
  });

  await markDone(job.id, objectKey, bytes.byteLength);
  log.info(
    { jobId: job.id, projectId: job.project_id, bytes: bytes.byteLength },
    "csv export — done"
  );
}

async function tick(log: FastifyBaseLogger): Promise<void> {
  const job = await claimNextJob(log);
  if (!job) return;
  try {
    await runJob(job, log);
  } catch (e: unknown) {
    const message = e instanceof Error ? e.message : String(e);
    log.error({ err: e, jobId: job.id }, "csv export — render failed");
    captureException(e, { jobId: job.id, projectId: job.project_id });
    try {
      await markFailed(job.id, message);
    } catch (markErr) {
      log.error({ err: markErr, jobId: job.id }, "csv export — markFailed also failed");
    }
  }
}

export function startCsvExportWorker(log: FastifyBaseLogger): void {
  if (workerStarted) return;
  workerStarted = true;
  log.info("csv export worker started");
  setInterval(() => {
    void tick(log).catch((err) => {
      log.error({ err }, "csv export worker — unhandled tick error");
    });
  }, POLL_MS);
}
