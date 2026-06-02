import { useEffect, useMemo, useRef, useState } from "react";
import type { Photo } from "@forensic/shared";
import { api, ApiError } from "../lib/api";

/**
 * Side / bottom docked photo preview panel. Replaces the centered
 * `PhotoLightbox` modal on the floor-plan page so engineers can keep
 * the plan in view while reviewing photos at a location (Build
 * #5.27.1). Mirrors the iOS `PhotoPreviewBar` from `PlanViewerView`,
 * including the `Group / All` nav-mode toggle.
 *
 * Layout:
 * - Viewport width ≥ 1024px → docked to the RIGHT side, full height,
 *   ~45vw wide (so the plan still has ~55% of the screen). On a
 *   typical office monitor this beats a bottom dock that wastes the
 *   horizontal real estate.
 * - Otherwise → docked to the BOTTOM, full width, ~55vh tall. Same
 *   shape iOS uses.
 *
 * Navigation:
 * - Arrow keys / on-screen prev/next buttons step through the
 *   currently-active scope.
 * - The scope toggle ("This group" / "All on plan") controls what
 *   the buttons iterate over. If the current photo has no iOS
 *   group, the toggle only offers "All on plan".
 * - Esc / clicking the close button dismisses.
 *
 * Photo URL fetching mirrors the old PhotoLightbox: caches per-photo
 * presigned URLs in a session-local Map keyed by photo ID, and
 * preloads the immediate neighbours so paging is instant.
 */

interface Props {
  projectId: string;
  /** All photos on the active plan (= `photoIdsOnPlan` superset). */
  photos: Photo[];
  /** Initially-selected photo, as an index into `photos`. */
  startIndex: number;
  /**
   * IDs of photos in the currently-clicked cluster / group. When
   * provided, the "This group" tab limits navigation to this set.
   * When omitted (or length 1) the toggle hides and nav defaults to
   * the full `photos` list.
   */
  scopedPhotoIds?: string[];
  onClose: () => void;
}

const PRELOAD_RADIUS = 2;
const SIDE_BREAKPOINT_PX = 1024;

type NavScope = "group" | "all";

export function PhotoPreviewPanel({
  projectId,
  photos,
  startIndex,
  scopedPhotoIds,
  onClose,
}: Props) {
  const [index, setIndex] = useState(startIndex);
  // Default nav scope: if a real group/cluster was passed in, start
  // in "group" mode (iOS default); otherwise "all".
  const initialScope: NavScope =
    scopedPhotoIds && scopedPhotoIds.length > 1 ? "group" : "all";
  const [navScope, setNavScope] = useState<NavScope>(initialScope);
  const [url, setUrl] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  // Responsive dock: re-check on resize so a window drag flips the
  // layout immediately.
  const [isWide, setIsWide] = useState(() =>
    typeof window === "undefined"
      ? true
      : window.innerWidth >= SIDE_BREAKPOINT_PX
  );
  useEffect(() => {
    function onResize() {
      setIsWide(window.innerWidth >= SIDE_BREAKPOINT_PX);
    }
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  // Build the navigation set based on the current scope. The set is
  // an array of indices into `photos` — we navigate by index so the
  // `setIndex` calls stay simple.
  const navIndices = useMemo<number[]>(() => {
    if (navScope === "group" && scopedPhotoIds && scopedPhotoIds.length > 1) {
      const ids = new Set(scopedPhotoIds);
      return photos
        .map((p, i) => (ids.has(p.id) ? i : -1))
        .filter((i) => i >= 0);
    }
    return photos.map((_, i) => i);
  }, [navScope, scopedPhotoIds, photos]);

  // Position of the current index within the scoped nav set. -1 if
  // somehow not in scope (shouldn't happen but handle gracefully —
  // the panel will still render the photo, just without nav arrows).
  const navPos = navIndices.indexOf(index);
  const navTotal = navIndices.length;

  // Session cache of presigned URLs keyed by photo id. Same shape as
  // PhotoLightbox used to use — TTLs are 5 min, acceptable for a
  // single preview session.
  const urlCacheRef = useRef<Map<string, string>>(new Map());
  const preloadedRef = useRef<Set<string>>(new Set());

  const photo = photos[index];

  // Fetch (or read cached) presigned URL for the active photo. Cancel
  // an in-flight older fetch if the user pages quickly.
  useEffect(() => {
    if (!photo) return;
    let cancelled = false;
    setLoadError(null);
    setPending(false);

    const cached = urlCacheRef.current.get(photo.id);
    if (cached) {
      setUrl(cached);
    } else {
      setUrl(null);
      api
        .getPhotoImageUrl(projectId, photo.id)
        .then((res) => {
          if (cancelled) return;
          urlCacheRef.current.set(photo.id, res.url);
          setUrl(res.url);
        })
        .catch((e: unknown) => {
          if (cancelled) return;
          if (e instanceof ApiError && e.status === 404) {
            setPending(true);
          } else if (e instanceof ApiError) {
            setLoadError(`${e.status} ${e.message}`);
          } else {
            setLoadError("Failed to load image");
          }
        });
    }
    return () => {
      cancelled = true;
    };
  }, [projectId, photo]);

  // Preload the navigation neighbours so paging is instant.
  useEffect(() => {
    if (navIndices.length <= 1 || navPos < 0) return;
    let cancelled = false;
    for (let delta = -PRELOAD_RADIUS; delta <= PRELOAD_RADIUS; delta++) {
      if (delta === 0) continue;
      const p =
        (navPos + delta + navIndices.length) % navIndices.length;
      const neighbourIdx = navIndices[p];
      if (neighbourIdx == null) continue;
      const neighbour = photos[neighbourIdx];
      if (!neighbour) continue;

      const warm = (imageUrl: string) => {
        if (cancelled || preloadedRef.current.has(neighbour.id)) return;
        preloadedRef.current.add(neighbour.id);
        const pre = new window.Image();
        pre.src = imageUrl;
      };

      const cached = urlCacheRef.current.get(neighbour.id);
      if (cached) {
        warm(cached);
      } else {
        api
          .getPhotoImageUrl(projectId, neighbour.id)
          .then((res) => {
            if (cancelled) return;
            urlCacheRef.current.set(neighbour.id, res.url);
            warm(res.url);
          })
          .catch(() => {
            /* silent — real fetch path will surface it on navigation */
          });
      }
    }
    return () => {
      cancelled = true;
    };
  }, [projectId, photos, navIndices, navPos]);

  // Keyboard nav. Mounted once; reads stable closures via refs so
  // there's no thrash on every index change.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
      else if (e.key === "ArrowLeft") prev();
      else if (e.key === "ArrowRight") next();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [navIndices, navPos]);

  function prev() {
    if (navTotal === 0) return;
    const pos = navPos >= 0 ? navPos : 0;
    const newPos = (pos - 1 + navTotal) % navTotal;
    const newIdx = navIndices[newPos];
    if (newIdx != null) setIndex(newIdx);
  }
  function next() {
    if (navTotal === 0) return;
    const pos = navPos >= 0 ? navPos : 0;
    const newPos = (pos + 1) % navTotal;
    const newIdx = navIndices[newPos];
    if (newIdx != null) setIndex(newIdx);
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

  // Scope toggle is meaningful only when we actually have a sub-scope
  // distinct from "all".
  const scopeToggleAvailable =
    scopedPhotoIds != null && scopedPhotoIds.length > 1;

  const dockClass = isWide
    ? // Right side: full height, ~45vw wide, scrolls if content overflows.
      "fixed right-0 top-0 bottom-0 z-50 flex w-[45vw] max-w-[640px] min-w-[360px] flex-col border-l border-neutral-800 bg-neutral-950 shadow-2xl"
    : // Bottom: full width, ~55vh tall.
      "fixed left-0 right-0 bottom-0 z-50 flex h-[55vh] flex-col border-t border-neutral-800 bg-neutral-950 shadow-2xl";

  return (
    <div role="dialog" aria-modal="false" aria-label="Photo preview" className={dockClass}>
      {/* Header — counter / caption / close. */}
      <div className="flex items-center justify-between gap-2 border-b border-neutral-800 px-4 py-2">
        <div className="flex items-center gap-3 text-xs text-neutral-400">
          <span className="font-mono text-neutral-200">
            #{photo.sequenceNumber}
          </span>
          {navTotal > 1 && (
            <span>
              {navPos >= 0 ? navPos + 1 : "?"} / {navTotal}
            </span>
          )}
          {scopeToggleAvailable && (
            <div className="flex overflow-hidden rounded border border-neutral-700">
              <button
                type="button"
                onClick={() => setNavScope("group")}
                className={
                  navScope === "group"
                    ? "bg-neutral-700 px-2 py-0.5 text-neutral-100"
                    : "px-2 py-0.5 text-neutral-400 hover:bg-neutral-800"
                }
                title="Page only within this group / location"
              >
                Group
              </button>
              <button
                type="button"
                onClick={() => setNavScope("all")}
                className={
                  navScope === "all"
                    ? "bg-neutral-700 px-2 py-0.5 text-neutral-100"
                    : "px-2 py-0.5 text-neutral-400 hover:bg-neutral-800"
                }
                title="Page through all photos on this plan"
              >
                All on plan
              </button>
            </div>
          )}
        </div>
        <button
          type="button"
          onClick={onClose}
          aria-label="Close photo preview"
          className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800"
        >
          Close ✕
        </button>
      </div>

      {/* Image area. flex-1 + overflow so the metadata footer always
          stays visible regardless of image aspect. */}
      <div className="relative flex flex-1 items-center justify-center overflow-hidden bg-black">
        {pending && (
          <div className="flex flex-col items-center justify-center gap-2 px-6 text-center text-sm text-neutral-400">
            <span className="text-2xl">⏳</span>
            <span>This photo hasn't finished uploading from the iPhone yet.</span>
            <span className="text-xs text-neutral-500">
              It'll appear once the device syncs it.
            </span>
          </div>
        )}
        {loadError && (
          <div className="rounded border border-red-800 bg-red-950/40 p-4 text-sm text-red-300">
            {loadError}
          </div>
        )}
        {!url && !loadError && !pending && (
          <div className="text-sm text-neutral-500">Loading…</div>
        )}
        {url && (
          <img
            src={url}
            alt={caption}
            className="max-h-full max-w-full object-contain"
          />
        )}

        {/* Prev / next buttons — overlay on the image area so they
            don't crowd the metadata footer at narrow widths. */}
        {navTotal > 1 && (
          <>
            <button
              type="button"
              aria-label="Previous photo"
              onClick={prev}
              className="absolute left-2 top-1/2 -translate-y-1/2 rounded bg-neutral-900/80 px-3 py-2 text-lg text-neutral-100 hover:bg-neutral-800"
            >
              ‹
            </button>
            <button
              type="button"
              aria-label="Next photo"
              onClick={next}
              className="absolute right-2 top-1/2 -translate-y-1/2 rounded bg-neutral-900/80 px-3 py-2 text-lg text-neutral-100 hover:bg-neutral-800"
            >
              ›
            </button>
          </>
        )}
      </div>

      {/* Metadata footer. */}
      <div className="flex flex-col gap-1 border-t border-neutral-800 px-4 py-3 text-sm">
        <div className="font-medium text-neutral-100">{caption}</div>
        {observation && (
          <div className="text-neutral-300">{observation}</div>
        )}
        <div className="font-mono text-xs text-neutral-500">{takenAt}</div>
      </div>
    </div>
  );
}
