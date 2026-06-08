import { useState } from "react";
import type { Bucket, FloorPlan } from "@forensic/shared";

/**
 * Batch action bar (Build #5.82.1 — Path P #7/8).
 *
 * Floats above the photo list when select mode is on. Surfaces four
 * actions iOS's `selectionActionRow` exposes:
 *
 *   - Move to bucket — assigns `bucketID` on every selected photo
 *     (or clears it via the "— None —" sentinel).
 *   - Move to level — assigns `floorPlanID` on every selected photo
 *     (NOT the pixel coords — that's the canvas pin-drag UI on the
 *     Floor Plan tab).
 *   - Apply tag — appends a confidence-1.0 tag to every selected
 *     photo, dedup'd case-insensitively against existing tags.
 *   - Delete — soft-delete via `trashedAt = now`; the photo moves
 *     out of `photos` and into `trashedPhotos` (Trash UI in PR #8).
 *
 * Re-tag-with-AI on a selection is deferred — `useBatchRetag`
 * doesn't accept a photoIds filter yet, and bolting one on is a
 * bigger change than warrants this PR. Today the AI tab's
 * "skip-already-tagged" toggle gives an "untagged-only" axis that
 * covers most of the actual workflow.
 */
interface Props {
  count: number;
  buckets: Bucket[];
  floorPlans: FloorPlan[];
  onMoveToBucket: (bucketId: string | null) => void;
  onMoveToLevel: (floorPlanId: string | null) => void;
  onApplyTag: (label: string) => void;
  onDelete: () => void;
  onClearSelection: () => void;
}

export function SelectionActionBar({
  count,
  buckets,
  floorPlans,
  onMoveToBucket,
  onMoveToLevel,
  onApplyTag,
  onDelete,
  onClearSelection,
}: Props) {
  const [tagInput, setTagInput] = useState("");
  const [confirmDelete, setConfirmDelete] = useState(false);

  function applyTag() {
    const label = tagInput.trim();
    if (label.length === 0) return;
    onApplyTag(label);
    setTagInput("");
  }

  return (
    <>
      <div className="sticky top-0 z-30 -mx-2 mb-2 flex flex-wrap items-center gap-2 rounded border border-blue-700/50 bg-blue-950/60 px-3 py-2 text-xs text-blue-100 backdrop-blur">
        <span className="font-medium">
          {count} selected
        </span>

        <span className="text-blue-300">·</span>

        <label className="flex items-center gap-1">
          <span className="text-blue-200">Bucket:</span>
          <select
            onChange={(e) => {
              const v = e.target.value;
              if (v === "__noop__") return;
              onMoveToBucket(v === "__none__" ? null : v);
              e.currentTarget.value = "__noop__";
            }}
            defaultValue="__noop__"
            className="rounded border border-neutral-700 bg-neutral-950 px-1 py-0.5 text-xs text-neutral-100"
          >
            <option value="__noop__">— Move to… —</option>
            <option value="__none__">— None —</option>
            {[...buckets]
              .sort((a, b) => a.sortOrder - b.sortOrder)
              .map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name}
                </option>
              ))}
          </select>
        </label>

        <label className="flex items-center gap-1">
          <span className="text-blue-200">Level:</span>
          <select
            onChange={(e) => {
              const v = e.target.value;
              if (v === "__noop__") return;
              onMoveToLevel(v === "__none__" ? null : v);
              e.currentTarget.value = "__noop__";
            }}
            defaultValue="__noop__"
            className="rounded border border-neutral-700 bg-neutral-950 px-1 py-0.5 text-xs text-neutral-100"
          >
            <option value="__noop__">— Move to… —</option>
            <option value="__none__">— None —</option>
            {floorPlans.map((p) => (
              <option key={p.id} value={p.id}>
                {p.label}
              </option>
            ))}
          </select>
        </label>

        <label className="flex items-center gap-1">
          <span className="text-blue-200">Tag:</span>
          <input
            type="text"
            value={tagInput}
            onChange={(e) => setTagInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                applyTag();
              }
            }}
            placeholder="label, Enter"
            className="w-32 rounded border border-neutral-700 bg-neutral-950 px-1 py-0.5 text-xs text-neutral-100 placeholder:text-neutral-500"
          />
          <button
            type="button"
            onClick={applyTag}
            disabled={tagInput.trim().length === 0}
            className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Apply
          </button>
        </label>

        <button
          type="button"
          onClick={() => setConfirmDelete(true)}
          className="rounded border border-red-600 bg-red-700/30 px-2 py-0.5 text-xs text-red-100 hover:bg-red-700/50"
        >
          Delete
        </button>

        <span className="ml-auto">
          <button
            type="button"
            onClick={onClearSelection}
            className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800"
          >
            Clear selection
          </button>
        </span>
      </div>

      {confirmDelete && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">
              Move <span className="font-semibold">{count}</span> photo
              {count === 1 ? "" : "s"} to trash?
              <div className="mt-2 text-xs text-neutral-400">
                Trashed photos still live on the server until you empty
                the trash; you can restore them from the Trash section
                if you change your mind.
              </div>
            </div>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmDelete(false)}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => {
                  setConfirmDelete(false);
                  onDelete();
                }}
                className="rounded border border-red-600 bg-red-700/40 px-4 py-1.5 text-sm text-red-100 hover:bg-red-700/60"
              >
                Move to trash
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
