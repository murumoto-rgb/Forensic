import { useEffect, useRef, useState } from "react";
import { Stage, Layer, Image as KonvaImage, Rect, Line } from "react-konva";
import type Konva from "konva";
import type { KonvaEventObject } from "konva/lib/Node";
import type { DistressKind, FloorPlan, Photo } from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { PhotoPin } from "./PhotoPin";
import { DistressGlyph } from "./DistressGlyph";
import { detectPrimaryClusters } from "../lib/clusterFanning";

/**
 * react-konva canvas hosting the floor plan image as background +
 * photo pins + distress marks overlaid in plan-pixel coordinates.
 *
 * Auto-fits the image to the container width on mount and on window
 * resize. User pan + zoom on top of that auto-fit baseline:
 *   - Mouse wheel: focal-point zoom (zooms toward / away from the
 *     cursor). Clamped to 0.25× — 8× of the auto-fit scale.
 *   - Click-and-drag on empty canvas area: pans (unless distress
 *     mode is on — see below).
 *   - Click on a pin: opens the lightbox (existing handler).
 *   - Click on a distress glyph: opens its editor (Phase 3 PR-C-3).
 *   - "Reset view" button: returns to auto-fit + center.
 *
 * Distress add mode (`distressKind != null`): Stage panning is
 * disabled so a click doesn't pan; instead:
 *   - Point kinds (outOfPlumbDoor / doorNotLatching / crackGradeBeam):
 *     a click on empty canvas places a single-point mark.
 *   - Stroke kind (crackFloor): mousedown → drag → mouseup draws a
 *     polyline, sampled every ~4 plan-pixels of cursor movement to
 *     keep the points array reasonable.
 * In both cases we call `onAddDistress` with the proposed geometry
 * in plan-pixel coordinates; the parent stages it in a confirm
 * dialog and only commits on user confirmation, mirroring the
 * pin-drag UX from Build #5.15.1.
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
  /**
   * Non-null = distress add mode is on with this kind selected.
   * Null/undefined = distress add mode is off (default behaviour:
   * pan + zoom + pin-drag if `onPinDrag` is set).
   */
  distressKind?: DistressKind | null;
  /**
   * Fires when the user has finished placing a new distress mark.
   * `points` are plan-pixel coordinates. Caller stages this in a
   * confirm dialog before saving.
   */
  onAddDistress?: (kind: DistressKind, points: Array<[number, number]>) => void;
  /**
   * Fires when the user clicks an existing distress mark. Caller
   * opens an editor (change kind / note / delete) for it.
   */
  onClickDistress?: (markId: string) => void;
  /**
   * Uniform scale factor for photo-pin visual size. 1.0 = default;
   * controlled by the toolbar +/- buttons (Build #5.26.1). Also
   * drives the spatial-cluster collision radius — bigger pins
   * cluster at a larger plan-pixel threshold so two pins that
   * visually overlap also cluster.
   */
  bubbleScale?: number;
  /**
   * Fires when the user clicks a spatial-cluster representative pin
   * (a single bubble standing in for ≥2 pins that landed within a
   * bubble-radius of each other on the plan). `photoIndices` are
   * indices into the `photos` array — the parent uses these to drive
   * the cluster popover. When undefined, cluster reps render but
   * aren't clickable (view-only).
   */
  onClickCluster?: (photoIndices: number[], screenX: number, screenY: number) => void;
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

// Minimum spacing between consecutive stroke samples, in PLAN pixels.
// Keeps a freehand crackFloor stroke at ~10-100 points instead of
// hundreds, while still rendering smoothly because pixels are
// converted to screen via `effectiveScale` on render. At 1× zoom on
// a 3000-px-wide plan, 4 plan-pixels ≈ 2 screen-pixels on a
// 1500-px-wide container — visually continuous.
const STROKE_MIN_SAMPLE_DISTANCE = 4;

export function FloorPlanCanvas({
  projectId,
  plan,
  photos,
  onSelectPhoto,
  onPinDrag,
  highlightedPhotoId,
  distressKind,
  onAddDistress,
  onClickDistress,
  bubbleScale = 1,
  onClickCluster,
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

  // In-progress freehand stroke (only while distressKind === "crackFloor"
  // and the user is mid-drag). Cleared on completion or abort.
  const [currentStroke, setCurrentStroke] = useState<Array<[number, number]> | null>(null);

  // Reset view when switching plans so the new plan starts auto-fit
  // + centered, regardless of where the previous one was zoomed to.
  useEffect(() => {
    setUserZoom(1);
    setStagePos({ x: 0, y: 0 });
  }, [plan.id]);

  // Cancel any in-progress stroke if distress mode turns off or the
  // kind changes mid-draw. Prevents a half-drawn line lingering on
  // the canvas after the toggle flips.
  useEffect(() => {
    setCurrentStroke(null);
  }, [distressKind, plan.id]);

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

  const distressMode = distressKind != null;
  const distressIsStroke = distressKind === "crackFloor";

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

  // Convert the current pointer position from screen-space to
  // plan-pixel-space using the Stage's current scale + translation.
  function pointerPlanCoords(stage: Konva.Stage): { x: number; y: number } | null {
    const p = stage.getPointerPosition();
    if (!p) return null;
    const scale = stage.scaleX();
    return {
      x: (p.x - stage.x()) / scale,
      y: (p.y - stage.y()) / scale,
    };
  }

  // Click on the Stage when in distress mode for a POINT kind — place
  // a single-point mark. We DON'T check `e.target === stage` here
  // because clicks on the plan land on the KonvaImage (the plan
  // background), not the Stage itself, so that check would block
  // every legitimate placement (Build #5.24.1 fix). Instead, PhotoPin
  // and DistressGlyph each stop their click bubble at the source, so
  // any click that reaches the Stage's handler is by definition a
  // click on the empty plan canvas.
  // Accepts the union of MouseEvent and TouchEvent so the same body
  // can back both Stage `onClick` (mouse) and `onTap` (touch) — the
  // handler only touches `e.target`, not the evt-specific fields.
  function handleStageClick(
    e: KonvaEventObject<MouseEvent> | KonvaEventObject<TouchEvent>
  ) {
    if (!distressMode || distressIsStroke) return;
    if (!onAddDistress || distressKind == null) return;
    const stage = e.target.getStage();
    if (!stage) return;
    const coords = pointerPlanCoords(stage);
    if (!coords) return;
    onAddDistress(distressKind, [[coords.x, coords.y]]);
  }

  // Stroke drawing — only active for kind === "crackFloor". Same
  // bubble-rather-than-target reasoning as handleStageClick above:
  // PhotoPin / DistressGlyph stop mousedown at the source so we
  // don't start a stroke at the pin's coordinates if the user
  // mousedowns on top of one.
  function handleStrokeStart(e: KonvaEventObject<MouseEvent>) {
    if (!distressMode || !distressIsStroke) return;
    const stage = e.target.getStage();
    if (!stage) return;
    const coords = pointerPlanCoords(stage);
    if (!coords) return;
    setCurrentStroke([[coords.x, coords.y]]);
  }

  function handleStrokeMove(e: KonvaEventObject<MouseEvent>) {
    if (!distressMode || !distressIsStroke) return;
    if (currentStroke == null) return;
    const stage = e.target.getStage();
    if (!stage) return;
    const coords = pointerPlanCoords(stage);
    if (!coords) return;
    // Throttle by minimum spacing — both for performance and so the
    // resulting `points` array isn't dominated by sub-pixel jitter.
    const last = currentStroke[currentStroke.length - 1];
    if (last) {
      const dx = coords.x - last[0];
      const dy = coords.y - last[1];
      if (dx * dx + dy * dy < STROKE_MIN_SAMPLE_DISTANCE * STROKE_MIN_SAMPLE_DISTANCE) {
        return;
      }
    }
    setCurrentStroke([...currentStroke, [coords.x, coords.y]]);
  }

  function handleStrokeEnd() {
    if (!distressMode || !distressIsStroke) return;
    const stroke = currentStroke;
    setCurrentStroke(null);
    // Need at least 2 points to make a meaningful line; a single-point
    // crackFloor would render as nothing (DistressGlyph requires
    // >=2 for the stroke branch) and isn't useful as a measurement.
    if (!stroke || stroke.length < 2) return;
    if (!onAddDistress || distressKind == null) return;
    onAddDistress(distressKind, stroke);
  }

  function resetView() {
    setUserZoom(1);
    setStagePos({ x: 0, y: 0 });
  }

  const isPanned = userZoom !== 1 || stagePos.x !== 0 || stagePos.y !== 0;

  // Flatten the in-progress stroke for the temporary Line preview.
  const currentStrokeFlat: number[] = [];
  if (currentStroke) {
    for (const [x, y] of currentStroke) {
      currentStrokeFlat.push(x, y);
    }
  }

  // Spatial cluster detection — mirror iOS PlanViewerView. Two pins
  // whose centers fall within one bubble-radius of each other on the
  // plan get collapsed to a single representative bubble at the
  // cluster centroid with a "+N" badge showing how many other pins
  // are stacked there. The collision radius is in PLAN pixels and
  // scales with the rendered bubble size: at fit-to-screen, a pin's
  // screen radius is `(BASE_PIN_RADIUS * bubbleScale)`; convert to
  // plan-pixels via baseFitScale. Result: detection is independent of
  // the user's wheel zoom (a cluster at zoom=1 stays a cluster at
  // zoom=4) but responds to the bubble-size slider.
  //
  // Disabled when pin drag is active so each pin remains
  // independently draggable. Otherwise dragging a "representative"
  // would only move its lead while the cluster centroid stayed
  // anchored to the unmoved others — confusing.
  const BASE_PIN_RADIUS_SCREEN = 10;
  const collisionRadiusPlanPx =
    onPinDrag != null
      ? 0 // singleton clusters only
      : (BASE_PIN_RADIUS_SCREEN * bubbleScale) / Math.max(baseFitScale, 1e-6);
  const pinClusters = detectPrimaryClusters(
    planPins,
    (p) => ({
      x: p.planPixelX ?? 0,
      y: p.planPixelY ?? 0,
    }),
    collisionRadiusPlanPx
  );

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
            {distressMode
              ? distressIsStroke
                ? "(drag to draw a stroke · scroll to zoom)"
                : "(click to place · scroll to zoom)"
              : "(scroll to zoom · drag to pan)"}
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
        // Disable Stage panning while in distress mode so a click /
        // drag goes to placement instead of being interpreted as pan.
        draggable={!distressMode}
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
        // Inline lambdas bridge the prop's specific event type
        // (MouseEvent for onClick, TouchEvent for onTap) to
        // handleStageClick's union signature without TS complaints.
        onClick={(e) => handleStageClick(e)}
        onTap={(e) => handleStageClick(e)}
        onMouseDown={handleStrokeStart}
        onMouseMove={handleStrokeMove}
        onMouseUp={handleStrokeEnd}
        onMouseLeave={handleStrokeEnd}
        style={{
          background: "#0a0a0a",
          cursor: distressMode ? "crosshair" : "grab",
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
            <DistressGlyph
              key={mark.id}
              mark={mark}
              editable={distressMode && onClickDistress != null}
              onClick={
                onClickDistress ? () => onClickDistress(mark.id) : undefined
              }
            />
          ))}
          {/* In-progress freehand stroke (crackFloor) preview. Renders
              with reduced opacity + dashed style so it's clearly
              distinguishable from committed marks until the user
              confirms in the save dialog. */}
          {currentStroke && currentStroke.length >= 2 && (
            <Line
              points={currentStrokeFlat}
              stroke="#fb923c"
              strokeWidth={4}
              lineCap="round"
              lineJoin="round"
              opacity={0.6}
              dash={[8, 6]}
              listening={false}
            />
          )}
          {pinClusters.map((cluster) => {
            // `detectPrimaryClusters` always returns ≥1 member per
            // cluster, but TS's noUncheckedIndexedAccess can't see
            // that. Pull the first member with an explicit guard so
            // the rest of the branch can rely on a defined Photo.
            const firstMember = cluster.members[0];
            if (!firstMember) return null;

            // Singleton cluster: render the pin exactly as before
            // this PR (own position, own groupSize badge, own click).
            if (cluster.members.length === 1) {
              const photo = firstMember;
              const photoIndex = photos.indexOf(photo);
              const groupSize = photo.groupID
                ? groupCounts.get(photo.groupID) ?? 1
                : 1;
              return (
                <PhotoPin
                  key={photo.id}
                  photo={photo}
                  groupSize={groupSize}
                  scale={bubbleScale}
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
            }

            // Multi-member cluster: render ONE pin at the centroid
            // using the lowest-sequenceNumber member as the visual
            // lead. Badge shows the count of other pins in the
            // cluster. Click opens the parent's cluster popover so
            // the engineer can pick which underlying photo to view.
            const lead = cluster.members.reduce(
              (best, p) =>
                p.sequenceNumber < best.sequenceNumber ? p : best,
              firstMember
            );
            const memberIndices = cluster.members.map((m) =>
              photos.indexOf(m)
            );
            const otherCount = cluster.members.length - 1;
            return (
              <PhotoPin
                key={`cluster-${lead.id}`}
                photo={lead}
                scale={bubbleScale}
                renderX={cluster.centroidX}
                renderY={cluster.centroidY}
                badgeOverride={{ count: otherCount }}
                highlighted={
                  highlightedPhotoId != null &&
                  cluster.members.some((m) => m.id === highlightedPhotoId)
                }
                onClick={
                  onClickCluster
                    ? () => {
                        // Convert centroid plan-pixel → screen-pixel
                        // so the parent can position the popover.
                        // The Stage's current scale + translation
                        // already account for the user's wheel zoom
                        // and pan.
                        const stage = stageRef.current;
                        if (!stage) {
                          onClickCluster(memberIndices, 0, 0);
                          return;
                        }
                        const screenX =
                          cluster.centroidX * stage.scaleX() + stage.x();
                        const screenY =
                          cluster.centroidY * stage.scaleY() + stage.y();
                        // Also offset by the Stage's bounding rect in
                        // the page so the popover lands at the right
                        // viewport coords, not relative to the Stage.
                        const containerRect = stage
                          .container()
                          .getBoundingClientRect();
                        onClickCluster(
                          memberIndices,
                          containerRect.left + screenX,
                          containerRect.top + screenY
                        );
                      }
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
        {pinClusters.length < planPins.length && (
          <>
            {" "}({pinClusters.length} marker
            {pinClusters.length === 1 ? "" : "s"}{" "}
            after spatial clustering)
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
