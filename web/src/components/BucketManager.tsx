import { useState } from "react";
import type { Bucket, Project } from "@forensic/shared";

/**
 * Bucket CRUD (Build #5.80.1 — Path P #5/8).
 *
 * Per-project bucket management — create (name + color), rename,
 * recolor, reorder, delete (with photo-impact preview). Counts
 * per bucket and the project-wide "unbucketed" count are live
 * against the manifest, not cached.
 *
 * Reorder uses up/down buttons that swap `sortOrder` with the
 * adjacent bucket. Drag-and-drop ships in a follow-on if the
 * user asks for it — the iOS UI has the same buttons.
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
            return (
              <li
                key={bucket.id}
                className="flex flex-wrap items-center gap-2 rounded border border-neutral-800 bg-neutral-900/40 p-2"
              >
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
