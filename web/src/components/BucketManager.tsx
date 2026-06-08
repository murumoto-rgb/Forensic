import { useState } from "react";
import type { Bucket, Project } from "@forensic/shared";

/**
 * Bucket CRUD (Build #5.80.1 — Path P #5/8; drag-reorder added
 * Build #5.87.1).
 *
 * Per-project bucket management — create (name + color), rename,
 * recolor, reorder, delete (with photo-impact preview). Counts
 * per bucket and the project-wide "unbucketed" count are live
 * against the manifest, not cached.
 *
 * Reorder modes:
 *   - HTML5 drag-and-drop on the grip handle (mouse / trackpad);
 *     drops the row at the new position and renumbers `sortOrder`
 *     contiguously from 0.
 *   - ↑ / ↓ buttons (keyboard accessibility — same UX iOS has);
 *     swaps `sortOrder` with the adjacent bucket.
 *
 * Delete nulls `bucketID` on every photo that referenced the
 * removed bucket (so existing bucket assignments don't dangle).
 */
interface Props {
  project: Project;
  canEdit: boolean;
  onProjectChanged: (next: Project) => void;
}

const COLOR_PALETTE = [
  "#ef4444", // red
  "#f97316", // orange
  "#eab308", // yellow
  "#22c55e", // green
  "#06b6d4", // cyan
  "#3b82f6", // blue
  "#8b5cf6", // violet
  "#ec4899", // pink
  "#a3a3a3", // neutral
];

function newUuid(): string {
  return crypto.randomUUID();
}

export function BucketManager({ project, canEdit, onProjectChanged }: Props) {
  const [draftName, setDraftName] = useState("");
  const [draftColor, setDraftColor] = useState(COLOR_PALETTE[0]!);
  const [confirmDelete, setConfirmDelete] = useState<Bucket | null>(null);
  // Track in-flight drag: the bucket being dragged + the index over
  // which the user is currently hovering. Indices are into the
  // visible (sorted) `buckets` array.
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);

  const buckets = [...project.buckets].sort(
    (a, b) => a.sortOrder - b.sortOrder
  );
  const photoCounts = new Map<string, number>();
  for (const photo of project.photos) {
    if (photo.bucketID == null) continue;
    photoCounts.set(photo.bucketID, (photoCounts.get(photo.bucketID) ?? 0) + 1);
  }
  const unbucketed = project.photos.filter((p) => p.bucketID == null).length;

  function addBucket() {
    if (!canEdit) return;
    const name = draftName.trim();
    if (name.length === 0) return;
    const maxOrder = buckets.reduce(
      (acc, b) => Math.max(acc, b.sortOrder),
      -1
    );
    const next: Bucket = {
      id: newUuid(),
      name,
      colorHex: draftColor,
      sortOrder: maxOrder + 1,
      libraryCategoryID: null,
    };
    onProjectChanged({
      ...project,
      buckets: [...project.buckets, next],
    });
    setDraftName("");
  }

  function renameBucket(id: string, name: string) {
    if (!canEdit) return;
    const trimmed = name.trim();
    if (trimmed.length === 0) return;
    onProjectChanged({
      ...project,
      buckets: project.buckets.map((b) =>
        b.id === id ? { ...b, name: trimmed } : b
      ),
    });
  }

  function recolorBucket(id: string, color: string) {
    if (!canEdit) return;
    onProjectChanged({
      ...project,
      buckets: project.buckets.map((b) =>
        b.id === id ? { ...b, colorHex: color } : b
      ),
    });
  }

  function move(id: string, direction: "up" | "down") {
    if (!canEdit) return;
    const idx = buckets.findIndex((b) => b.id === id);
    if (idx === -1) return;
    const swap = direction === "up" ? idx - 1 : idx + 1;
    if (swap < 0 || swap >= buckets.length) return;
    const a = buckets[idx]!;
    const b = buckets[swap]!;
    onProjectChanged({
      ...project,
      buckets: project.buckets.map((bk) => {
        if (bk.id === a.id) return { ...bk, sortOrder: b.sortOrder };
        if (bk.id === b.id) return { ...bk, sortOrder: a.sortOrder };
        return bk;
      }),
    });
  }

  /**
   * Splice the dragged bucket into a new position and renumber
   * `sortOrder` contiguously from 0. Renumbering keeps the
   * underlying field tidy after many drops, and the up/down
   * buttons keep working because they swap adjacent values.
   */
  function reorderByDrop(draggedId: string, targetIdx: number) {
    if (!canEdit) return;
    const fromIdx = buckets.findIndex((b) => b.id === draggedId);
    if (fromIdx === -1 || fromIdx === targetIdx) return;
    const next = [...buckets];
    const [moved] = next.splice(fromIdx, 1);
    // After splice, indices >= fromIdx shift left by one; if the
    // target was past the dragged item, decrement to compensate.
    const insertAt = targetIdx > fromIdx ? targetIdx - 1 : targetIdx;
    next.splice(insertAt, 0, moved!);
    const renumbered = next.map((b, i) => ({ ...b, sortOrder: i }));
    // Preserve buckets that aren't in `buckets` (none today, but
    // future-proof if filtering ever lands).
    const renumberedIds = new Set(renumbered.map((b) => b.id));
    const untouched = project.buckets.filter((b) => !renumberedIds.has(b.id));
    onProjectChanged({
      ...project,
      buckets: [...untouched, ...renumbered],
    });
  }

  function deleteBucket(id: string) {
    if (!canEdit) return;
    onProjectChanged({
      ...project,
      buckets: project.buckets.filter((b) => b.id !== id),
      photos: project.photos.map((p) =>
        p.bucketID === id ? { ...p, bucketID: null } : p
      ),
    });
    setConfirmDelete(null);
  }

  return (
    <div className="flex flex-col gap-4">
      {/* Create row */}
      <section className="rounded border border-neutral-800 bg-neutral-900/40 p-3">
        <div className="mb-2 text-xs uppercase tracking-wide text-neutral-500">
          Create bucket
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <input
            type="text"
            value={draftName}
            onChange={(e) => setDraftName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                addBucket();
              }
            }}
            placeholder="Bucket name"
            disabled={!canEdit}
            className="rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-600 disabled:opacity-50"
          />
          <ColorSwatchPicker
            color={draftColor}
            onChange={setDraftColor}
            disabled={!canEdit}
          />
          <button
            type="button"
            onClick={addBucket}
            disabled={!canEdit || draftName.trim().length === 0}
            className="rounded border border-blue-600 bg-blue-700/40 px-3 py-1 text-sm text-blue-100 hover:bg-blue-700/60 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Add bucket
          </button>
          {!canEdit && (
            <span className="text-xs text-neutral-500">
              Take the edit lock to modify buckets.
            </span>
          )}
        </div>
      </section>

      {/* Bucket list */}
      {buckets.length === 0 ? (
        <div className="rounded border border-dashed border-neutral-800 p-6 text-center text-sm text-neutral-500">
          No buckets defined yet. Add one above — they show up in the
          per-photo editor and in PDF exports.
        </div>
      ) : (
        <ul className="flex flex-col gap-2">
          {buckets.map((bucket, idx) => {
            const count = photoCounts.get(bucket.id) ?? 0;
            const isDragging = draggingId === bucket.id;
            const isHovered = hoverIdx === idx && draggingId !== null && !isDragging;
            return (
              <li
                key={bucket.id}
                onDragOver={(e) => {
                  if (draggingId == null) return;
                  e.preventDefault();
                  setHoverIdx(idx);
                }}
                onDrop={(e) => {
                  e.preventDefault();
                  if (draggingId != null) {
                    reorderByDrop(draggingId, idx);
                  }
                  setDraggingId(null);
                  setHoverIdx(null);
                }}
                className={
                  "flex flex-wrap items-center gap-2 rounded border bg-neutral-900/40 p-2 " +
                  (isHovered
                    ? "border-blue-600 bg-blue-950/30"
                    : "border-neutral-800") +
                  (isDragging ? " opacity-50" : "")
                }
              >
                <span
                  draggable={canEdit}
                  onDragStart={(e) => {
                    if (!canEdit) {
                      e.preventDefault();
                      return;
                    }
                    setDraggingId(bucket.id);
                    e.dataTransfer.effectAllowed = "move";
                    // Required for Firefox to start the drag.
                    e.dataTransfer.setData("text/plain", bucket.id);
                  }}
                  onDragEnd={() => {
                    setDraggingId(null);
                    setHoverIdx(null);
                  }}
                  className={
                    "select-none px-1 text-neutral-500 " +
                    (canEdit
                      ? "cursor-grab active:cursor-grabbing hover:text-neutral-300"
                      : "cursor-not-allowed opacity-40")
                  }
                  title="Drag to reorder"
                  aria-label="Drag handle"
                >
                  ⋮⋮
                </span>
                <ColorSwatchPicker
                  color={bucket.colorHex}
                  onChange={(c) => recolorBucket(bucket.id, c)}
                  disabled={!canEdit}
                />
                <input
                  type="text"
                  defaultValue={bucket.name}
                  onBlur={(e) => {
                    if (e.target.value !== bucket.name) {
                      renameBucket(bucket.id, e.target.value);
                    }
                  }}
                  disabled={!canEdit}
                  className="flex-1 rounded border border-transparent bg-transparent px-1 text-sm text-neutral-100 focus:border-neutral-700 focus:bg-neutral-950 disabled:opacity-60"
                />
                <span className="text-xs text-neutral-500">
                  {count} photo{count === 1 ? "" : "s"}
                </span>
                <div className="flex items-center gap-1">
                  <button
                    type="button"
                    onClick={() => move(bucket.id, "up")}
                    disabled={!canEdit || idx === 0}
                    className="rounded border border-neutral-700 px-1.5 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-30"
                    title="Move up"
                    aria-label="Move bucket up"
                  >
                    ↑
                  </button>
                  <button
                    type="button"
                    onClick={() => move(bucket.id, "down")}
                    disabled={!canEdit || idx === buckets.length - 1}
                    className="rounded border border-neutral-700 px-1.5 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-30"
                    title="Move down"
                    aria-label="Move bucket down"
                  >
                    ↓
                  </button>
                  <button
                    type="button"
                    onClick={() => setConfirmDelete(bucket)}
                    disabled={!canEdit}
                    className="rounded border border-red-700 px-2 py-0.5 text-xs text-red-200 hover:bg-red-950/40 disabled:cursor-not-allowed disabled:opacity-50"
                    title="Delete bucket"
                  >
                    Delete
                  </button>
                </div>
              </li>
            );
          })}
        </ul>
      )}

      <div className="text-xs text-neutral-500">
        Unbucketed: {unbucketed} photo{unbucketed === 1 ? "" : "s"}
      </div>

      {/* Delete confirm */}
      {confirmDelete && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">
              Delete bucket{" "}
              <span className="font-semibold">{confirmDelete.name}</span>?
              {photoCounts.get(confirmDelete.id) ? (
                <span className="ml-1 text-neutral-400">
                  Photos in this bucket ({photoCounts.get(confirmDelete.id)})
                  will become un-bucketed.
                </span>
              ) : null}
            </div>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmDelete(null)}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => deleteBucket(confirmDelete.id)}
                className="rounded border border-red-600 bg-red-700/40 px-4 py-1.5 text-sm text-red-100 hover:bg-red-700/60"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function ColorSwatchPicker({
  color,
  onChange,
  disabled,
}: {
  color: string;
  onChange: (next: string) => void;
  disabled?: boolean;
}) {
  return (
    <div className="flex items-center gap-1">
      {COLOR_PALETTE.map((c) => {
        const selected = c.toLowerCase() === color.toLowerCase();
        return (
          <button
            key={c}
            type="button"
            onClick={() => onChange(c)}
            disabled={disabled}
            aria-label={`Pick color ${c}`}
            className={
              selected
                ? "h-5 w-5 rounded-full border-2 border-white"
                : "h-5 w-5 rounded-full border border-neutral-700 hover:border-neutral-400 disabled:opacity-50"
            }
            style={{ background: c }}
          />
        );
      })}
    </div>
  );
}
