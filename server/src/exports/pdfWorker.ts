/**
 * Background PDF export worker (Build #5.62.1).
 *
 * Polls the `pdf_export_jobs` table with a 5–60 second delay after
 * each settled tick, claims one row atomically, renders the project's
 * manifest in bounded HTML chunks, and prints via headless Chromium
 * (Puppeteer), uploads the result to R2, and marks the row done.
 * On render failure the row is flipped to 'failed' with the error
 * surfaced so the web client can show it.
 *
 * Why an in-process worker (not a separate service):
 *   - Render free / Starter tier is one container; a worker dyno
 *     would double the cost for a sub-10-job/day workload.
 *   - The job queue is Postgres-backed (not Redis), so any process
 *     with the secret key can poll. Easy to lift into a worker
 *     dyno later if volume justifies it.
 *
 * Atomic claim: a queued row is claimed via a conditional update
 *   (`update set status='running' where id=X and status='queued'`).
 *   Only one worker's update will succeed; the other sees an empty
 *   response and skips that id.
 *
 * Chromium launches lazily for a claimed job, reuses a browser across
 * up to four chunks, and closes after every job so idle API traffic
 * does not retain a browser process. This is not an RSS guarantee.
 *
 * PDF layout is delegated to htmlReport's streamed report chunks.
 */

import type { FastifyBaseLogger } from "fastify";
import { PDFDocument } from "pdf-lib";
import puppeteer, { type Browser } from "puppeteer";
import type { PdfExportOptions, Project } from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { putObjectBytes } from "../r2.js";
import { captureException } from "../sentry.js";
import { renderReportChunks, reportFooterTemplate } from "./htmlReport.js";
import { applyOptionDefaults } from "./options.js";
import { loadReportBrandingForExport } from "../reportBranding.js";
import { startQueuePoller } from "./queuePoller.js";

/** R2 prefix for rendered PDFs. Keeps them out of the
 *  `<projectId>/<photoId>/<kind>` namespace photos use. */
const PDF_PREFIX = "exports/pdf";

let workerStarted = false;
let tickRunning = false;
/** pdf-lib retains the final document; explicitly cap output instead of claiming constant memory. */
export const MAX_PDF_SOURCE_BYTES = 64 * 1024 * 1024;
const MAX_PDF_PAGES = 1000;
const BROWSER_CLOSE_TIMEOUT_MS = 5_000;
let browser: Browser | null = null;

interface JobRow {
  id: string;
  project_id: string;
  status: string;
  options?: Partial<PdfExportOptions> | null;
}

async function getOrLaunchBrowser(): Promise<Browser> {
  if (browser && browser.connected) return browser;
  browser = await puppeteer.launch({
    headless: true,
    args: [
      // Standard "this is a container, you have no sandbox kernel
      // features" flag set for Chromium on Render / Docker. Without
      // these the launch fails with "Failed to move to new namespace."
      "--no-sandbox",
      "--disable-setuid-sandbox",
      // Force Chrome to use /tmp instead of /dev/shm — Render
      // containers have a tiny /dev/shm by default; running out
      // mid-render is one cause of "Target closed."
      "--disable-dev-shm-usage",
      // NOTE: previously had `--single-process` + `--no-zygote` here
      // for memory savings on Render free tier. Both turned out to
      // cause "Protocol error: Target closed" mid-page.pdf() on
      // 500+ photo exports (Build #5.74.4). Multi-process Chrome
      // is more memory-stable for large prints; the per-chunk
      // browser relaunch (also in #5.74.4) keeps RSS bounded.
    ],
  });
  return browser;
}

async function closeWithDeadline(close: () => Promise<void>): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      close(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("Browser close timed out")), BROWSER_CLOSE_TIMEOUT_MS);
        timer.unref();
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Release the owned browser after a job and between batches. Closing a broken
 * DevTools connection is bounded so it cannot permanently occupy the worker. */
async function recycleBrowser(log: FastifyBaseLogger): Promise<void> {
  const previous = browser;
  browser = null;
  if (!previous) return;
  try {
    await closeWithDeadline(() => previous.close());
  } catch (err) {
    log.warn({ err }, "pdf worker — browser close failed; terminating owned browser process");
    // This is our Puppeteer-launched child, never the user's browser. A
    // stalled DevTools close must not retain the worker/polling slot forever.
    try { previous.process()?.kill("SIGKILL"); } catch { /* Already exited. */ }
  }
}

/** Try to claim one queued job. Returns the claimed row or null when
 *  the queue is empty / another worker grabbed it first. */
async function claimNextJob(log: FastifyBaseLogger): Promise<JobRow | null> {
  const { data: candidates, error: scanErr } = await supabaseAdmin
    .from("pdf_export_jobs")
    .select("id, project_id, status, options")
    .eq("status", "queued")
    .order("created_at", { ascending: true })
    .limit(1);
  if (scanErr) {
    log.error({ err: scanErr }, "pdf worker — queue scan failed");
    return null;
  }
  const candidate = candidates && candidates[0];
  if (!candidate) return null;

  // Conditional update — the `eq('status', 'queued')` is the atomic
  // claim. If another worker grabbed it, this update matches 0 rows.
  const { data: claimed, error: claimErr } = await supabaseAdmin
    .from("pdf_export_jobs")
    .update({ status: "running", started_at: new Date().toISOString() })
    .eq("id", candidate.id)
    .eq("status", "queued")
    .select("id, project_id, status, options")
    .maybeSingle();
  if (claimErr) {
    log.error({ err: claimErr, jobId: candidate.id }, "pdf worker — claim failed");
    return null;
  }
  return (claimed as JobRow | null) ?? null;
}

async function renderJob(job: JobRow, log: FastifyBaseLogger): Promise<void> {
  // Load the manifest — same shape projects/routes.ts uses.
  const { data: row, error: readErr } = await supabaseAdmin
    .from("projects")
    .select("manifest")
    .eq("id", job.project_id)
    .maybeSingle();
  if (readErr || !row) {
    throw new Error(
      `Project ${job.project_id} not found or unreadable: ${readErr?.message ?? "no row"}`
    );
  }
  const project = (row as { manifest: Project }).manifest;
  const options = applyOptionDefaults(job.options ?? {});

  const branding = await loadReportBrandingForExport();
  const chunks = renderReportChunks(project, job.project_id, log, options, branding);
  const pdfFormat = options.pageSize === "a4" ? "A4" : "Letter";
  const merged = await PDFDocument.create();
  let chunkIndex = 0;
  let sourceBytes = 0;
  const mbAtStart = Math.round(process.memoryUsage().rss / 1024 / 1024);

  // Byte/pixel limits can split chunks dynamically. An unknown total is more
  // honest than fetching/rendering the entire report just to count in advance.
  await supabaseAdmin.from("pdf_export_jobs")
    .update({ progress_total_chunks: null, progress_done_chunks: 0 })
    .eq("id", job.id).then(undefined, () => {});

  for await (const html of chunks) {
    if (chunkIndex > 0 && chunkIndex % 4 === 0) await recycleBrowser(log);
    const b = await getOrLaunchBrowser();
    const page = await b.newPage();
    try {
      await page.setContent(html, { waitUntil: "load", timeout: 60_000 });
      // A valid header is not a successful decode. Chromium must have decoded
      // every required inline image before this chunk can contribute to Done.
      const imagesReady = await page.evaluate(() => Array.from((globalThis as unknown as { document: { images: ArrayLike<{ complete: boolean; naturalWidth: number; naturalHeight: number }> } }).document.images)
        .every(image => image.complete && image.naturalWidth > 0 && image.naturalHeight > 0));
      if (!imagesReady) throw new Error("A required PDF image could not be decoded. Export aborted.");
      const pdf = await page.pdf({ format: pdfFormat, printBackground: true,
        ...(branding.footerOverride ? { displayHeaderFooter: true, headerTemplate: "<span></span>", footerTemplate: reportFooterTemplate(branding.footerOverride) } : {}),
      });
      sourceBytes += pdf.byteLength;
      if (sourceBytes > MAX_PDF_SOURCE_BYTES) throw new Error("PDF exceeds the 64 MiB export limit. Export a smaller selection.");
      const source = await PDFDocument.load(pdf);
      if (merged.getPageCount() + source.getPageCount() > MAX_PDF_PAGES) throw new Error("PDF exceeds 1000 pages. Export a smaller selection.");
      const pages = await merged.copyPages(source, source.getPageIndices());
      for (const copied of pages) merged.addPage(copied);
      // No chunk-PDF array: source bytes are released after this iteration.
      chunkIndex++;
      log.info({ jobId: job.id, chunkIndex, chunkHtmlBytes: Buffer.byteLength(html), chunkPdfKb: Math.round(pdf.byteLength / 1024) }, "pdf worker — chunk done");
      await supabaseAdmin.from("pdf_export_jobs")
        .update({ progress_done_chunks: chunkIndex }).eq("id", job.id)
        .then(undefined, () => {});
    } finally {
      try {
        await closeWithDeadline(() => page.close());
      } catch {
        // A stuck page close must not prevent outer job cleanup. Discard the
        // browser now rather than reusing its broken connection for a chunk.
        await recycleBrowser(log);
      }
    }
  }
  if (chunkIndex === 0) throw new Error("Selection is empty — nothing to render.");
  const finalBytes = Buffer.from(await merged.save());
  if (finalBytes.byteLength > MAX_PDF_SOURCE_BYTES) throw new Error("PDF exceeds the 64 MiB export limit. Export a smaller selection.");
  log.info({ jobId: job.id, finalPdfKb: Math.round(finalBytes.byteLength / 1024), pageCount: merged.getPageCount(), rssDeltaMb: Math.round(process.memoryUsage().rss / 1024 / 1024) - mbAtStart }, "pdf worker — merged");

  const objectKey = `${PDF_PREFIX}/${job.id}.pdf`;
  await putObjectBytes({
    objectKey,
    body: finalBytes,
    contentType: "application/pdf",
  });
  const { error: updateErr } = await supabaseAdmin
    .from("pdf_export_jobs")
    .update({
      status: "done",
      progress_total_chunks: chunkIndex,
      progress_done_chunks: chunkIndex,
      pdf_object_key: objectKey,
      completed_at: new Date().toISOString(),
    })
    .eq("id", job.id);
  if (updateErr) {
    // Upload succeeded but the row update failed — log loudly but
    // don't throw, the PDF is in R2 even if the row is wrong.
    log.error(
      { err: updateErr, jobId: job.id },
      "pdf worker — completion update failed"
    );
  } else {
    log.info(
      { jobId: job.id, projectId: job.project_id },
      "pdf export done"
    );
  }
}

async function markFailed(jobId: string, message: string): Promise<void> {
  const { error } = await supabaseAdmin
    .from("pdf_export_jobs")
    .update({
      status: "failed",
      error_message: message.slice(0, 1000),
      completed_at: new Date().toISOString(),
    })
    .eq("id", jobId);
  if (error) throw error;
}

/** Shared by the polling loop and deterministic worker tests. */
export async function processPdfExportJob(job: JobRow, log: FastifyBaseLogger): Promise<void> {
  try {
    await renderJob(job, log);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    log.error({ err: error, jobId: job.id }, "pdf worker — render failed");
    captureException(error, { jobId: job.id, projectId: job.project_id });
    await markFailed(job.id, message);
  } finally {
    await recycleBrowser(log);
  }
}

async function tick(log: FastifyBaseLogger): Promise<boolean> {
  // Atomic DB claiming prevents duplicate claims, not simultaneous different
  // jobs. One local job at a time keeps the shared browser and memory bounded.
  if (tickRunning) return false;
  tickRunning = true;
  try {
    const job = await claimNextJob(log);
    if (job) await processPdfExportJob(job, log);
    return job !== null;
  } finally {
    tickRunning = false;
  }
}

/**
 * Boot the worker. Called from `index.ts` after Fastify is up.
 * Idempotent — calling twice is a no-op (in case the import graph
 * ever produces a duplicate call).
 */
export function startPdfExportWorker(log: FastifyBaseLogger): void {
  if (workerStarted) return;
  workerStarted = true;
  log.info("pdf export worker started");
  startQueuePoller(() => tick(log), (err) => {
    log.error({ err }, "pdf worker — unhandled tick error");
  });
}
