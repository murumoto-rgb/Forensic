import { useEffect, useState } from "react";
import type { Photo } from "@forensic/shared";
import { api, ApiError } from "../lib/api";

/**
 * Modal full-size photo viewer. Click thumbnail in PhotoGrid → this
 * opens at the selected index. Keyboard nav: Esc to close, ← / → to
 * paginate. Fetches a presigned image URL for whichever photo is
 * currently visible; switches as the user navigates.
 *
 * Caption falls back through the same chain as iOS:
 *   userCaption → aiAnalysis.captionDraft → photo number
 * Same for the observation line.
 *
 * Backdrop click closes; the inner card stops propagation so clicking
 * the photo or text doesn't dismiss.
 */
interface Props {
  projectId: string;
  photos: Photo[];
  startIndex: number;
  onClose: () => void;
}

export function PhotoLightbox({ projectId, photos, startIndex, onClose }: Props) {
  const [index, setIndex] = useState(startIndex);
  const [url, setUrl] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  const photo = photos[index];

  // Fetch presigned URL whenever the active photo changes. Cancel the
  // previous request via the captured `cancelled` flag so an in-flight
  // older fetch can't overwrite the newer one if the user is paging
  // quickly.
  useEffect(() => {
    if (!photo) return;
    let cancelled = false;
    setUrl(null);
    setLoadError(null);
    setPending(false);
    api
      .getPhotoImageUrl(projectId, photo.id)
      .then((res) => {
        if (!cancelled) setUrl(res.url);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        // 404 = binary not uploaded from the iPhone yet (often still
        // in iCloud). Transient; show a "pending upload" message
        // rather than an error code.
        if (e instanceof ApiError && e.status === 404) {
          setPending(true);
        } else if (e instanceof ApiError) {
          setLoadError(`${e.status} ${e.message}`);
        } else {
          setLoadError("Failed to load image");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, photo]);

  // Esc / ← / → key handling.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
      else if (e.key === "ArrowLeft") prev();
      else if (e.key === "ArrowRight") next();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [photos.length, index]);

  function prev() {
    setIndex((i) => (i - 1 + photos.length) % photos.length);
  }
  function next() {
    setIndex((i) => (i + 1) % photos.length);
  }

  if (!photo) return null;

  const caption =
    photo.userCaption?.trim() ||
    photo.aiAnalysis?.captionDraft?.trim() ||
    `Photo ${photo.sequenceNumber}`;
  const observation =
    photo.userObservation?.trim() ||
    photo.aiAnalysis?.summaryObservation?.trim() ||
    "";
  const takenAt = new Date(photo.timestamp).toLocaleString();

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Photo viewer"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/85 p-4"
      onClick={onClose}
    >
      {/* Top bar — counter + close */}
      <button
        type="button"
        aria-label="Close photo viewer"
        onClick={onClose}
        className="absolute right-4 top-4 rounded bg-neutral-900/80 px-3 py-1 text-sm text-neutral-100 hover:bg-neutral-800"
      >
        Close ✕
      </button>
      <div className="absolute left-4 top-4 rounded bg-neutral-900/80 px-3 py-1 text-sm text-neutral-100">
        {index + 1} / {photos.length}
      </div>

      {/* Prev / next */}
      {photos.length > 1 && (
        <>
          <button
            type="button"
            aria-label="Previous photo"
            onClick={(e) => {
              e.stopPropagation();
              prev();
            }}
            className="absolute left-2 top-1/2 -translate-y-1/2 rounded bg-neutral-900/80 px-3 py-2 text-lg text-neutral-100 hover:bg-neutral-800"
          >
            ‹
          </button>
          <button
            type="button"
            aria-label="Next photo"
            onClick={(e) => {
              e.stopPropagation();
              next();
            }}
            className="absolute right-2 top-1/2 -translate-y-1/2 rounded bg-neutral-900/80 px-3 py-2 text-lg text-neutral-100 hover:bg-neutral-800"
          >
            ›
          </button>
        </>
      )}

      {/* Inner card */}
      <div
        onClick={(e) => e.stopPropagation()}
        className="flex max-h-full max-w-5xl flex-col gap-4 rounded-lg border border-neutral-800 bg-neutral-950 p-4 shadow-2xl"
      >
        <div className="flex items-center justify-center">
          {pending && (
            <div className="flex h-96 w-full flex-col items-center justify-center gap-2 rounded border border-neutral-800 bg-neutral-900 text-center text-sm text-neutral-400">
              <span className="text-2xl">⏳</span>
              <span>This photo hasn't finished uploading from the iPhone yet.</span>
              <span className="text-xs text-neutral-500">
                It'll appear once the device syncs it.
              </span>
            </div>
          )}
          {loadError && (
            <div className="rounded border border-red-800 bg-red-950/40 p-6 text-sm text-red-300">
              {loadError}
            </div>
          )}
          {!url && !loadError && !pending && (
            <div className="flex h-96 w-full animate-pulse items-center justify-center rounded border border-neutral-800 bg-neutral-900 text-neutral-500">
              Loading…
            </div>
          )}
          {url && (
            <img
              src={url}
              alt={caption}
              className="max-h-[75vh] w-auto rounded object-contain"
            />
          )}
        </div>

        <div className="flex flex-col gap-1 px-2 pb-2 text-sm">
          <div className="font-medium text-neutral-100">{caption}</div>
          {observation && (
            <div className="text-neutral-300">{observation}</div>
          )}
          <div className="font-mono text-xs text-neutral-500">{takenAt}</div>
        </div>
      </div>
    </div>
  );
}
