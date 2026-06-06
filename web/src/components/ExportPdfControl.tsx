import { useEffect, useRef, useState } from "react";
import type { PdfExportJob } from "@forensic/shared";
import { api, ApiError } from "../lib/api";

/**
 * "Export PDF" button + status pill (Build #5.62.1, plan item #3 PR #1).
 *
 * Clicking the button:
 *   1. POSTs `/v1/projects/:id/export/pdf` to enqueue a render job.
 *   2. Polls `/v1/exports/:jobId` every 2 seconds until the job
 *      reaches `done` or `failed`.
 *   3. On `done` — auto-clicks a hidden anchor pointing at the
 *      presigned R2 URL so the PDF downloads without the user
 *      having to confirm a second click.
 *
 * Layout-wise this is intentionally the same width/affordance as the
 * Re-tag-all-with-AI button next to it on the project detail page.
 * Real options-sheet UI (page size, photo-per-page count, include
 * trashed photos, etc.) lands in PR #3; this PR ships the pipeline
 * with no choices to make.
 */

interface Props {
  projectId: string;
  /** When false, the button renders disabled — the page is
   *  read-only (no lock held). PDF export is treated as a write
   *  because it consumes the same `requested_by` user row + leaves
   *  a permanent server-side artifact. */
  canExport: boolean;
}

type State =
  | { kind: "idle" }
  | { kind: "queued"; job: PdfExportJob }
  | { kind: "running"; job: PdfExportJob }
  | { kind: "done"; job: PdfExportJob; downloadUrl: string }
  | { kind: "failed"; job: PdfExportJob; message: string }
  | { kind: "error"; message: string };

const POLL_MS = 2_000;

export function ExportPdfControl({ projectId, canExport }: Props) {
  const [state, setState] = useState<State>({ kind: "idle" });
  const pollRef = useRef<number | null>(null);
  // Tracks the active job id so a slow setInterval callback can bail
  // if the user clicked Reset / a new job started in the meantime.
  const activeJobIdRef = useRef<string | null>(null);

  function clearPoll() {
    if (pollRef.current !== null) {
      window.clearInterval(pollRef.current);
      pollRef.current = null;
    }
  }

  useEffect(() => {
    return () => clearPoll();
  }, []);

  function poll(jobId: string) {
    if (activeJobIdRef.current !== jobId) return;
    api
      .getPdfExport(jobId)
      .then((res) => {
        if (activeJobIdRef.current !== jobId) return;
        const job = res.job;
        if (job.status === "queued") {
          setState({ kind: "queued", job });
        } else if (job.status === "running") {
          setState({ kind: "running", job });
        } else if (job.status === "done") {
          clearPoll();
          activeJobIdRef.current = null;
          if (res.downloadUrl) {
            setState({ kind: "done", job, downloadUrl: res.downloadUrl });
            // Trigger the download by synthesizing an <a> click — no
            // user prompt; browsers treat this as a same-gesture
            // continuation of the original button click as long as
            // we land within ~few seconds. If the gesture window has
            // closed, the anchor stays in the DOM for the user to
            // click "Download" manually.
            const a = document.createElement("a");
            a.href = res.downloadUrl;
            a.download = `${projectId}.pdf`;
            a.rel = "noopener";
            document.body.appendChild(a);
            a.click();
            a.remove();
          } else {
            setState({
              kind: "error",
              message: "Render finished but no download URL was returned.",
            });
          }
        } else if (job.status === "failed") {
          clearPoll();
          activeJobIdRef.current = null;
          setState({
            kind: "failed",
            job,
            message: job.errorMessage ?? "Render failed",
          });
        }
      })
      .catch((e: unknown) => {
        // A single poll failure isn't fatal — Render free-tier cold
        // starts can drop a couple of requests before the worker
        // wakes up. Keep polling; the interval will retry.
        if (e instanceof ApiError && e.status === 404) {
          clearPoll();
          activeJobIdRef.current = null;
          setState({
            kind: "error",
            message: "Export job disappeared from the server.",
          });
        }
      });
  }

  function start() {
    clearPoll();
    setState({
      kind: "queued",
      job: {
        id: "(pending)",
        projectId,
        status: "queued",
        pdfObjectKey: null,
        errorMessage: null,
        createdAt: new Date().toISOString(),
        startedAt: null,
        completedAt: null,
      },
    });
    api
      .createPdfExport(projectId)
      .then((res) => {
        const jobId = res.job.id;
        activeJobIdRef.current = jobId;
        setState({ kind: "queued", job: res.job });
        pollRef.current = window.setInterval(() => poll(jobId), POLL_MS);
        // Fire one immediate poll so the user sees "running" within
        // a second or two if the worker grabs the job fast.
        poll(jobId);
      })
      .catch((e: unknown) => {
        setState({
          kind: "error",
          message:
            e instanceof ApiError
              ? `${e.errorCode}: ${e.message}`
              : "Failed to enqueue export",
        });
      });
  }

  function reset() {
    clearPoll();
    activeJobIdRef.current = null;
    setState({ kind: "idle" });
  }

  const inFlight = state.kind === "queued" || state.kind === "running";

  return (
    <div className="flex items-center gap-2">
      {state.kind === "queued" && (
        <span className="text-xs text-neutral-400">Queued…</span>
      )}
      {state.kind === "running" && (
        <span className="text-xs text-neutral-400">Rendering…</span>
      )}
      {state.kind === "done" && (
        <a
          href={state.downloadUrl}
          download={`${projectId}.pdf`}
          className="text-xs text-green-400 underline hover:text-green-300"
        >
          PDF ready — download again
        </a>
      )}
      {state.kind === "failed" && (
        <span
          className="max-w-[16rem] truncate text-xs text-red-400"
          title={state.message}
        >
          Failed: {state.message}
        </span>
      )}
      {state.kind === "error" && (
        <span
          className="max-w-[16rem] truncate text-xs text-red-400"
          title={state.message}
        >
          {state.message}
        </span>
      )}
      {(state.kind === "done" || state.kind === "failed" || state.kind === "error") && (
        <button
          type="button"
          onClick={reset}
          className="rounded border border-neutral-700 px-2 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
        >
          Reset
        </button>
      )}
      <button
        type="button"
        onClick={start}
        disabled={!canExport || inFlight}
        className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
        title={
          canExport
            ? "Render the project to a PDF on the server. The download starts when the render completes."
            : "Take the edit lock first."
        }
      >
        Export PDF
      </button>
    </div>
  );
}
