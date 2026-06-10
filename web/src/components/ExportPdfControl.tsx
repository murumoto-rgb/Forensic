import { useEffect, useRef, useState } from "react";
import type {
  PdfExportJob,
  PdfExportOptions,
  PdfPlanMode,
  PdfSection,
} from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { useUserPrefs } from "../lib/useUserPrefs";

/**
 * "Export PDF" button + iOS-parity options modal + status pill
 * (Build #5.62.1 / #5.63.1 / #5.64.1 / #5.73.1, plan item #3).
 *
 * As of #5.73.1 (Path C #8/8) the modal exposes the same option
 * surface iOS's `PDFExportOptionsView` does: page size, flexible
 * `perPage` (1-12), section toggles + iOS-default ordering,
 * per-plan multi-select, plan render mode, five annotation toggles,
 * bucket grouping, plus the web-specific carryovers (includeCoverPage,
 * includeTrashed). The legacy #5.64.1 fields (`photosPerPage`,
 * `photoFilter`, `floorPlanId`, `includeFloorPlanPages`) are no
 * longer in the wire shape — the server's `applyOptionDefaults` no
 * longer needs them as a bridge.
 *
 * Click → modal → "Generate PDF" submits a job. The component polls
 * `/v1/exports/:jobId` every 2 s until done/failed; on done it
 * auto-fires a hidden `<a>` click on the presigned R2 URL so the
 * PDF downloads without a second user gesture.
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
  /** For the per-plan multi-select. Empty when the project has no
   *  plans — that section collapses out automatically. */
  floorPlans: FloorPlanSummary[];
}

/** iOS-parity defaults — match `DEFAULT_PDF_EXPORT_OPTIONS` on the
 *  server (which itself matches iOS `PDFExportOptions.defaults`). */
const DEFAULT_OPTIONS: PdfExportOptions = {
  // Layout
  pageSize: "letter",
  perPage: 6,
  // Sections — iOS default order is [plan, contactSheets, metadataTable].
  sectionOrder: ["plan", "contactSheets", "metadataTable"],
  includeCoverPage: true,
  includeMetadataTable: false,
  // Floor plans
  planMode: "photoOnly",
  selectedFloorIds: null, // null = all plans
  // Annotations (tags-only matches iOS `AnnotationOptions.defaults`)
  annotations: {
    includeTags: true,
    includeCaption: false,
    includeObservation: false,
    includeMeasurement: false,
    includeReviewerFlag: false,
  },
  // Filters
  groupByBucket: false,
  includeTrashed: false,
  // Build #6.20.1: overwritten at start() with the user's on-screen
  // pin-size preference so the PDF matches the plan tab.
  pinScale: 1,
};

/** Reorder helper: rebuild `sectionOrder` from the include flags
 *  while preserving the iOS canonical order. */
const CANONICAL_SECTION_ORDER: PdfSection[] = [
  "plan",
  "contactSheets",
  "metadataTable",
];
function sectionOrderFromFlags(flags: {
  plan: boolean;
  contactSheets: boolean;
  metadataTable: boolean;
}): PdfSection[] {
  return CANONICAL_SECTION_ORDER.filter((s) => flags[s]);
}

type State =
  | { kind: "idle" }
  | { kind: "queued"; job: PdfExportJob }
  | { kind: "running"; job: PdfExportJob }
  | { kind: "done"; job: PdfExportJob; downloadUrl: string }
  | { kind: "failed"; job: PdfExportJob; message: string }
  | { kind: "error"; message: string };

/** A placeholder job for optimistic UI before the server responds /
 *  for a resumed job we don't have full details on yet. */
function makePendingJob(projectId: string, id: string): PdfExportJob {
  return {
    id,
    projectId,
    status: "queued",
    pdfObjectKey: null,
    errorMessage: null,
    createdAt: new Date().toISOString(),
    startedAt: null,
    completedAt: null,
    progressDoneChunks: null,
    progressTotalChunks: null,
  };
}

/** Human-readable progress string from a job's chunk counters. */
function progressLabel(job: PdfExportJob): string {
  const done = job.progressDoneChunks;
  const total = job.progressTotalChunks;
  if (total != null && total > 0 && done != null) {
    const pct = Math.round((done / total) * 100);
    return `Rendering… ${done} / ${total} (${pct}%)`;
  }
  return "Rendering…";
}

const POLL_MS = 2_000;
/** Stop polling after this long even if the server still says running
 *  (Build #6.15.1). A stuck render would otherwise poll forever; this
 *  caps it at 10 minutes — long enough that legitimate large exports
 *  finish, short enough that a dead job surfaces an error. The job
 *  itself keeps existing server-side; the user can refresh or open
 *  the exports page to see its final state. */
const POLL_TIMEOUT_MS = 10 * 60 * 1000;

/** localStorage key for the in-flight job id, scoped per project so
 *  two project tabs don't clobber each other (Build #5.75.1). */
function activeJobStorageKey(projectId: string): string {
  return `forensic.pdfExport.activeJob.${projectId}`;
}

export function ExportPdfControl({
  projectId,
  canExport,
  floorPlans,
}: Props) {
  const [state, setState] = useState<State>({ kind: "idle" });
  const [showModal, setShowModal] = useState(false);
  const [options, setOptions] = useState<PdfExportOptions>(DEFAULT_OPTIONS);
  // Build #6.20.1: the plan-tab pin-size preference flows into the
  // export so the PDF's pins match what the user sees on screen
  // (iOS's exporter has always done the equivalent).
  const userPrefs = useUserPrefs();
  const pollRef = useRef<number | null>(null);
  const activeJobIdRef = useRef<string | null>(null);
  /** Wall-clock timestamp (ms) when polling for the active job
   *  started. `poll` uses it to time out a stuck render
   *  (Build #6.15.1). */
  const pollStartedAtRef = useRef<number | null>(null);

  function clearPoll() {
    if (pollRef.current !== null) {
      window.clearInterval(pollRef.current);
      pollRef.current = null;
    }
    pollStartedAtRef.current = null;
  }

  // Persist / clear the active job id so a refresh or navigate-away
  // can resume polling the same render (Build #5.75.1). The render
  // keeps running server-side regardless; this just lets the UI
  // reconnect to it and surface the download when it's ready.
  function rememberActiveJob(jobId: string) {
    try {
      window.localStorage.setItem(activeJobStorageKey(projectId), jobId);
    } catch {
      // Private-mode / storage-disabled — degrade to in-memory only.
    }
  }
  function forgetActiveJob() {
    try {
      window.localStorage.removeItem(activeJobStorageKey(projectId));
    } catch {
      /* ignore */
    }
  }

  useEffect(() => {
    return () => clearPoll();
  }, []);

  // On mount, resume any in-flight job persisted for this project.
  // Picks up a render the user started before refreshing / leaving.
  useEffect(() => {
    let resumedJobId: string | null = null;
    try {
      resumedJobId = window.localStorage.getItem(
        activeJobStorageKey(projectId)
      );
    } catch {
      resumedJobId = null;
    }
    if (!resumedJobId) return;
    activeJobIdRef.current = resumedJobId;
    // Build #6.15.1: a resumed job's clock starts now — we don't
    // know how long it's already been running on the server, but
    // the 10-min budget covers further waiting from this tab.
    pollStartedAtRef.current = Date.now();
    setState({
      kind: "running",
      job: makePendingJob(projectId, resumedJobId),
    });
    pollRef.current = window.setInterval(
      () => poll(resumedJobId!),
      POLL_MS
    );
    poll(resumedJobId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId]);

  function poll(jobId: string) {
    if (activeJobIdRef.current !== jobId) return;
    // Build #6.15.1: bail out of a stuck render so the spinner can't
    // hang the UI forever. The poll task already self-guards on
    // activeJobIdRef mismatch, so this branch only fires when the
    // current job has run past the wall-clock budget.
    const startedAt = pollStartedAtRef.current;
    if (startedAt !== null && Date.now() - startedAt > POLL_TIMEOUT_MS) {
      clearPoll();
      activeJobIdRef.current = null;
      forgetActiveJob();
      setState({
        kind: "error",
        message:
          "Export is taking longer than 10 minutes. Check the Exports page for the final status — the render keeps running on the server.",
      });
      return;
    }
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
          forgetActiveJob();
          if (res.downloadUrl) {
            setState({ kind: "done", job, downloadUrl: res.downloadUrl });
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
          forgetActiveJob();
          setState({
            kind: "failed",
            job,
            message: job.errorMessage ?? "Render failed",
          });
        }
      })
      .catch((e: unknown) => {
        if (e instanceof ApiError && e.status === 404) {
          clearPoll();
          activeJobIdRef.current = null;
          forgetActiveJob();
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
    setState({ kind: "queued", job: makePendingJob(projectId, "(pending)") });
    api
      .createPdfExport(projectId, { ...opts, pinScale: userPrefs.bubbleScale })
      .then((res) => {
        const jobId = res.job.id;
        activeJobIdRef.current = jobId;
        pollStartedAtRef.current = Date.now();
        rememberActiveJob(jobId);
        setState({ kind: "queued", job: res.job });
        pollRef.current = window.setInterval(() => poll(jobId), POLL_MS);
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
    forgetActiveJob();
    setState({ kind: "idle" });
  }

  const inFlight = state.kind === "queued" || state.kind === "running";

  return (
    <div className="flex items-center gap-2">
      {state.kind === "queued" && (
        <span className="flex items-center gap-1.5 text-xs text-neutral-400">
          <span className="inline-block h-2 w-2 animate-pulse rounded-full bg-blue-400" />
          Queued…
        </span>
      )}
      {state.kind === "running" && (
        <span className="flex items-center gap-1.5 text-xs text-neutral-300">
          <span className="inline-block h-2 w-2 animate-pulse rounded-full bg-blue-400" />
          {progressLabel(state.job)}
        </span>
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
      {(state.kind === "done" ||
        state.kind === "failed" ||
        state.kind === "error") && (
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

/** Common option values for the perPage select (matches iOS-supported
 *  grid layouts from `gridDimensions` on the server). */
const PER_PAGE_OPTIONS: number[] = [1, 2, 3, 4, 6, 8, 9, 12];

const PLAN_MODE_LABELS: Record<PdfPlanMode, string> = {
  photoOnly: "Photo pins only",
  distressOnly: "Distress markers only",
  photoAndDistressSeparate: "Photos + distress (separate pages)",
  merged: "Photos + distress (merged)",
};

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
  function patchAnnotations(a: Partial<PdfExportOptions["annotations"]>) {
    onChange({
      ...options,
      annotations: { ...options.annotations, ...a },
    });
  }

  // Section toggles derive from the sectionOrder array. "Plan" /
  // "Contact sheets" / "Metadata table" each are checked when their
  // PdfSection appears in the array.
  const sectionFlags = {
    plan: options.sectionOrder.includes("plan"),
    contactSheets: options.sectionOrder.includes("contactSheets"),
    metadataTable: options.sectionOrder.includes("metadataTable"),
  };
  function toggleSection(s: PdfSection, on: boolean) {
    const next = { ...sectionFlags, [s]: on };
    onChange({
      ...options,
      sectionOrder: sectionOrderFromFlags(next),
      // Keep `includeMetadataTable` in lockstep with its
      // sectionOrder presence — the server reads `includeMetadataTable`
      // for the boolean gate, sectionOrder for placement, so we set
      // both consistently from the same checkbox.
      ...(s === "metadataTable" ? { includeMetadataTable: on } : {}),
    });
  }

  // Floor-plan filter: "All" vs "Specific". When Specific is picked
  // with no plans checked, submit is disabled — that's a "select
  // nothing" state we don't want silently submitted.
  const floorFilterMode: "all" | "specific" =
    options.selectedFloorIds === null ? "all" : "specific";
  function setFloorFilterMode(mode: "all" | "specific") {
    if (mode === "all") {
      patch({ selectedFloorIds: null });
    } else {
      patch({ selectedFloorIds: [] });
    }
  }
  function toggleFloorPlan(planId: string, on: boolean) {
    const current = options.selectedFloorIds ?? [];
    const next = on
      ? Array.from(new Set([...current, planId]))
      : current.filter((id) => id !== planId);
    patch({ selectedFloorIds: next });
  }

  const submitDisabled =
    floorFilterMode === "specific" &&
    (options.selectedFloorIds?.length ?? 0) === 0;

  return (
    <div
      role="dialog"
      aria-modal="true"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
    >
      <div className="flex max-h-[90vh] w-full max-w-lg flex-col rounded-lg border border-neutral-700 bg-neutral-900 shadow-2xl">
        <h2 className="border-b border-neutral-800 px-6 py-4 text-base font-semibold text-neutral-100">
          Export PDF — options
        </h2>

        <div className="flex flex-col gap-5 overflow-y-auto px-6 py-4">
          {/* Layout */}
          <fieldset className="flex flex-col gap-2">
            <legend className="text-xs uppercase tracking-wide text-neutral-500">
              Layout
            </legend>
            <label className="flex items-center justify-between gap-3 text-sm text-neutral-200">
              Page size
              <select
                value={options.pageSize}
                onChange={(e) =>
                  patch({
                    pageSize: e.target.value as PdfExportOptions["pageSize"],
                  })
                }
                className="min-w-[10rem] rounded border border-neutral-700 bg-neutral-950 p-1.5 text-sm text-neutral-100"
              >
                <option value="letter">Letter (8.5 × 11 in)</option>
                <option value="a4">A4 (210 × 297 mm)</option>
              </select>
            </label>
            <label className="flex items-center justify-between gap-3 text-sm text-neutral-200">
              Photos per page
              <select
                value={options.perPage}
                onChange={(e) =>
                  patch({ perPage: Number(e.target.value) })
                }
                className="min-w-[10rem] rounded border border-neutral-700 bg-neutral-950 p-1.5 text-sm text-neutral-100"
              >
                {PER_PAGE_OPTIONS.map((n) => (
                  <option key={n} value={n}>
                    {n}
                  </option>
                ))}
              </select>
            </label>
          </fieldset>

          {/* Sections */}
          <fieldset className="flex flex-col gap-2 border-t border-neutral-800 pt-4">
            <legend className="text-xs uppercase tracking-wide text-neutral-500">
              Sections
            </legend>
            <label className="flex items-center gap-2 text-sm text-neutral-200">
              <input
                type="checkbox"
                checked={options.includeCoverPage}
                onChange={(e) => patch({ includeCoverPage: e.target.checked })}
              />
              Cover page (always first)
            </label>
            <label className="flex items-center gap-2 text-sm text-neutral-200">
              <input
                type="checkbox"
                checked={sectionFlags.plan}
                onChange={(e) => toggleSection("plan", e.target.checked)}
              />
              Floor plan pages
            </label>
            <label className="flex items-center gap-2 text-sm text-neutral-200">
              <input
                type="checkbox"
                checked={sectionFlags.contactSheets}
                onChange={(e) =>
                  toggleSection("contactSheets", e.target.checked)
                }
              />
              Contact sheets (photos)
            </label>
            <label className="flex items-center gap-2 text-sm text-neutral-200">
              <input
                type="checkbox"
                checked={sectionFlags.metadataTable}
                onChange={(e) =>
                  toggleSection("metadataTable", e.target.checked)
                }
              />
              Metadata table
            </label>
            <p className="mt-1 text-xs text-neutral-500">
              Sections render in iOS-canonical order: floor plans →
              contact sheets → metadata table.
            </p>
          </fieldset>

          {/* Floor plans (mode + which-plans) */}
          {sectionFlags.plan && floorPlans.length > 0 && (
            <fieldset className="flex flex-col gap-2 border-t border-neutral-800 pt-4">
              <legend className="text-xs uppercase tracking-wide text-neutral-500">
                Floor plans
              </legend>
              <label className="flex items-center justify-between gap-3 text-sm text-neutral-200">
                Render mode
                <select
                  value={options.planMode}
                  onChange={(e) =>
                    patch({ planMode: e.target.value as PdfPlanMode })
                  }
                  className="min-w-[15rem] rounded border border-neutral-700 bg-neutral-950 p-1.5 text-sm text-neutral-100"
                >
                  {(Object.keys(PLAN_MODE_LABELS) as PdfPlanMode[]).map((m) => (
                    <option key={m} value={m}>
                      {PLAN_MODE_LABELS[m]}
                    </option>
                  ))}
                </select>
              </label>
              <div className="flex flex-col gap-1 pt-2">
                <span className="text-xs text-neutral-500">
                  Which floor plans to include
                </span>
                <label className="flex items-center gap-2 text-sm text-neutral-200">
                  <input
                    type="radio"
                    name="floorFilterMode"
                    checked={floorFilterMode === "all"}
                    onChange={() => setFloorFilterMode("all")}
                  />
                  All floor plans
                </label>
                <label className="flex items-center gap-2 text-sm text-neutral-200">
                  <input
                    type="radio"
                    name="floorFilterMode"
                    checked={floorFilterMode === "specific"}
                    onChange={() => setFloorFilterMode("specific")}
                  />
                  Specific:
                </label>
                {floorFilterMode === "specific" && (
                  <div className="ml-6 flex flex-col gap-1">
                    {floorPlans.map((p) => (
                      <label
                        key={p.id}
                        className="flex items-center gap-2 text-sm text-neutral-300"
                      >
                        <input
                          type="checkbox"
                          checked={
                            options.selectedFloorIds?.includes(p.id) ?? false
                          }
                          onChange={(e) =>
                            toggleFloorPlan(p.id, e.target.checked)
                          }
                        />
                        {p.label}
                      </label>
                    ))}
                  </div>
                )}
              </div>
            </fieldset>
          )}

          {/* Annotations (per contact-sheet cell) */}
          {sectionFlags.contactSheets && (
            <fieldset className="flex flex-col gap-2 border-t border-neutral-800 pt-4">
              <legend className="text-xs uppercase tracking-wide text-neutral-500">
                Per-photo annotations
              </legend>
              <p className="text-xs text-neutral-500">
                Shown under each contact-sheet cell.
              </p>
              <label className="flex items-center gap-2 text-sm text-neutral-200">
                <input
                  type="checkbox"
                  checked={options.annotations.includeTags}
                  onChange={(e) =>
                    patchAnnotations({ includeTags: e.target.checked })
                  }
                />
                Tags
              </label>
              <label className="flex items-center gap-2 text-sm text-neutral-200">
                <input
                  type="checkbox"
                  checked={options.annotations.includeCaption}
                  onChange={(e) =>
                    patchAnnotations({ includeCaption: e.target.checked })
                  }
                />
                Caption
              </label>
              <label className="flex items-center gap-2 text-sm text-neutral-200">
                <input
                  type="checkbox"
                  checked={options.annotations.includeObservation}
                  onChange={(e) =>
                    patchAnnotations({ includeObservation: e.target.checked })
                  }
                />
                Observation
              </label>
              <label className="flex items-center gap-2 text-sm text-neutral-200">
                <input
                  type="checkbox"
                  checked={options.annotations.includeMeasurement}
                  onChange={(e) =>
                    patchAnnotations({ includeMeasurement: e.target.checked })
                  }
                />
                Measurement
              </label>
              <label className="flex items-center gap-2 text-sm text-neutral-200">
                <input
                  type="checkbox"
                  checked={options.annotations.includeReviewerFlag}
                  onChange={(e) =>
                    patchAnnotations({ includeReviewerFlag: e.target.checked })
                  }
                />
                Reviewer flag
              </label>
            </fieldset>
          )}

          {/* Filters & grouping */}
          <fieldset className="flex flex-col gap-2 border-t border-neutral-800 pt-4">
            <legend className="text-xs uppercase tracking-wide text-neutral-500">
              Filters
            </legend>
            <label className="flex items-center gap-2 text-sm text-neutral-200">
              <input
                type="checkbox"
                checked={options.groupByBucket}
                onChange={(e) => patch({ groupByBucket: e.target.checked })}
              />
              Group photos by bucket (with divider pages)
            </label>
            <label className="flex items-center gap-2 text-sm text-neutral-200">
              <input
                type="checkbox"
                checked={options.includeTrashed}
                onChange={(e) => patch({ includeTrashed: e.target.checked })}
              />
              Include trashed photos
            </label>
          </fieldset>
        </div>

        <div className="flex justify-end gap-3 border-t border-neutral-800 px-6 py-4">
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
                ? "Pick at least one floor plan, or switch to All."
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
