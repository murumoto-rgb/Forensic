/**
 * Background PDF export worker (Build #5.62.1).
 *
 * Polls the `pdf_export_jobs` table every few seconds for queued
 * rows, claims one atomically, renders the project's manifest into
 * an HTML page, prints the page to a PDF via headless Chromium
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
 * Memory budget: Puppeteer loads ~250 MB of Chromium per browser
 * instance. We reuse a single browser across jobs (lazy-launched on
 * first claim, kept alive for the lifetime of the process) to avoid
 * paying that cost per render. A new page is opened per job and
 * closed when done.
 *
 * The PDF layout in THIS PR is intentionally minimal — a cover page
 * showing the project name, photo count, and a generation timestamp.
 * Real per-photo + per-plan pages land in PR #2; the options sheet
 * lands in PR #3. The MVP is the pipeline plumbing, not the polish.
 *
 * Skeleton skip condition: if either Supabase or R2 isn't reachable
 * (boot env vars unset in dev), the polling loop never starts. The
 * server otherwise still serves all non-export routes.
 */

import type { FastifyBaseLogger } from "fastify";
import puppeteer, { type Browser } from "puppeteer";
import type { PdfExportOptions, Project } from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { putObjectBytes } from "../r2.js";
import { captureException } from "../sentry.js";
import { renderReportHtml } from "./htmlReport.js";
import { applyOptionDefaults } from "./options.js";

/** How often to scan the queue. Render free tier sleeps after 15
 *  min of idle; on cold-start the first poll fires immediately after
 *  the server boots. 5 s is responsive enough for a click-and-wait
 *  UI without hammering the DB. */
const POLL_MS = 5_000;

/** R2 prefix for rendered PDFs. Keeps them out of the
 *  `<projectId>/<photoId>/<kind>` namespace photos use. */
const PDF_PREFIX = "exports/pdf";

let workerStarted = false;
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
      // The standard "this is a container, you have no sandbox kernel
      // features" flag set for Chromium on Render / Docker. Without
      // these the launch fails with "Failed to move to new namespace."
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-dev-shm-usage",
      // Save memory on Render's 512 MB free dyno.
      "--single-process",
      "--no-zygote",
    ],
  });
  return browser;
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
  // PR #3: options drive layout choices (page size, photos per page,
  // photo filter, included sections). Worker fills defaults for any
  // missing field so old / minimal clients still produce the
  // #5.63.1 output shape.
  const options = applyOptionDefaults(job.options ?? {});
  const html = await renderReportHtml(project, job.project_id, log, options);

  const b = await getOrLaunchBrowser();
  const page = await b.newPage();
  try {
    // Memory probe (Build #5.65.1) — surfaces actual RSS around the
    // heaviest step so we can tune `MAX_PHOTOS_PER_PDF` from measured
    // data rather than guesses. `rss` is the process's resident set
    // size in bytes (total memory the OS is holding for us).
    const mbAtStart = Math.round(process.memoryUsage().rss / 1024 / 1024);
    log.info({ jobId: job.id, rssMb: mbAtStart, htmlBytes: html.length }, "pdf worker — pre-render");
    await page.setContent(html, { waitUntil: "load", timeout: 60_000 });
    const mbAfterSetContent = Math.round(process.memoryUsage().rss / 1024 / 1024);
    log.info({ jobId: job.id, rssMb: mbAfterSetContent }, "pdf worker — post-setContent");
    // page.pdf's `format` is the paper size for ALL pages. The HTML
    // also sets `@page { size: ... }` so the CSS-level page break
    // hints line up with Puppeteer's paper size.
    const pdf = await page.pdf({
      format: options.pageSize === "a4" ? "A4" : "Letter",
      printBackground: true,
    });
    const mbAfterPdf = Math.round(process.memoryUsage().rss / 1024 / 1024);
    log.info(
      {
        jobId: job.id,
        rssMb: mbAfterPdf,
        rssDeltaMb: mbAfterPdf - mbAtStart,
        pdfKb: Math.round((Buffer.isBuffer(pdf) ? pdf.byteLength : Buffer.from(pdf).byteLength) / 1024),
      },
      "pdf worker — post-pdf"
    );
    const pdfBuffer = Buffer.isBuffer(pdf) ? pdf : Buffer.from(pdf);
    const objectKey = `${PDF_PREFIX}/${job.id}.pdf`;
    await putObjectBytes({
      objectKey,
      body: pdfBuffer,
      contentType: "application/pdf",
    });
    const { error: updateErr } = await supabaseAdmin
      .from("pdf_export_jobs")
      .update({
        status: "done",
        pdf_object_key: objectKey,
        completed_at: new Date().toISOString(),
      })
      .eq("id", job.id);
    if (updateErr) {
      // Render succeeded but the row update failed — log loudly but
      // don't throw, the PDF is in R2 even if the row is wrong.
      log.error({ err: updateErr, jobId: job.id }, "pdf worker — completion update failed");
    } else {
      log.info({ jobId: job.id, projectId: job.project_id }, "pdf export done");
    }
  } finally {
    await page.close().catch(() => {});
  }
}

async function markFailed(jobId: string, message: string): Promise<void> {
  await supabaseAdmin
    .from("pdf_export_jobs")
    .update({
      status: "failed",
      error_message: message.slice(0, 1000),
      completed_at: new Date().toISOString(),
    })
    .eq("id", jobId);
}

async function tick(log: FastifyBaseLogger): Promise<void> {
  const job = await claimNextJob(log);
  if (!job) return;
  try {
    await renderJob(job, log);
  } catch (e: unknown) {
    const message = e instanceof Error ? e.message : String(e);
    log.error({ err: e, jobId: job.id }, "pdf worker — render failed");
    captureException(e, { jobId: job.id, projectId: job.project_id });
    try {
      await markFailed(job.id, message);
    } catch (markErr) {
      log.error({ err: markErr, jobId: job.id }, "pdf worker — markFailed also failed");
    }
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
  // We use setInterval rather than a recursive setTimeout because we
  // want a steady cadence even if a tick stalls; concurrent ticks are
  // prevented by the atomic claim (a second tick that fires while the
  // first is mid-render will simply find no queued rows or fail its
  // own claim and back off).
  setInterval(() => {
    void tick(log).catch((err) => {
      log.error({ err }, "pdf worker — unhandled tick error");
    });
  }, POLL_MS);
}
