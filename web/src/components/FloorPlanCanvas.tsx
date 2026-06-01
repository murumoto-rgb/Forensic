import { useEffect, useRef, useState } from "react";
import { Stage, Layer, Image as KonvaImage, Rect } from "react-konva";
import type Konva from "konva";
import type { KonvaEventObject } from "konva/lib/Node";
import type { FloorPlan, Photo } from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { PhotoPin } from "./PhotoPin";
import { DistressGlyph } from "./DistressGlyph";

/**
 * react-konva canvas hosting the floor plan image as background +
 * photo pins + distress marks overlaid in plan-pixel coordinates.
 *
 * Auto-fits the image to the container width on mount and on window
 * resize. User pan + zoom on top of that auto-fit baseline:
 *   - Mouse wheel: focal-point zoom (zooms toward / away from the
 *     cursor). Clamped to 0.25× — 8× of the auto-fit scale.
 *   - Click-and-drag on empty canvas area: pans.
 *   - Click on a pin: opens the lightbox (existing handler).
 *   - "Reset view" button: returns to auto-fit + center.
 *
 * Pin/distress mark drag-to-reposition + add/delete distress lands in
 * the next Phase 3 PRs (C-2 + C-3).
 *
 * Plan image load states:
 *   - loading: fetching presigned URL
 *   - pending: 404 — iOS hasn't uploaded the plan image yet. Render
 *     a placeholder grid + the pins/distress in their pixel
 *     coordinates so the rendering is still meaningful (you can see
 *     spatial relationships without the underlying plan).
 *   - ready:   image fetched + decoded
 *   - error:   fetch failed for a non-404 reason
 */
interface Props {
  projectId: string;
  plan: FloorPlan;
  photos: Photo[];
  onSelectPhoto?: (photoIndex: number) => void;
  /**
   * If provided, photo pins become draggable; this fires when the
   * drag completes with the new plan-pixel coordinates. Caller is
   * responsible for mutating the manifest + persisting via the
   * server PUT.
   */
  onPinDrag?: (photoIndex: number, newPlanPixelX: number, newPlanPixelY: number) => void;
  highlightedPhotoId?: string | null;
}

type ImageState =
  | { kind: "loading" }
  | { kind: "pending" }
  | { kind: "ready"; image: HTMLImageElement; width: number; height: number }
  | { kind: "error"; message: string };

// Fallback plan dimensions when we have no image — wide enough to
// hold the photo pins / distress marks at their stored pixel
// coordinates. Most iPad-captured plans are <= 2000×2000.
const FALLBACK_PLAN_WIDTH = 2000;
const FALLBACK_PLAN_HEIGHT = 2000;

// User-zoom clamp. The base scale is "auto-fit to container width"
// per the existing calculation; user wheel zoom multiplies on top of
// that. 0.25× shows the plan smaller than the auto-fit (useful for
// orientation on a large display); 8× lets you zoom into a single
// distress mark at sub-millimetre detail.
const MIN_USER_ZOOM = 0.25;
const MAX_USER_ZOOM = 8;
const WHEEL_ZOOM_FACTOR = 1.1;

export function FloorPlanCanvas({
  projectId,
  plan,
  photos,
  onSelectPhoto,
  onPinDrag,
  highlightedPhotoId,
}: Props) {
  const [imageState, setImageState] = useState<ImageState>({ kind: "loading" });
  const containerRef = useRef<HTMLDivElement | null>(null);
  const stageRef = useRef<Konva.Stage | null>(null);
  const [containerWidth, setContainerWidth] = useState(800);

  // User-driven zoom + pan offsets on top of the auto-fit baseline.
  // userZoom = 1.0 means "fit to container"; >1 zooms in.
  // stagePos is the Stage's x/y translation in screen pixels (post-
  // scale), set both by drag and by focal-point wheel zoom.
  const [userZoom, setUserZoom] = useState(1);
  const [stagePos, setStagePos] = useState({ x: 0, y: 0 });

  // Reset view when switching plans so the new plan starts auto-fit
  // + centered, regardless of where the previous one was zoomed to.
  useEffect(() => {
    setUserZoom(1);
    setStagePos({ x: 0, y: 0 });
  }, [plan.id]);

  // Fetch presigned URL + decode the image.
  useEffect(() => {
    let cancelled = false;
    setImageState({ kind: "loading" });
    api
      .getPlanImageUrl(projectId, plan.id)
      .then((res) => {
        if (cancelled) return;
        const img = new window.Image();
        // No crossOrigin attribute: lets the browser fetch the R2
        // presigned URL without enforcing CORS on the response.
        // (R2 buckets don't have CORS rules configured by default,
        // and we don't need canvas-pixel access for display — only
        // for hypothetical future PDF export, which would need R2
        // bucket CORS configured first anyway.) Without this, the
        // image silently fails to decode + onerror fires.
        img.onload = () => {
          if (cancelled) return;
          setImageState({
            kind: "ready",
            image: img,
            width: img.naturalWidth,
            height: img.naturalHeight,
          });
        };
        img.onerror = () => {
          if (cancelled) return;
          setImageState({ kind: "error", message: "Failed to decode plan image" });
        };
        img.src = res.url;
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        if (e instanceof ApiError && e.status === 404) {
          setImageState({ kind: "pending" });
        } else if (e instanceof ApiError) {
          setImageState({
            kind: "error",
            message: `${e.status} ${e.errorCode}: ${e.message}`,
          });
        } else {
          const detail =
            e instanceof Error
              ? `${e.name}: ${e.message}`
              : String(e);
          setImageState({
            kind: "error",
            message: `Failed to load plan image — ${detail}`,
          });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, plan.id]);

  // Track container width for auto-fit. ResizeObserver covers
  // browser resize + responsive layout changes without re-rendering
  // on every animation frame.
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      const w = entries[0]?.contentRect.width;
      if (w && w > 0) setContainerWidth(w);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Photos to render as pins for this plan. Filter rules:
  //   * Belongs to this plan (floorPlanID matches).
  //   * Either ungrouped (no groupID) OR the primary photo of its
  //     group — non-primary group members would stack on top of the
  //     primary so we suppress them at the canvas layer. The pin
  //     gets a "+N" badge to show how many other photos sit at the
  //     same point.
  // We also compute the per-pin group count once here so the pin
  // component doesn't have to re-scan the photos array.
  const groupCounts = new Map<string, number>();
  for (const p of photos) {
    if (p.groupID) {
      groupCounts.set(p.groupID, (groupCounts.get(p.groupID) ?? 0) + 1);
    }
  }
  const planPins = photos.filter(
    (p) =>
      p.floorPlanID === plan.id &&
      (p.groupID == null || p.isPrimary)
  );
  // Suppressed count = photos that belong to this plan but are non-
  // primary group members. Surfaced in the footer so the user knows
  // the discrepancy between "pins on canvas" and "photos on this plan".
  const planPhotoCount = photos.filter((p) => p.floorPlanID === plan.id).length;
  const suppressedCount = planPhotoCount - planPins.length;

  // Compute scale + stage size based on container width vs plan
  // dimensions.
  const planWidth =
    imageState.kind === "ready" ? imageState.width : FALLBACK_PLAN_WIDTH;
  const planHeight =
    imageState.kind === "ready" ? imageState.height : FALLBACK_PLAN_HEIGHT;
  const baseFitScale = containerWidth / planWidth;
  const effectiveScale = baseFitScale * userZoom;
  const stageWidth = containerWidth;
  // Stage height fits the auto-fit baseline; when the user zooms
  // beyond 1× the image overflows but the Stage shows what fits in
  // this rectangle. We don't grow the Stage on zoom to keep the
  // surrounding page layout stable.
  const stageHeight = planHeight * baseFitScale;

  // Focal-point wheel zoom: scale toward/away from the cursor so
  // the pixel under the cursor stays put. Matches the gesture in
  // Google Maps / Figma / most map UIs.
  function handleWheel(e: KonvaEventObject<WheelEvent>) {
    e.evt.preventDefault();
    const stage = e.target.getStage();
    if (!stage) return;
    const oldScale = stage.scaleX();
    const pointer = stage.getPointerPosition();
    if (!pointer) return;

    const planX = (pointer.x - stage.x()) / oldScale;
    const planY = (pointer.y - stage.y()) / oldScale;

    const direction = e.evt.deltaY > 0 ? -1 : 1;
    const candidate =
      direction > 0
        ? userZoom * WHEEL_ZOOM_FACTOR
        : userZoom / WHEEL_ZOOM_FACTOR;
    const newUserZoom = Math.max(MIN_USER_ZOOM, Math.min(MAX_USER_ZOOM, candidate));
    const newEffectiveScale = baseFitScale * newUserZoom;

    setUserZoom(newUserZoom);
    setStagePos({
      x: pointer.x - planX * newEffectiveScale,
      y: pointer.y - planY * newEffectiveScale,
    });
  }

  function resetView() {
    setUserZoom(1);
    setStagePos({ x: 0, y: 0 });
  }

  const isPanned = userZoom !== 1 || stagePos.x !== 0 || stagePos.y !== 0;

  return (
    <div ref={containerRef} className="w-full">
      {imageState.kind === "pending" && (
        <div className="mb-3 rounded border border-amber-700 bg-amber-950/40 p-3 text-xs text-amber-200">
          ⏳ Plan image hasn't finished uploading from the iPhone yet.
          Showing pin + distress positions on a blank grid — they'll
          line up over the plan once it syncs.
        </div>
      )}
      {imageState.kind === "error" && (
        <div className="mb-3 rounded border border-red-800 bg-red-950/40 p-3 text-xs text-red-300">
          {imageState.message}
        </div>
      )}

      {/* Toolbar: zoom percentage + reset button. Sits above the
          canvas so it stays visible regardless of pan position. */}
      <div className="mb-2 flex items-center justify-between text-xs text-neutral-400">
        <div>
          Zoom: <span className="font-mono">{Math.round(userZoom * 100)}%</span>
          <span className="ml-3 text-neutral-600">
            (scroll to zoom · drag to pan)
          </span>
        </div>
        {isPanned ? (
          <button
            type="button"
            onClick={resetView}
            className="rounded border border-amber-700 bg-amber-950/40 px-2 py-1 text-amber-200 hover:bg-amber-900/40"
          >
            Reset view
          </button>
        ) : (
          <button
            type="button"
            onClick={resetView}
            className="rounded border border-neutral-700 px-2 py-1 text-neutral-400 hover:bg-neutral-800"
            title="Restore the auto-fit view (also useful if you've panned/zoomed to an empty area)"
          >
            Reset view
          </button>
        )}
      </div>

      <Stage
        ref={stageRef}
        width={stageWidth}
        height={stageHeight}
        scaleX={effectiveScale}
        scaleY={effectiveScale}
        x={stagePos.x}
        y={stagePos.y}
        draggable
        onDragEnd={(e) => {
          // Konva's dragend event bubbles up from inner draggable
          // Nodes. A PhotoPin drag fires its own onDragEnd AND
          // re-fires here with `e.target` being the pin's Group,
          // not the Stage. `e.target.x()/y()` would then be the
          // pin's plan-pixel coordinates — applying those as the
          // Stage's pan translation jumps the view across the
          // canvas (especially noticeable at high zoom). Guard so
          // we only treat as a Stage pan when the Stage itself is
          // the drag source.
          if (e.target === e.target.getStage()) {
            setStagePos({ x: e.target.x(), y: e.target.y() });
          }
        }}
        onWheel={handleWheel}
        style={{
          background: "#0a0a0a",
          cursor: "grab",
          overflow: "hidden",
        }}
      >
        <Layer>
          {imageState.kind === "ready" ? (
            <KonvaImage
              image={imageState.image}
              width={imageState.width}
              height={imageState.height}
            />
          ) : (
            <Rect
              x={0}
              y={0}
              width={planWidth}
              height={planHeight}
              fill="#171717"
            />
          )}
          {plan.distress.map((mark) => (
            <DistressGlyph key={mark.id} mark={mark} />
          ))}
          {planPins.map((photo) => {
            const photoIndex = photos.indexOf(photo);
            const groupSize = photo.groupID
              ? groupCounts.get(photo.groupID) ?? 1
              : 1;
            return (
              <PhotoPin
                key={photo.id}
                photo={photo}
                groupSize={groupSize}
                highlighted={highlightedPhotoId === photo.id}
                onClick={
                  onSelectPhoto ? () => onSelectPhoto(photoIndex) : undefined
                }
                onDragEnd={
                  onPinDrag
                    ? (x, y) => onPinDrag(photoIndex, x, y)
                    : undefined
                }
              />
            );
          })}
        </Layer>
      </Stage>
      <div className="mt-2 text-xs text-neutral-500">
        {planPhotoCount} photo{planPhotoCount === 1 ? "" : "s"} on this plan
        {suppressedCount > 0 && (
          <>
            {" "}({planPins.length} pin{planPins.length === 1 ? "" : "s"};{" "}
            {suppressedCount} reshoot{suppressedCount === 1 ? "" : "s"}{" "}
            shown as +N badges)
          </>
        )}
        {" · "}
        {plan.distress.length} distress mark
        {plan.distress.length === 1 ? "" : "s"}
        {imageState.kind === "ready" && (
          <>
            {" · "}
            {imageState.width}×{imageState.height} px
          </>
        )}
      </div>
    </div>
  );
}
