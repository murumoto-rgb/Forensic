import { useEffect, useRef, useState } from "react";
import type { PdfExportJob, PdfExportOptions } from "@forensic/shared";
import { api, ApiError } from "../lib/api";

/**
 * "Export PDF" button + options modal + status pill
 * (Build #5.62.1 / #5.63.1 / #5.64.1, plan item #3).
 *
 * Click → options modal → user picks page size + photo filter +
 * photos-per-page + include-flags → "Generate PDF" submits a job
 * with the chosen options. The component polls
 * `/v1/exports/:jobId` every 2 seconds until the job is done or
 * failed, then auto-triggers a hidden `<a>` click on the presigned
 * R2 URL so the PDF downloads without the user clicking a second
 * time.
 *
 * Defaults match the prior #5.63.1 behavior (all photos, 1 per
 * page, Letter, cover + plans included) so any user who hits
 * Generate PDF without changing options gets the same output the
 * previous build produced.
 */

interface FloorPlanSummary {
  id: string;
  label: string;
}

interface Props {
  projectId: string;
  /** When false, the button renders disabled — the page is
   *  read-only (no lock held). PDF export is treated as a write
   *  because it consumes the same `requested_by` user row + leaves
   *  a permanent server-side artifact. */
  canExport: boolean;
  /** For the "By floor plan" filter dropdown. Empty when the project
   *  has no plans — the option hides automatically. */
  floorPlans: FloorPlanSummary[];
}

const DEFAULT_OPTIONS: PdfExportOptions = {
  pageSize: "letter",
  photosPerPage: 1,
  photoFilter: "all",
  floorPlanId: null,
  includeTrashed: false,
  includeCoverPage: true,
  includeFloorPlanPages: true,
};

type State =
  | { kind: "idle" }
  | { kind: "queued"; job: PdfExportJob }
  | { kind: "running"; job: PdfExportJob }
  | { kind: "done"; job: PdfExportJob; downloadUrl: string }
  | { kind: "failed"; job: PdfExportJob; message: string }
  | { kind: "error"; message: string };

const POLL_MS = 2_000;

export function ExportPdfControl({ projectId, canExport, floorPlans }: Props) {
  const [state, setState] = useState<State>({ kind: "idle" });
  const [showModal, setShowModal] = useState(false);
  const [options, setOptions] = useState<PdfExportOptions>(() => ({
    ...DEFAULT_OPTIONS,
    // If the project has exactly one plan and the user picks
    // "By floor plan," pre-fill it so they don't have to.
    floorPlanId: floorPlans.length === 1 ? floorPlans[0]!.id : null,
  }));
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

  function start(opts: PdfExportOptions) {
    setShowModal(false);
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
      .createPdfExport(projectId, opts)
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
        onClick={() => setShowModal(true)}
        disabled={!canExport || inFlight}
        className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
        title={
          canExport
            ? "Open the PDF export options. The download starts when the render completes."
            : "Take the edit lock first."
        }
      >
        Export PDF
      </button>

      {showModal && (
        <ExportOptionsModal
          options={options}
          onChange={setOptions}
          floorPlans={floorPlans}
          onCancel={() => setShowModal(false)}
          onSubmit={() => start(options)}
        />
      )}
    </div>
  );
}

interface ModalProps {
  options: PdfExportOptions;
  onChange: (next: PdfExportOptions) => void;
  floorPlans: FloorPlanSummary[];
  onCancel: () => void;
  onSubmit: () => void;
}

function ExportOptionsModal({
  options,
  onChange,
  floorPlans,
  onCancel,
  onSubmit,
}: ModalProps) {
  function patch(p: Partial<PdfExportOptions>) {
    onChange({ ...options, ...p });
  }
  const submitDisabled =
    options.photoFilter === "byFloorPlan" && !options.floorPlanId;
  return (
    <div
      role="dialog"
      aria-modal="true"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
    >
      <div className="flex w-full max-w-md flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
        <h2 className="text-base font-semibold text-neutral-100">
          Export PDF — options
        </h2>

        <label className="flex flex-col gap-1 text-xs text-neutral-400">
          Page size
          <select
            value={options.pageSize}
            onChange={(e) =>
              patch({ pageSize: e.target.value as PdfExportOptions["pageSize"] })
            }
            className="rounded border border-neutral-700 bg-neutral-950 p-2 text-sm text-neutral-100"
          >
            <option value="letter">Letter (8.5 × 11 in)</option>
            <option value="a4">A4 (210 × 297 mm)</option>
          </select>
        </label>

        <label className="flex flex-col gap-1 text-xs text-neutral-400">
          Photos per page
          <select
            value={options.photosPerPage}
            onChange={(e) =>
              patch({
                photosPerPage: Number(e.target.value) as PdfExportOptions["photosPerPage"],
              })
            }
            className="rounded border border-neutral-700 bg-neutral-950 p-2 text-sm text-neutral-100"
          >
            <option value={1}>1 (full size, with AI fields)</option>
            <option value={2}>2 (stacked, contact-sheet feel)</option>
            <option value={4}>4 (compact grid)</option>
          </select>
        </label>

        <label className="flex flex-col gap-1 text-xs text-neutral-400">
          Photo filter
          <select
            value={options.photoFilter}
            onChange={(e) =>
              patch({
                photoFilter: e.target.value as PdfExportOptions["photoFilter"],
              })
            }
            className="rounded border border-neutral-700 bg-neutral-950 p-2 text-sm text-neutral-100"
          >
            <option value="all">All photos</option>
            <option value="favorites">Favorites only</option>
            {floorPlans.length > 0 && (
              <option value="byFloorPlan">By floor plan</option>
            )}
          </select>
        </label>

        {options.photoFilter === "byFloorPlan" && floorPlans.length > 0 && (
          <label className="flex flex-col gap-1 text-xs text-neutral-400">
            Floor plan
            <select
              value={options.floorPlanId ?? ""}
              onChange={(e) =>
                patch({ floorPlanId: e.target.value || null })
              }
              className="rounded border border-neutral-700 bg-neutral-950 p-2 text-sm text-neutral-100"
            >
              <option value="">(pick one)</option>
              {floorPlans.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.label}
                </option>
              ))}
            </select>
          </label>
        )}

        <div className="flex flex-col gap-2 border-t border-neutral-800 pt-3 text-xs text-neutral-300">
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={options.includeCoverPage}
              onChange={(e) => patch({ includeCoverPage: e.target.checked })}
            />
            Include cover page
          </label>
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={options.includeFloorPlanPages}
              onChange={(e) =>
                patch({ includeFloorPlanPages: e.target.checked })
              }
            />
            Include floor-plan pages (with pin overlay)
          </label>
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={options.includeTrashed}
              onChange={(e) => patch({ includeTrashed: e.target.checked })}
            />
            Include trashed photos
          </label>
        </div>

        <div className="flex justify-end gap-3 pt-2">
          <button
            type="button"
            onClick={onCancel}
            className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={onSubmit}
            disabled={submitDisabled}
            className="rounded border border-blue-500 bg-blue-600/80 px-4 py-1.5 text-sm font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
            title={
              submitDisabled
                ? "Pick a floor plan above first."
                : "Generate the PDF with these options."
            }
          >
            Generate PDF
          </button>
        </div>
      </div>
    </div>
  );
}
