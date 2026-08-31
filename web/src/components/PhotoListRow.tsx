import type { Photo, Project } from "@forensic/shared";
import { PhotoThumbnail } from "./PhotoThumbnail";

/**
 * Rich photo list row (Build #5.77.1 — Path P #2/8).
 *
 * One card per photo, designed to mirror iOS `PhotoRow` field-for-
 * field. Layout: thumbnail at left, info column to the right
 * (sequence number, badges, timestamp, location, bucket, tag
 * chips), action stack at the far right (favorite, tag, locate,
 * overflow).
 *
 * Build #5.79.1 (Path P #4/8) wires the tag-editor and overflow
 * action buttons to `onOpenEditor`, which the parent uses to
 * open the docked `PhotoPreviewPanel` in editor mode. Relocate
 * still routes to a stub (the relocate flow uses the plan canvas;
 * see `FloorPlanTab` for the pin-drag UI).
 */
interface Props {
  projectId: string;
  project: Project;
  photo: Photo;
  url: string | null;
  batchLoading: boolean;
  threshold: number;
  canEdit: boolean;
  /** When true, the row is in select mode: a checkbox appears on
   *  the left, the thumbnail-click triggers selection toggle instead
   *  of opening the lightbox, and the right-side action buttons are
   *  hidden so the action bar at the top owns the verbs. */
  selectMode: boolean;
  selected: boolean;
  onOpen: () => void;
  onOpenEditor: () => void;
  onToggleFavorite: () => void;
  onToggleSelected: () => void;
  onThumbnailError: () => void;
}

const ROTATIONS_LABEL: Record<number, string> = {
  0: "",
  90: "↻ 90°",
  180: "↻ 180°",
  270: "↻ 270°",
};

function formatTimestamp(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const date = d.toLocaleDateString(undefined, {
    month: "2-digit",
    day: "2-digit",
    year: "2-digit",
  });
  const time = d.toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
  return `${date} @ ${time}`;
}

export function PhotoListRow({
  projectId,
  project,
  photo,
  url,
  batchLoading,
  threshold,
  canEdit,
  selectMode,
  selected,
  onOpen,
  onOpenEditor,
  onToggleFavorite,
  onToggleSelected,
  onThumbnailError,
}: Props) {
  // Resolve floor-plan label for the "location" line. iOS treats
  // a photo as "located" when it has a plan AND pixel coordinates;
  // the `positionSource` is informational (gps vs manual vs none).
  const planLabel = photo.floorPlanID
    ? project.floorPlans.find((p) => p.id === photo.floorPlanID)?.label ?? null
    : null;
  const isPlaced = photo.planPixelX != null && photo.planPixelY != null;
  const locationText = !photo.floorPlanID
    ? "No level"
    : isPlaced
      ? planLabel ?? "Unknown plan"
      : `${planLabel ?? "Unknown plan"} · not placed`;

  // Bucket badge (color dot + name).
  const bucket = photo.bucketID
    ? project.buckets.find((b) => b.id === photo.bucketID)
    : null;

  // Tag chips above the confidence threshold, primaries-first.
  const visibleTags = [...photo.tags]
    .filter((t) => t.confidence >= threshold)
    .sort((a, b) => {
      const ap = a.parentTag == null ? 0 : 1;
      const bp = b.parentTag == null ? 0 : 1;
      return ap - bp || a.label.localeCompare(b.label);
    });

  const pendingCount = photo.pendingSuggestions.filter(
    (s) => s.source === "claude"
  ).length;

  const needsReview =
    photo.aiAnalysis != null &&
    (photo.aiAnalysis.reviewerFlag.trim().length > 0 ||
      photo.aiAnalysis.parseFailed ||
      photo.aiAnalysis.validationErrors.length > 0);

  const hasMeasurement =
    photo.aiAnalysis != null && photo.aiAnalysis.measurementVisible != null;

  const inGroup = photo.groupID != null;

  const thumbClickHandler = selectMode ? onToggleSelected : onOpen;
  return (
    <article
      className={
        selected
          ? "flex gap-3 rounded border border-blue-500 bg-blue-950/40 p-2 transition"
          : "flex gap-3 rounded border border-neutral-800 bg-neutral-900/40 p-2 transition hover:border-neutral-700"
      }
      data-photo-id={photo.id}
    >
      {selectMode && (
        <label className="flex shrink-0 items-start pt-1">
          <input
            type="checkbox"
            checked={selected}
            onChange={onToggleSelected}
            aria-label={`Select photo ${photo.sequenceNumber}`}
            className="h-4 w-4 cursor-pointer"
          />
        </label>
      )}
      <div
        role="button"
        tabIndex={0}
        onClick={thumbClickHandler}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            thumbClickHandler();
          }
        }}
        className="relative block shrink-0 overflow-hidden rounded border border-neutral-800 bg-neutral-950"
        style={{ width: 144, height: 108 }}
        aria-label={
          selectMode
            ? `Toggle selection for photo ${photo.sequenceNumber}`
            : `Open photo ${photo.sequenceNumber}`
        }
      >
        <PhotoThumbnail
          projectId={projectId}
          photoId={photo.id}
          url={url}
          batchLoading={batchLoading}
          alt={photo.userCaption ?? `Photo ${photo.sequenceNumber}`}
          onClick={undefined}
          onError={onThumbnailError}
        />
        {photo.previewRotation !== 0 && (
          <span className="absolute left-1 top-1 rounded bg-black/60 px-1.5 py-0.5 text-[10px] font-medium text-amber-200">
            {ROTATIONS_LABEL[photo.previewRotation] ?? `↻ ${photo.previewRotation}°`}
          </span>
        )}
      </div>

      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <header className="flex flex-wrap items-baseline gap-2">
          <span className="font-mono text-base font-semibold text-neutral-100">
            #{photo.sequenceNumber}
          </span>
          {inGroup && (
            <span
              className="rounded border border-neutral-700 px-1.5 text-[10px] uppercase tracking-wide text-neutral-300"
              title={photo.isPrimary ? "Primary of group" : "Member of group"}
            >
              {photo.isPrimary ? "▣ Group" : "▢ Group"}
            </span>
          )}
          {pendingCount > 0 && (
            <span
              className="rounded bg-blue-950/60 px-1.5 text-[10px] font-medium text-blue-200"
              title="Pending AI tag suggestions"
            >
              AI {pendingCount}
            </span>
          )}
          {needsReview && (
            <span
              className="rounded bg-amber-950/60 px-1.5 text-[10px] font-medium text-amber-200"
              title="Needs review (low confidence, parse failure, or validation issues)"
            >
              Review
            </span>
          )}
          {hasMeasurement && (
            <span
              className="rounded bg-emerald-950/60 px-1.5 text-[10px] font-medium text-emerald-200"
              title={`Measurement visible: ${photo.aiAnalysis?.measurementVisible}`}
            >
              📏 Measurement
            </span>
          )}
        </header>

        <div className="text-xs text-neutral-400">
          {formatTimestamp(photo.timestamp)}
        </div>
        <div className="text-xs text-neutral-300">📍 {locationText}</div>

        {bucket && (
          <div className="flex items-center gap-1.5 text-xs text-neutral-300">
            <span
              className="inline-block h-2.5 w-2.5 rounded-full"
              style={{ background: bucket.colorHex }}
            />
            {bucket.name}
          </div>
        )}

        {(photo.userCaption ?? photo.aiAnalysis?.captionDraft) && (
          <div
            className="line-clamp-2 text-xs text-neutral-400"
            title={photo.userCaption ?? photo.aiAnalysis?.captionDraft ?? ""}
          >
            {photo.userCaption ?? photo.aiAnalysis?.captionDraft}
          </div>
        )}

        {visibleTags.length > 0 && (
          <div className="mt-0.5 flex flex-wrap gap-1">
            {visibleTags.slice(0, 6).map((tag, i) => (
              <span
                key={`${tag.label}-${i}`}
                className={
                  tag.parentTag == null
                    ? "rounded border border-blue-700/50 bg-blue-950/40 px-1.5 py-0.5 text-[10px] text-blue-200"
                    : "rounded border border-neutral-700 px-1.5 py-0.5 text-[10px] text-neutral-300"
                }
                title={
                  tag.parentTag
                    ? `${tag.parentTag} → ${tag.label} · ${(tag.confidence * 100).toFixed(0)}%`
                    : `${tag.label} · ${(tag.confidence * 100).toFixed(0)}%`
                }
              >
                {tag.label}
              </span>
            ))}
            {visibleTags.length > 6 && (
              <span className="px-1 py-0.5 text-[10px] text-neutral-500">
                +{visibleTags.length - 6} more
              </span>
            )}
          </div>
        )}
      </div>

      {!selectMode && (
      <div className="flex shrink-0 flex-col items-end gap-1">
        <button
          type="button"
          onClick={onToggleFavorite}
          disabled={!canEdit}
          className={
            photo.isFavorite
              ? "rounded p-1 text-amber-300 hover:bg-amber-950/40 disabled:opacity-60"
              : "rounded p-1 text-neutral-500 hover:bg-neutral-800 hover:text-neutral-200 disabled:opacity-60 disabled:hover:bg-transparent"
          }
          title={
            !canEdit
              ? "Take the edit lock to favorite"
              : photo.isFavorite
                ? "Unfavorite"
                : "Favorite"
          }
          aria-label={photo.isFavorite ? "Unfavorite" : "Favorite"}
        >
          {photo.isFavorite ? "★" : "☆"}
        </button>
        <button
          type="button"
          onClick={onOpenEditor}
          className="rounded p-1 text-neutral-400 hover:bg-neutral-800 hover:text-neutral-100"
          title="Edit tags, caption, observation, bucket, rotation"
          aria-label="Edit photo"
        >
          🏷
        </button>
        <button
          type="button"
          onClick={onOpenEditor}
          className="rounded p-1 text-neutral-400 hover:bg-neutral-800 hover:text-neutral-100"
          title="Open editor (placement is on the Floor Plan tab)"
          aria-label="Relocate"
        >
          📍
        </button>
        <button
          type="button"
          onClick={onOpenEditor}
          className="rounded p-1 text-neutral-400 hover:bg-neutral-800 hover:text-neutral-100"
          title="More: open the photo editor"
          aria-label="More"
        >
          ⋯
        </button>
      </div>
      )}
    </article>
  );
}
