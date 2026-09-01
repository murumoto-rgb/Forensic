import { useEffect, useRef, useState } from "react";
import type { AITagPhotoModel, Project } from "@forensic/shared";
import {
  useBatchRetag,
  type BatchOptions,
  type BatchPhotoOutcome,
} from "../lib/useBatchRetag";
import { useUserPrefs } from "../lib/useUserPrefs";
import { useEscapeKey } from "../lib/useEscapeKey";
import type { MutableRefObject } from "react";

/**
 * "Re-tag all with AI" — project-level button + options modal +
 * sticky progress panel. The second half of the web AI-tagging
 * command center (Build #5.42.1; Sprint C2 of the AI-tagging
 * completion plan). Drives `useBatchRetag` against the project's
 * photos and persists results through the same manifest PUT loop
 * single-photo Re-tag uses.
 *
 * The parent (`ProjectDetailPage`) owns the project + revision
 * state and passes refs in so the hook reads the latest values at
 * checkpoint time. After the batch runs, every successfully-tagged
 * photo has an updated `aiAnalysis` AND a fresh `pendingSuggestions`
 * list — the engineer reviews each photo on the floor-plan preview
 * panel (Sprint C1).
 */
export function BatchRetagControl({
  projectId,
  projectRef,
  revisionRef,
  setProject,
  setRevision,
  save,
  saveAndWait,
  photoCount,
  photoIds,
  buttonLabel,
  hideTriggerButton,
  initiallyOpen,
  onClose,
}: {
  projectId: string;
  projectRef: MutableRefObject<Project | null>;
  revisionRef: MutableRefObject<string | null>;
  setProject: (p: Project) => void;
  setRevision: (r: string) => void;
  save?: (p: Project) => void;
  saveAndWait?: (p: Project) => Promise<void>;
  /** Photos that COULD be tagged this run (e.g. project total, or
   *  the size of the current selection). Disables the trigger
   *  button when 0; modal still reads opts.skipAlreadyTagged so the
   *  actual subset is a function of both. */
  photoCount: number;
  /** Restrict the batch to these photo IDs. Omitted = whole project. */
  photoIds?: readonly string[];
  /** Override the trigger button label (default: "Re-tag all with AI"). */
  buttonLabel?: string;
  /** Hide the trigger button entirely — parent drives `initiallyOpen`. */
  hideTriggerButton?: boolean;
  /** Open the modal as soon as the component mounts. Used when this
   *  control is rendered transiently in response to a selection-bar
   *  click in PhotosTab. */
  initiallyOpen?: boolean;
  /** Fired when the user cancels the modal without starting OR
   *  dismisses the progress panel. Lets a transient parent unmount
   *  the control so the next trigger remounts cleanly. */
  onClose?: () => void;
}) {
  const [showModal, setShowModal] = useState(initiallyOpen ?? false);
  const prefs = useUserPrefs();
  // Read user prefs as the initial defaults; the modal still lets
  // the user override per-batch (the changes don't persist back to
  // prefs — that would feel surprising for a one-off override).
  // Initial values capture prefs at mount, which is the right moment
  // when `initiallyOpen` triggers a transient remount in PhotosTab.
  const [opts, setOpts] = useState<BatchOptions>({
    model: prefs.model,
    skipAlreadyTagged: true,
    concurrency: prefs.concurrency,
  });
  const didInitialize = useRef(false);
  useEffect(() => {
    if (didInitialize.current) return;
    didInitialize.current = true;
    if (initiallyOpen) {
      setOpts((cur) => ({
        ...cur,
        model: prefs.model,
        concurrency: prefs.concurrency,
      }));
    }
  }, [initiallyOpen, prefs.model, prefs.concurrency]);
  const { state, start, cancel, reset } = useBatchRetag({
    projectId,
    projectRef,
    revisionRef,
    setProject,
    setRevision,
    save,
    saveAndWait,
  });

  const inFlight =
    state.kind === "preparing" ||
    state.kind === "running" ||
    state.kind === "saving";
  // Build #6.17.1: Escape closes the modal — but only when the
  // batch isn't actually running. A live batch keeps streaming on
  // the server even if the user dismisses, so refusing Escape mid-
  // run prevents an accidental wipe of progress that the user
  // actually wants to watch.
  useEscapeKey(showModal && !inFlight, () => {
    setShowModal(false);
    onClose?.();
  });
  const finished =
    state.kind === "done" ||
    state.kind === "cancelled" ||
    state.kind === "error";

  return (
    <>
      {!hideTriggerButton && (
        <button
          type="button"
          onClick={() => {
            reset();
            // Refresh the per-batch defaults from current user prefs
            // so a settings change between batches is honored without
            // remounting the control.
            setOpts({
              model: prefs.model,
              skipAlreadyTagged: opts.skipAlreadyTagged,
              concurrency: prefs.concurrency,
            });
            setShowModal(true);
          }}
          disabled={photoCount === 0 || inFlight}
          className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
          title="Run AI tagging. Results land as pending suggestions to review on the photo editor."
        >
          {buttonLabel ?? "Re-tag all with AI"}
        </button>
      )}

      {showModal && !inFlight && !finished && (
        <BatchOptionsModal
          opts={opts}
          setOpts={setOpts}
          onCancel={() => {
            setShowModal(false);
            onClose?.();
          }}
          onStart={() => {
            setShowModal(false);
            void start(opts, photoIds);
          }}
        />
      )}

      {(inFlight || finished) && (
        <BatchProgressPanel
          state={state}
          onCancel={cancel}
          onDismiss={() => {
            reset();
            setShowModal(false);
            onClose?.();
          }}
        />
      )}
    </>
  );
}

function BatchOptionsModal({
  opts,
  setOpts,
  onCancel,
  onStart,
}: {
  opts: BatchOptions;
  setOpts: (next: BatchOptions) => void;
  onCancel: () => void;
  onStart: () => void;
}) {
  return (
    <div
      role="dialog"
      aria-modal="true"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
    >
      <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
        <div className="flex flex-col gap-1">
          <h2 className="text-base font-semibold text-neutral-100">
            Re-tag all photos with AI
          </h2>
          <p className="text-xs text-neutral-400">
            Results land as pending suggestions on each photo. Review
            them on the floor-plan preview panel.
          </p>
        </div>

        <label className="flex flex-col gap-1 text-xs">
          <span className="text-neutral-400">Model</span>
          <select
            value={opts.model}
            onChange={(e) =>
              setOpts({ ...opts, model: e.currentTarget.value as AITagPhotoModel })
            }
            className="rounded border border-neutral-700 bg-neutral-800 px-2 py-1 text-neutral-200"
          >
            <option value="claude-sonnet-4-6">Claude Sonnet 4.6 (careful)</option>
            <option value="claude-haiku-4-5">Claude Haiku 4.5 (fast)</option>
          </select>
        </label>

        <label className="flex flex-col gap-1 text-xs">
          <span className="text-neutral-400">
            Parallel requests: {opts.concurrency}
          </span>
          <input
            type="range"
            min={1}
            max={10}
            step={1}
            value={opts.concurrency}
            onChange={(e) =>
              setOpts({
                ...opts,
                concurrency: Number.parseInt(e.currentTarget.value, 10),
              })
            }
            className="accent-blue-500"
          />
          <span className="text-[10px] text-neutral-500">
            Higher = faster but more likely to hit Anthropic's rate limit.
            3 is safe on Tier 1; raise if you're on a higher tier.
          </span>
        </label>

        <label className="flex items-start gap-2 text-xs">
          <input
            type="checkbox"
            checked={opts.skipAlreadyTagged}
            onChange={(e) =>
              setOpts({ ...opts, skipAlreadyTagged: e.currentTarget.checked })
            }
            className="mt-0.5"
          />
          <span className="text-neutral-300">
            Skip photos that already have tags
            <span className="ml-1 text-neutral-500">(safer default)</span>
          </span>
        </label>

        <div className="flex justify-end gap-2">
          <button
            type="button"
            onClick={onCancel}
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={onStart}
            className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1 text-xs font-medium text-white hover:bg-blue-600"
          >
            Start
          </button>
        </div>
      </div>
    </div>
  );
}

function BatchProgressPanel({
  state,
  onCancel,
  onDismiss,
}: {
  state: ReturnType<typeof useBatchRetag>["state"];
  onCancel: () => void;
  onDismiss: () => void;
}) {
  const total = state.total || 1; // avoid div-by-zero
  const progressed = state.doneCount + state.failedCount;
  const percent = Math.round((progressed / total) * 100);
  const inFlight =
    state.kind === "preparing" ||
    state.kind === "running" ||
    state.kind === "saving";

  return (
    <div className="fixed bottom-4 left-4 z-40 w-80 rounded-lg border border-neutral-700 bg-neutral-900 shadow-2xl">
      <div className="flex items-center justify-between border-b border-neutral-800 px-3 py-2">
        <span className="text-sm font-semibold text-neutral-100">
          {state.kind === "preparing" && "Preparing batch…"}
          {state.kind === "running" && "Tagging…"}
          {state.kind === "saving" && "Saving checkpoint…"}
          {state.kind === "done" && "Done"}
          {state.kind === "cancelled" && "Cancelled"}
          {state.kind === "error" && "Error"}
          {state.kind === "idle" && "Idle"}
        </span>
        {inFlight ? (
          <button
            type="button"
            onClick={onCancel}
            className="rounded border border-neutral-700 px-2 py-0.5 text-[10px] text-neutral-300 hover:bg-neutral-800"
          >
            Cancel
          </button>
        ) : (
          <button
            type="button"
            onClick={onDismiss}
            className="rounded border border-neutral-700 px-2 py-0.5 text-[10px] text-neutral-300 hover:bg-neutral-800"
            aria-label="Dismiss"
          >
            ✕
          </button>
        )}
      </div>
      <div className="flex flex-col gap-2 px-3 py-3 text-xs">
        <div className="flex items-center justify-between font-mono text-neutral-400">
          <span>
            {progressed}/{total}
          </span>
          <span>{percent}%</span>
        </div>
        <div className="h-2 w-full overflow-hidden rounded bg-neutral-800">
          <div
            className={
              state.kind === "error"
                ? "h-full bg-red-600"
                : state.kind === "cancelled"
                  ? "h-full bg-amber-500"
                  : "h-full bg-blue-500"
            }
            style={{ width: `${percent}%` }}
          />
        </div>
        <div className="flex flex-wrap gap-2 text-neutral-400">
          <Stat
            color="text-emerald-300"
            label="Tagged"
            value={state.doneCount}
          />
          <Stat
            color="text-amber-300"
            label="Skipped"
            value={state.skippedCount}
          />
          <Stat
            color="text-red-300"
            label="Failed"
            value={state.failedCount}
          />
        </div>
        {state.errorMessage && (
          <div className="rounded border border-red-800 bg-red-950/40 px-2 py-1 text-[11px] text-red-200">
            {state.errorMessage}
          </div>
        )}
        {state.kind === "done" && state.failedCount === 0 && (
          <div className="rounded border border-emerald-800 bg-emerald-950/40 px-2 py-1 text-[11px] text-emerald-200">
            Batch complete. Open each photo's preview panel to review
            pending suggestions.
          </div>
        )}
        {state.failedCount > 0 && firstFailure(state.outcomes) && (
          <details className="text-[11px]">
            <summary className="cursor-pointer text-neutral-500 hover:text-neutral-300">
              Show first failure
            </summary>
            <div className="mt-1 rounded border border-neutral-800 bg-neutral-950 px-2 py-1 text-neutral-400">
              {firstFailure(state.outcomes)}
            </div>
          </details>
        )}
      </div>
    </div>
  );
}

function Stat({
  color,
  label,
  value,
}: {
  color: string;
  label: string;
  value: number;
}) {
  return (
    <span className="flex items-baseline gap-1">
      <span className={`font-mono font-semibold ${color}`}>{value}</span>
      <span className="text-[10px] uppercase tracking-wide">{label}</span>
    </span>
  );
}

function firstFailure(
  outcomes: Record<string, BatchPhotoOutcome>
): string | null {
  for (const o of Object.values(outcomes)) {
    if (o.kind === "failed") return `Photo ${o.photoId}: ${o.message}`;
  }
  return null;
}
