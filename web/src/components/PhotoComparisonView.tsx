import { useEffect, useState } from "react";
import type { Photo } from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { useEscapeKey } from "../lib/useEscapeKey";

/**
 * Before/after comparison carousel for grouped photos (Build #5.102.1).
 *
 * Mirrors iOS's `PhotoComparisonView.swift` — walks the
 * `reshootsPhotoID` chain to assemble the group's photos in order
 * (primary first, reshoots after), renders them side-by-side or
 * one-at-a-time on narrow viewports.
 *
 * Reachable from `PhotoPreviewPanel`'s header when the focused
 * photo has a non-null `groupID` and the group has >1 members.
 */
interface Props {
  projectId: string;
  /** All photos in the project — comparison walks the group. */
  photos: readonly Photo[];
  /** The photo the user clicked Compare from. Used to locate the group. */
  selectedPhoto: Photo;
  onClose: () => void;
}

export function PhotoComparisonView({
  projectId,
  photos,
  selectedPhoto,
  onClose,
}: Props) {
  // Build #6.17.1: Escape closes the comparison modal.
  useEscapeKey(true, onClose);
  // Walk the group. Primary first, then reshoots ordered by their
  // sequenceNumber (matches iOS).
  const groupMembers = resolveGroup(photos, selectedPhoto);
  const [activeIdx, setActiveIdx] = useState(() =>
    Math.max(
      0,
      groupMembers.findIndex((p) => p.id === selectedPhoto.id)
    )
  );

  return (
    <div
      role="dialog"
      aria-modal="true"
      className="fixed inset-0 z-50 flex flex-col bg-black/85 p-4"
    >
      <header className="mb-3 flex items-center justify-between text-sm text-neutral-200">
        <div>
          <div className="font-semibold">
            Group of {groupMembers.length} photo
            {groupMembers.length === 1 ? "" : "s"}
          </div>
          <div className="text-xs text-neutral-500">
            Primary first; reshoots follow in capture order.
          </div>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-200 hover:bg-neutral-800"
        >
          Close
        </button>
      </header>

      <div className="mb-2 flex flex-wrap items-center gap-2 text-xs text-neutral-300">
        {groupMembers.map((p, i) => (
          <button
            key={p.id}
            type="button"
            onClick={() => setActiveIdx(i)}
            className={
              i === activeIdx
                ? "rounded border border-blue-500 bg-blue-950/40 px-2 py-1 text-blue-100"
                : "rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800"
            }
          >
            #{p.sequenceNumber}
            {p.isPrimary && (
              <span className="ml-1 text-[10px] uppercase text-blue-300">
                primary
              </span>
            )}
          </button>
        ))}
      </div>

      {/* Two-pane comparison: active photo + next photo (or previous when at the end). */}
      <div className="grid min-h-0 flex-1 grid-cols-1 gap-3 lg:grid-cols-2">
        <ComparisonPane
          projectId={projectId}
          photo={groupMembers[activeIdx] ?? null}
          label="Active"
        />
        <ComparisonPane
          projectId={projectId}
          photo={groupMembers[(activeIdx + 1) % groupMembers.length] ?? null}
          label="Next"
        />
      </div>

      <p className="mt-2 text-[11px] text-neutral-500">
        Click a sequence number above to focus that photo on the
        left. The right pane cycles to the next in the group so you
        can compare any pair.
      </p>
    </div>
  );
}

function ComparisonPane({
  projectId,
  photo,
  label,
}: {
  projectId: string;
  photo: Photo | null;
  label: string;
}) {
  const [url, setUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!photo) {
      setUrl(null);
      return;
    }
    let cancelled = false;
    api
      .getPhotoImageUrl(projectId, photo.id)
      .then((resp) => {
        if (!cancelled) setUrl(resp.url);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setError(
          e instanceof ApiError
            ? `${e.errorCode}: ${e.message}`
            : "Failed to load image"
        );
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, photo]);

  return (
    <div className="flex min-h-0 flex-col rounded border border-neutral-800 bg-neutral-950">
      <div className="border-b border-neutral-800 px-3 py-1 text-xs text-neutral-400">
        {label}
        {photo && (
          <>
            {" — "}
            <span className="text-neutral-200">#{photo.sequenceNumber}</span>
            {photo.userCaption && (
              <span className="ml-2 text-neutral-500">
                — {photo.userCaption}
              </span>
            )}
          </>
        )}
      </div>
      <div className="flex min-h-0 flex-1 items-center justify-center overflow-hidden">
        {error && (
          <div className="text-sm text-red-300">{error}</div>
        )}
        {!error && !url && (
          <div className="text-sm text-neutral-500">Loading…</div>
        )}
        {url && (
          <img
            src={url}
            alt={photo?.userCaption ?? `Photo ${photo?.sequenceNumber}`}
            style={{
              transform: photo
                ? `rotate(${photo.previewRotation}deg)`
                : undefined,
            }}
            className="max-h-full max-w-full object-contain"
          />
        )}
      </div>
    </div>
  );
}

/**
 * Walk the group containing `seed`. Order: primary first (the
 * photo with `isPrimary === true` AND the matching groupID),
 * then non-primary members ordered by their `sequenceNumber`.
 * If `seed.groupID` is null, returns just [seed].
 */
function resolveGroup(
  photos: readonly Photo[],
  seed: Photo
): readonly Photo[] {
  if (!seed.groupID) return [seed];
  const members = photos.filter((p) => p.groupID === seed.groupID);
  const primary = members.find((p) => p.isPrimary);
  const rest = members
    .filter((p) => !p.isPrimary)
    .sort((a, b) => a.sequenceNumber - b.sequenceNumber);
  return primary ? [primary, ...rest] : rest;
}
