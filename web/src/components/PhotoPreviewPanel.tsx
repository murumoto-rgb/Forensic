import { useEffect, useMemo, useRef, useState } from "react";
import type { AITagPhotoModel, Photo, Project } from "@forensic/shared";
import {
  compilePrompt,
  compileUserPrompt,
  parseAIPhotoAnalysis,
  PromptCompileError,
} from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { useTagConfidenceThreshold } from "../lib/useTagConfidenceThreshold";

/**
 * Side / bottom docked photo preview panel.
 *
 * Build #5.28.1 turned this into a CONTROLLED component — the
 * selected photo lives in the parent (`ProjectPlanPage`) so the
 * floor-plan canvas can observe it and recenter the highlighted pin
 * in the visible portion of the canvas (the portion not covered by
 * this panel) on every navigation. The panel itself owns only UI
 * state (nav scope toggle, batch-thumb URL map).
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
 * - The scope toggle ("This group" / "All on plan") controls what
 *   `prev` / `next` and the thumb strip iterate over.
 * - Prev/Next buttons and arrow keys step through the active scope.
 * - Thumb strip (below the header) shows every photo in the active
 *   scope; clicking a thumb jumps directly to that photo. Thumb URLs
 *   come from the batch endpoint (one round trip per scope change).
 * - The panel calls `onSelectPhoto(id)` on every navigation; the
 *   parent's state update re-renders the panel with the new
 *   `selectedPhotoId` AND triggers the canvas's recenter effect.
 *
 * Photo URL fetching mirrors the iOS preview-bar's: a per-session
 * Map cache keyed by photo ID for full-image URLs, plus a more
 * aggressive `PRELOAD_RADIUS = 5` (bumped from 2 in Build #5.28.1)
 * so paging in either direction is instant for a typical click
 * cadence.
 */

interface Props {
  projectId: string;
  /**
   * Full project — needed by the "Re-tag with AI" button to compile
   * the project-scoped vocabulary block (reads `tagSelection`,
   * `aiInstructions`, `aiExtraVocabulary` from the manifest). Same
   * project the parent renders the canvas from; passing the whole
   * struct keeps the panel from needing four narrower props.
   */
  project: Project;
  /** All photos on the active plan. */
  photos: Photo[];
  /** Currently-selected photo id (controlled by parent). */
  selectedPhotoId: string;
  /**
   * IDs of photos in the currently-clicked cluster / group. When
   * provided, the "Group" tab limits navigation to this set.
   * When omitted (or length 1) the toggle hides and nav defaults to
   * the full `photos` list.
   */
  scopedPhotoIds?: string[];
  /** Fires on every navigation (prev/next, arrow key, thumb click). */
  onSelectPhoto: (photoId: string) => void;
  /**
   * Fires when the panel mutates the currently-selected photo (e.g.
   * the "Re-tag with AI" button writes a new `aiAnalysis`). Parent
   * is responsible for splicing the photo into the project and
   * persisting via the manifest PUT endpoint — the panel is
   * controlled, so it doesn't own the project state.
   */
  onPhotoUpdated?: (updated: Photo) => void;
  onClose: () => void;
}

const PRELOAD_RADIUS = 5;
const SIDE_BREAKPOINT_PX = 1024;
const THUMB_PX = 56;

type NavScope = "group" | "all";

export function PhotoPreviewPanel({
  projectId,
  project,
  photos,
  selectedPhotoId,
  scopedPhotoIds,
  onSelectPhoto,
  onPhotoUpdated,
  onClose,
}: Props) {
  // Default nav scope: if a real group/cluster was passed in, start
  // in "group" mode (iOS default); otherwise "all".
  const initialScope: NavScope =
    scopedPhotoIds && scopedPhotoIds.length > 1 ? "group" : "all";
  const [navScope, setNavScope] = useState<NavScope>(initialScope);
  // Reset scope when a different cluster / group is selected (the
  // scoped set changes identity). useEffect with a deps array on
  // scopedPhotoIds.join handles that — the panel doesn't unmount,
  // so we manually reset to the new default.
  const scopedKey = scopedPhotoIds?.join("|") ?? "";
  useEffect(() => {
    setNavScope(
      scopedPhotoIds && scopedPhotoIds.length > 1 ? "group" : "all"
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scopedKey]);

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

  // Navigation set based on current scope. Indices into `photos`.
  const navIndices = useMemo<number[]>(() => {
    if (navScope === "group" && scopedPhotoIds && scopedPhotoIds.length > 1) {
      const ids = new Set(scopedPhotoIds);
      return photos
        .map((p, i) => (ids.has(p.id) ? i : -1))
        .filter((i) => i >= 0);
    }
    return photos.map((_, i) => i);
  }, [navScope, scopedPhotoIds, photos]);

  // Resolve the active photo from selectedPhotoId.
  const index = photos.findIndex((p) => p.id === selectedPhotoId);
  const photo = index >= 0 ? photos[index] : null;
  const navPos = navIndices.indexOf(index);
  const navTotal = navIndices.length;

  // Session cache of presigned image URLs (full-size). Same shape as
  // the old PhotoLightbox.
  const urlCacheRef = useRef<Map<string, string>>(new Map());
  const preloadedRef = useRef<Set<string>>(new Set());

  // Batch-fetched thumb URLs for the active nav scope. One server
  // round trip per scope change; renders the thumb strip below the
  // header without per-thumb fetches.
  const [thumbUrls, setThumbUrls] = useState<Map<string, string>>(new Map());
  // Refresh thumbs whenever the nav set changes (scope toggle, or
  // a brand-new cluster). Stringify the indices for a stable key.
  const navIdsKey = useMemo(
    () => navIndices.map((i) => photos[i]?.id).join(","),
    [navIndices, photos]
  );
  useEffect(() => {
    if (navIndices.length === 0) {
      setThumbUrls(new Map());
      return;
    }
    let cancelled = false;
    const ids = navIndices
      .map((i) => photos[i]?.id)
      .filter((id): id is string => id != null);
    api
      .getPhotoUrlsBatch(projectId, ids, "thumb")
      .then((res) => {
        if (cancelled) return;
        setThumbUrls(new Map(Object.entries(res.urls)));
      })
      .catch(() => {
        // Silent — the thumb strip just stays empty / lazy-loads from
        // the per-photo path if we ever wire it. Not blocking.
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [navIdsKey, projectId]);

  // Fetch (or read cached) full-image presigned URL for the active
  // photo. Cancel in-flight request if the user pages quickly.
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

  // Preload the navigation neighbours so paging is instant. Bumped
  // from ±2 to ±5 in Build #5.28.1.
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
            /* silent — real fetch will surface it on navigation */
          });
      }
    }
    return () => {
      cancelled = true;
    };
  }, [projectId, photos, navIndices, navPos]);

  // Keyboard nav. Reads navIndices + navPos via deps so we step over
  // the up-to-date scope-filtered set.
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

  function navigateBy(delta: number) {
    if (navTotal === 0) return;
    const pos = navPos >= 0 ? navPos : 0;
    const newPos = (pos + delta + navTotal) % navTotal;
    const newIdx = navIndices[newPos];
    if (newIdx == null) return;
    const newPhoto = photos[newIdx];
    if (newPhoto) onSelectPhoto(newPhoto.id);
  }
  const prev = () => navigateBy(-1);
  const next = () => navigateBy(+1);

  // Auto-scroll the thumb strip so the current photo's thumb is
  // visible. Ref to the active thumb element.
  const stripContainerRef = useRef<HTMLDivElement | null>(null);
  const activeThumbRef = useRef<HTMLButtonElement | null>(null);
  useEffect(() => {
    if (activeThumbRef.current) {
      activeThumbRef.current.scrollIntoView({
        behavior: "smooth",
        block: "nearest",
        inline: "center",
      });
    }
  }, [selectedPhotoId, navIdsKey]);

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

  const scopeToggleAvailable =
    scopedPhotoIds != null && scopedPhotoIds.length > 1;

  const dockClass = isWide
    ? "fixed right-0 top-0 bottom-0 z-50 flex w-[45vw] max-w-[640px] min-w-[360px] flex-col border-l border-neutral-800 bg-neutral-950 shadow-2xl"
    : "fixed left-0 right-0 bottom-0 z-50 flex h-[55vh] flex-col border-t border-neutral-800 bg-neutral-950 shadow-2xl";

  return (
    <div
      role="dialog"
      aria-modal="false"
      aria-label="Photo preview"
      data-preview-panel="true"
      data-preview-dock={isWide ? "right" : "bottom"}
      className={dockClass}
    >
      {/* Header — counter / scope toggle / close. */}
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

      {/* Thumb strip — horizontally scrollable, one row of small
          previews of the active nav scope. Click a thumb to jump.
          Auto-scrolls the current photo into view via scrollIntoView.
          Native lazy-loading skips off-screen thumbs until the user
          scrolls them in, which keeps initial render snappy on a
          large "All on plan" scope (could be 100s on a busy site). */}
      {navTotal > 1 && (
        <div
          ref={stripContainerRef}
          className="flex gap-1 overflow-x-auto border-b border-neutral-800 bg-neutral-900/60 px-2 py-2"
        >
          {navIndices.map((idx) => {
            const p = photos[idx];
            if (!p) return null;
            const thumbUrl = thumbUrls.get(p.id);
            const isActive = p.id === selectedPhotoId;
            return (
              <button
                key={p.id}
                ref={isActive ? activeThumbRef : undefined}
                type="button"
                onClick={() => onSelectPhoto(p.id)}
                title={`#${p.sequenceNumber}${p.userCaption ? ` — ${p.userCaption}` : ""}`}
                className={
                  isActive
                    ? "relative flex-shrink-0 overflow-hidden rounded border-2 border-blue-500 bg-neutral-800"
                    : "relative flex-shrink-0 overflow-hidden rounded border-2 border-transparent bg-neutral-800 hover:border-neutral-600"
                }
                style={{ width: THUMB_PX, height: THUMB_PX }}
              >
                {thumbUrl ? (
                  <img
                    src={thumbUrl}
                    alt={`#${p.sequenceNumber}`}
                    loading="lazy"
                    className="h-full w-full object-cover"
                  />
                ) : (
                  <span className="flex h-full w-full items-center justify-center text-[10px] text-neutral-500">
                    #{p.sequenceNumber}
                  </span>
                )}
                <span className="absolute bottom-0 left-0 right-0 bg-black/60 px-0.5 text-center text-[9px] font-mono text-white">
                  #{p.sequenceNumber}
                </span>
              </button>
            );
          })}
        </div>
      )}

      {/* Image area. */}
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

        {/* AI analysis viewer (Build #5.39.1). Surfaces the
            structured fields the model emitted that the panel's
            caption + observation lines don't already cover:
            recommended use, scale presence, transcribed measurement,
            reviewer flag, the tag-tree with per-secondary confidence,
            and any validator errors recorded on iOS. Renders only
            when an aiAnalysis exists on the photo. */}
        {photo.aiAnalysis && <AIAnalysisViewer analysis={photo.aiAnalysis} />}

        {/* Re-tag with AI (Build #5.37.1). Only renders when the
            parent wired up the update callback — keeps view-only
            consumers (e.g. a future read-only embed) honest. */}
        {onPhotoUpdated && (
          <ReTagWithAIControl
            projectId={projectId}
            project={project}
            photo={photo}
            onPhotoUpdated={onPhotoUpdated}
          />
        )}
      </div>
    </div>
  );
}

/**
 * Read-only viewer for a photo's `AIPhotoAnalysis`. Mirrors the
 * fields iOS's `PhotoTagEditorSheet` surfaces — recommended use,
 * scale presence, transcribed measurement, reviewer flag, the
 * tag-tree with per-secondary confidence percentages, and the
 * validator errors iOS may have written on the previous tag run.
 *
 * The caption + observation rows in the panel already surface
 * `captionDraft` + `summaryObservation`, so this viewer
 * intentionally skips those — duplicating them would just make the
 * footer twice as tall.
 *
 * Renders nothing extra when a field is empty / null / the iOS
 * "unknown" sentinel so a sparsely-populated analysis doesn't show
 * a wall of dashes.
 */
function AIAnalysisViewer({
  analysis,
}: {
  analysis: import("@forensic/shared").AIPhotoAnalysis;
}) {
  const hasTags =
    analysis.primaryTags.length > 0 ||
    Object.keys(analysis.secondaryTagsByPrimary).length > 0;
  const hasAnyVisible =
    hasTags ||
    nonTrivialString(analysis.recommendedUse) ||
    nonTrivialString(analysis.scalePresent) ||
    nonTrivialString(analysis.measurementVisible) ||
    nonTrivialString(analysis.locationInferred) ||
    nonTrivialString(analysis.reviewerFlag) ||
    analysis.validationErrors.length > 0 ||
    analysis.parseFailed;

  // An aiAnalysis that's structurally present but every field is
  // empty (e.g. an early parse failure on a model with no usable
  // output) renders as a one-line header rather than nothing — so
  // the user knows the call ran but produced nothing useful.
  if (!hasAnyVisible) {
    return (
      <details className="mt-2 border-t border-neutral-800 pt-2 text-xs">
        <summary className="cursor-pointer text-neutral-400 hover:text-neutral-200">
          AI analysis (empty)
        </summary>
      </details>
    );
  }

  return (
    <details
      className="mt-2 border-t border-neutral-800 pt-2 text-xs"
      open
    >
      <summary className="cursor-pointer text-neutral-300 hover:text-neutral-100">
        AI analysis
        {analysis.parseFailed && (
          <span className="ml-2 rounded bg-amber-900/40 px-1.5 py-0.5 text-[10px] text-amber-300">
            parse failed
          </span>
        )}
      </summary>
      <div className="mt-2 flex flex-col gap-2">
        {nonTrivialString(analysis.recommendedUse) && (
          <AnalysisRow label="Recommended use" value={analysis.recommendedUse} />
        )}
        {nonTrivialString(analysis.scalePresent) && (
          <AnalysisRow label="Scale" value={analysis.scalePresent} />
        )}
        {nonTrivialString(analysis.measurementVisible) && (
          <AnalysisRow
            label="Measurement"
            value={analysis.measurementVisible!}
          />
        )}
        {nonTrivialString(analysis.locationInferred) && (
          <AnalysisRow label="Location" value={analysis.locationInferred} />
        )}
        {nonTrivialString(analysis.reviewerFlag) && (
          <AnalysisRow
            label="Reviewer flag"
            value={analysis.reviewerFlag}
            tone="warning"
          />
        )}
        {hasTags && <AITagTree analysis={analysis} />}
        {analysis.validationErrors.length > 0 && (
          <div className="rounded border border-amber-800 bg-amber-950/40 px-2 py-1 text-amber-200">
            <div className="mb-1 font-semibold text-amber-100">
              Validator issues
            </div>
            <ul className="ml-4 list-disc space-y-0.5">
              {analysis.validationErrors.map((e, i) => (
                <li key={i}>{e}</li>
              ))}
            </ul>
          </div>
        )}
        {analysis.parseFailed && analysis.rawResponse && (
          <details className="mt-1">
            <summary className="cursor-pointer text-neutral-500 hover:text-neutral-300">
              Show raw response
            </summary>
            <pre className="mt-1 max-h-48 overflow-auto rounded border border-neutral-800 bg-neutral-950 p-2 text-[10px] text-neutral-400">
              {analysis.rawResponse}
            </pre>
          </details>
        )}
      </div>
    </details>
  );
}

function AnalysisRow({
  label,
  value,
  tone = "neutral",
}: {
  label: string;
  value: string;
  tone?: "neutral" | "warning";
}) {
  return (
    <div className="flex flex-col">
      <span
        className={
          tone === "warning"
            ? "text-[10px] uppercase tracking-wide text-amber-400"
            : "text-[10px] uppercase tracking-wide text-neutral-500"
        }
      >
        {label}
      </span>
      <span
        className={
          tone === "warning" ? "text-amber-200" : "text-neutral-200"
        }
      >
        {value}
      </span>
    </div>
  );
}

/**
 * Render the analysis's tag tree as a list of primaries, each with
 * its bullet of secondary chips. Per-secondary confidence is read
 * from `tagConfidences` (case-insensitive lookup on the chip's
 * label) and rendered as a small percentage when present.
 *
 * Secondaries below the app-wide confidence threshold (Build
 * #5.40.1; same `sitephoto.tagConfidenceThreshold` key iOS uses)
 * are hidden by default; a small inline slider in the tree header
 * lets the user surface them again. Hidden-count chip shown beside
 * the slider when any secondary was filtered out, mirroring iOS's
 * "8 hidden" affordance.
 */
function AITagTree({
  analysis,
}: {
  analysis: import("@forensic/shared").AIPhotoAnalysis;
}) {
  const [threshold, setThreshold] = useTagConfidenceThreshold();
  // Build a lowercase-keyed confidence lookup once so we don't
  // walk the map per chip.
  const confByLower = new Map<string, number>();
  for (const [k, v] of Object.entries(analysis.tagConfidences)) {
    confByLower.set(k.trim().toLowerCase(), v);
  }

  let hiddenCount = 0;
  // Pre-compute the rendered tree so we can count hidden secondaries
  // before laying out the header.
  const renderedPrimaries = analysis.primaryTags.map((primary) => {
    const trimmedPrimary = primary.trim();
    const matchKey = Object.keys(analysis.secondaryTagsByPrimary).find(
      (k) => k.trim().toLowerCase() === trimmedPrimary.toLowerCase()
    );
    const secondaries =
      (matchKey && analysis.secondaryTagsByPrimary[matchKey]) || [];
    const chips: { label: string; conf: number | undefined }[] = [];
    for (const sec of secondaries) {
      const trimmedSec = sec.trim();
      if (trimmedSec.length === 0 || trimmedSec.toLowerCase() === "none") {
        continue;
      }
      const conf = confByLower.get(trimmedSec.toLowerCase());
      // Filter rule: hide a secondary when its confidence is BELOW
      // the threshold. A secondary with no confidence entry is
      // treated as "kept" — iOS's pipeline assigns the fallback
      // confidence (0.7) when a secondary's tag_confidences entry
      // is missing, which keeps it above the default 50% threshold
      // and matches the visible-by-default behaviour.
      if (conf != null && conf < threshold) {
        hiddenCount += 1;
        continue;
      }
      chips.push({ label: trimmedSec, conf });
    }
    return { trimmedPrimary, chips, key: primary };
  });

  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center justify-between gap-2">
        <span className="text-[10px] uppercase tracking-wide text-neutral-500">
          Tags
        </span>
        <div className="flex items-center gap-2">
          {hiddenCount > 0 && (
            <span
              className="text-[10px] text-neutral-500"
              title={`${hiddenCount} secondary tag${
                hiddenCount === 1 ? "" : "s"
              } hidden below ${Math.round(threshold * 100)}% confidence`}
            >
              {hiddenCount} hidden
            </span>
          )}
          <label
            className="flex items-center gap-1.5 text-[10px] text-neutral-500"
            title="Hide AI tags below this confidence. Stored in localStorage; mirrors iOS Settings → Tag Confidence Filter."
          >
            Min&nbsp;
            <input
              type="range"
              min={0}
              max={1}
              step={0.05}
              value={threshold}
              onChange={(e) =>
                setThreshold(Number.parseFloat(e.currentTarget.value))
              }
              className="h-1 w-20 cursor-pointer accent-blue-500"
              aria-label="Minimum tag confidence"
            />
            <span className="font-mono text-neutral-400">
              {Math.round(threshold * 100)}%
            </span>
          </label>
        </div>
      </div>
      {analysis.primaryTags.length === 0 && (
        <div className="text-neutral-500 italic">
          No primaries — secondaries below carry no parent in the analysis.
        </div>
      )}
      {renderedPrimaries.map(({ trimmedPrimary, chips, key }) => (
        <div key={key} className="flex flex-col gap-1">
          <div className="font-medium text-neutral-200">{trimmedPrimary}</div>
          {chips.length > 0 && (
            <div className="ml-2 flex flex-wrap gap-1">
              {chips.map(({ label, conf }) => (
                <span
                  key={label}
                  className="rounded bg-neutral-800 px-1.5 py-0.5 text-[11px] text-neutral-200"
                >
                  {label}
                  {conf != null && (
                    <span className="ml-1 text-neutral-500">
                      {Math.round(Math.max(0, Math.min(1, conf)) * 100)}%
                    </span>
                  )}
                </span>
              ))}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

/**
 * True when `s` carries useful content. Treats the empty string AND
 * the iOS-side "unknown" sentinel (`scalePresent` / `recommendedUse`
 * are stored as raw strings but iOS represents the "unknown" enum
 * case as a bare `""` on the wire) as falsy so the viewer doesn't
 * show empty rows.
 */
function nonTrivialString(s: string | null | undefined): boolean {
  if (s == null) return false;
  return s.trim().length > 0;
}

/**
 * "Re-tag with AI" button + status banner. Fetches the team's
 * `tagLibrary` + `aiRulesTemplate` from the server, compiles the
 * project-scoped system prompt the same way iOS does (via the
 * shared `compilePrompt`), forwards the photo through the
 * `/v1/ai/tag-photo` proxy, parses the rawText into an
 * `AIPhotoAnalysis`, and hands it back to the parent via
 * `onPhotoUpdated`. The parent persists via the manifest PUT.
 *
 * Scoped as a sibling component (rather than inlined in the panel)
 * so the panel's render path stays small and the local state
 * machine here doesn't bleed into the rest of the file.
 */
function ReTagWithAIControl({
  projectId,
  project,
  photo,
  onPhotoUpdated,
}: {
  projectId: string;
  project: Project;
  photo: Photo;
  onPhotoUpdated: (photo: Photo) => void;
}) {
  type Status =
    | { kind: "idle" }
    | { kind: "running" }
    | { kind: "error"; message: string }
    | { kind: "done"; parseFailed: boolean };
  const [status, setStatus] = useState<Status>({ kind: "idle" });
  const [model, setModel] = useState<AITagPhotoModel>("claude-sonnet-4-6");

  async function runReTag() {
    setStatus({ kind: "running" });
    try {
      // Fetch the two config keys we need to assemble the prompt.
      // Parallel because they're independent.
      const [tagLibResp, rulesResp] = await Promise.all([
        api.getTagLibraryConfig(),
        api.getAIRulesTemplateConfig(),
      ]);
      if (!tagLibResp) {
        setStatus({
          kind: "error",
          message:
            "No tag library on the server yet. Push one from iOS first (Settings → Tag Library → make any edit).",
        });
        return;
      }
      const rulesTemplate = rulesResp?.value.text ?? "";

      const compiled = compilePrompt({
        rulesTemplate,
        tagLibrary: tagLibResp.value,
        project,
      });

      const resp = await api.tagPhoto({
        projectId,
        photoId: photo.id,
        model,
        systemPrompt: compiled.joinedSystemPrompt,
        userText: compileUserPrompt(photo.imageFilename),
      });

      const analysis = parseAIPhotoAnalysis({
        rawText: resp.rawText,
        fallbackPhotoID: photo.imageFilename,
      });
      onPhotoUpdated({ ...photo, aiAnalysis: analysis });
      setStatus({ kind: "done", parseFailed: analysis.parseFailed });
    } catch (e: unknown) {
      if (e instanceof PromptCompileError) {
        setStatus({
          kind: "error",
          message:
            "This project has no AI tag selection yet. Pick contexts on iOS (project → AI Tags) first.",
        });
      } else if (e instanceof ApiError) {
        setStatus({
          kind: "error",
          message: `${e.status} ${e.errorCode}: ${e.message}`,
        });
      } else {
        setStatus({
          kind: "error",
          message:
            e instanceof Error ? e.message : "Re-tag request failed.",
        });
      }
    }
  }

  return (
    <div className="mt-2 flex flex-col gap-2 border-t border-neutral-800 pt-2">
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={runReTag}
          disabled={status.kind === "running"}
          className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1 text-xs font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {status.kind === "running" ? "Tagging…" : "Re-tag with AI"}
        </button>
        <select
          aria-label="AI model"
          value={model}
          onChange={(e) => setModel(e.target.value as AITagPhotoModel)}
          disabled={status.kind === "running"}
          className="rounded border border-neutral-700 bg-neutral-800 px-2 py-1 text-xs text-neutral-200 disabled:opacity-50"
        >
          <option value="claude-sonnet-4-6">Sonnet 4.6</option>
          <option value="claude-haiku-4-5">Haiku 4.5</option>
        </select>
      </div>
      {status.kind === "error" && (
        <div className="rounded border border-red-800 bg-red-950/40 px-2 py-1 text-xs text-red-200">
          {status.message}
        </div>
      )}
      {status.kind === "done" && status.parseFailed && (
        <div className="rounded border border-amber-700 bg-amber-950/40 px-2 py-1 text-xs text-amber-200">
          Model output was unparseable — saved on the photo for review.
        </div>
      )}
      {status.kind === "done" && !status.parseFailed && (
        <div className="rounded border border-emerald-800 bg-emerald-950/40 px-2 py-1 text-xs text-emerald-200">
          Tagged. Save status indicator confirms persistence.
        </div>
      )}
    </div>
  );
}
