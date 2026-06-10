// Split out of PhotoPreviewPanel.tsx (Build #6.22.1) — the panel had
// grown to 1,614 lines holding four independent sub-features. Each
// file owns one feature plus its private helpers; the panel shell
// imports the exported components. No behavior change.
import { useEffect, useState } from "react";
import type { Photo, Project } from "@forensic/shared";

/**
 * Per-photo editor (Build #5.79.1 — Path P #4/8).
 *
 * Inline editor section inside `PhotoPreviewPanel`, visible only
 * when the parent wired `onPhotoUpdated`. Brings the writable
 * fields iOS's `PhotoTagEditorSheet` exposes to web:
 *
 *   - Caption          (writes `userCaption`)
 *   - Observation      (writes `userObservation`)
 *   - Favorite         (writes `isFavorite`)
 *   - Bucket           (writes `bucketID`; select picker + clear)
 *   - Rotation         (cycles `previewRotation` 0/90/180/270)
 *   - Tags             (chip list with × remove, plus an Add input)
 *
 * Mutations are sent to the parent via `onPhotoUpdated`; the
 * parent persists via the shared manifest hook (one PUT per blur
 * on text fields — text fields debounce locally so we don't
 * thrash the server while the user is typing).
 */
export function PhotoEditorSection({
  project,
  photo,
  onPhotoUpdated,
}: {
  project: Project;
  photo: Photo;
  onPhotoUpdated: (updated: Photo) => void;
}) {
  const [caption, setCaption] = useState(photo.userCaption ?? "");
  const [observation, setObservation] = useState(photo.userObservation ?? "");
  const [tagInput, setTagInput] = useState("");

  // Reset local text state when the selected photo changes (the
  // panel re-uses one mount across nav). Otherwise typing in #5 and
  // jumping to #6 would carry the draft over.
  useEffect(() => {
    setCaption(photo.userCaption ?? "");
    setObservation(photo.userObservation ?? "");
    setTagInput("");
  }, [photo.id, photo.userCaption, photo.userObservation]);

  function commitCaption() {
    const next = caption.trim();
    const cur = photo.userCaption ?? "";
    if (next === cur.trim()) return;
    onPhotoUpdated({ ...photo, userCaption: next === "" ? null : next });
  }
  function commitObservation() {
    const next = observation.trim();
    const cur = photo.userObservation ?? "";
    if (next === cur.trim()) return;
    onPhotoUpdated({ ...photo, userObservation: next === "" ? null : next });
  }

  function toggleFavorite() {
    onPhotoUpdated({ ...photo, isFavorite: !photo.isFavorite });
  }
  function setBucket(id: string) {
    onPhotoUpdated({ ...photo, bucketID: id === "" ? null : id });
  }
  function cycleRotation() {
    const next = ((photo.previewRotation + 90) % 360) as Photo["previewRotation"];
    onPhotoUpdated({ ...photo, previewRotation: next });
  }
  function removeTag(idx: number) {
    const next = photo.tags.filter((_, i) => i !== idx);
    onPhotoUpdated({ ...photo, tags: next });
  }
  function addTag() {
    const label = tagInput.trim();
    if (label.length === 0) return;
    // Don't add if already present (case-insensitive on label +
    // parentTag pair, where new tags default to no parent).
    const exists = photo.tags.some(
      (t) => t.label.toLowerCase() === label.toLowerCase() && t.parentTag == null
    );
    if (exists) {
      setTagInput("");
      return;
    }
    onPhotoUpdated({
      ...photo,
      tags: [...photo.tags, { label, confidence: 1, parentTag: null }],
    });
    setTagInput("");
  }

  return (
    <div className="mt-2 flex flex-col gap-2 rounded border border-neutral-800 bg-neutral-900/40 p-2">
      <div className="flex items-center justify-between">
        <span className="text-[10px] uppercase tracking-wide text-neutral-500">
          Edit photo
        </span>
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={toggleFavorite}
            className={
              photo.isFavorite
                ? "rounded p-1 text-amber-300 hover:bg-amber-950/40"
                : "rounded p-1 text-neutral-500 hover:bg-neutral-800 hover:text-neutral-200"
            }
            title={photo.isFavorite ? "Unfavorite" : "Favorite"}
            aria-label={photo.isFavorite ? "Unfavorite" : "Favorite"}
          >
            {photo.isFavorite ? "★" : "☆"}
          </button>
          <button
            type="button"
            onClick={cycleRotation}
            className="rounded border border-neutral-700 px-2 py-0.5 text-[11px] text-neutral-300 hover:bg-neutral-800"
            title="Cycle preview rotation"
          >
            ↻ {photo.previewRotation}°
          </button>
        </div>
      </div>

      <label className="flex flex-col gap-1 text-[11px] text-neutral-400">
        Caption
        <input
          type="text"
          value={caption}
          onChange={(e) => setCaption(e.target.value)}
          onBlur={commitCaption}
          placeholder="(no caption)"
          className="rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-600"
        />
      </label>

      <label className="flex flex-col gap-1 text-[11px] text-neutral-400">
        Observation
        <textarea
          value={observation}
          onChange={(e) => setObservation(e.target.value)}
          onBlur={commitObservation}
          rows={2}
          placeholder="(no observation)"
          className="rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-600"
        />
      </label>

      <label className="flex items-center gap-2 text-[11px] text-neutral-400">
        Bucket
        <select
          value={photo.bucketID ?? ""}
          onChange={(e) => setBucket(e.target.value)}
          className="flex-1 rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100"
        >
          <option value="">— None —</option>
          {[...project.buckets]
            .sort((a, b) => a.sortOrder - b.sortOrder)
            .map((b) => (
              <option key={b.id} value={b.id}>
                {b.name}
              </option>
            ))}
        </select>
      </label>

      <div className="flex flex-col gap-1">
        <span className="text-[11px] text-neutral-400">Tags</span>
        <div className="flex flex-wrap gap-1">
          {photo.tags.length === 0 && (
            <span className="text-[11px] text-neutral-500">(no tags)</span>
          )}
          {photo.tags.map((tag, i) => (
            <span
              key={`${tag.label}-${tag.parentTag ?? ""}-${i}`}
              className={
                tag.parentTag == null
                  ? "flex items-center gap-1 rounded border border-blue-700/50 bg-blue-950/40 px-1.5 py-0.5 text-[11px] text-blue-200"
                  : "flex items-center gap-1 rounded border border-neutral-700 px-1.5 py-0.5 text-[11px] text-neutral-300"
              }
              title={
                tag.parentTag
                  ? `${tag.parentTag} → ${tag.label} · ${(tag.confidence * 100).toFixed(0)}%`
                  : `${tag.label} · ${(tag.confidence * 100).toFixed(0)}%`
              }
            >
              {tag.label}
              <button
                type="button"
                onClick={() => removeTag(i)}
                aria-label={`Remove ${tag.label}`}
                className="rounded text-neutral-400 hover:text-red-300"
              >
                ✕
              </button>
            </span>
          ))}
        </div>
        <div className="flex gap-1">
          <input
            type="text"
            value={tagInput}
            onChange={(e) => setTagInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                addTag();
              }
            }}
            placeholder="Add a tag (Enter to add)"
            className="flex-1 rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-xs text-neutral-100 placeholder:text-neutral-600"
          />
          <button
            type="button"
            onClick={addTag}
            disabled={tagInput.trim().length === 0}
            className="rounded border border-neutral-700 px-2 py-1 text-xs text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Add
          </button>
        </div>
      </div>
    </div>
  );
}
