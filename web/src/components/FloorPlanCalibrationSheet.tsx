import { useEffect, useMemo, useRef, useState } from "react";
import { Stage, Layer, Image as KImage, Circle, Line, Text } from "react-konva";
import type Konva from "konva";

/**
 * Floor plan calibration sheet (Build #5.94.1).
 *
 * Same logic iOS requires: a floor plan can't be useful until the
 * user has picked an **origin** (anchor) point and defined a
 * **scale** by clicking two points A and B + entering the real-
 * world distance between them. Pixels-per-foot is then
 * `dist(A,B) / feet`.
 *
 * Workflow:
 *   1. Pick a file (handled outside this sheet).
 *   2. This sheet opens with the image on a Konva stage.
 *   3. User toggles the active tool — Origin / Point A / Point B —
 *      and clicks on the canvas to place each crosshair.
 *   4. A magnifier loupe follows the cursor; clicking on the loupe
 *      counts as a click on the underlying pixel beneath the
 *      cursor (so pixel-precise placement is possible without
 *      needing the entire stage to be zoomed in).
 *   5. User types the real-world distance between A and B in feet.
 *   6. Optional: north heading (degrees clockwise from up).
 *   7. Optional: label override (defaults to the file name).
 *   8. Save fires `onConfirm` with the calibration data; the
 *      parent uploads the file + builds the FloorPlan struct.
 *
 * Pan + zoom: scroll wheel zooms around the cursor; click-and-drag
 * with no active point pans. Tool clicks suppress pan during
 * placement.
 *
 * The magnifier loupe is a fixed-size DOM `<canvas>` overlay (not
 * a second Konva stage) — Konva renders to a stage canvas already,
 * and we draw a 2D-context copy of a clipped region around the
 * cursor. Cheaper than spinning up a second stage on every move.
 */

export interface CalibrationResult {
  /** Plan label (defaults to file stem). */
  label: string;
  /** Origin / anchor pixel coords on the natural image. */
  anchorPixelX: number;
  anchorPixelY: number;
  /** Scale point A (image pixel coords). */
  pointAX: number;
  pointAY: number;
  /** Scale point B (image pixel coords). */
  pointBX: number;
  pointBY: number;
  /** Real-world distance between A and B in feet. */
  calibrationDistanceFeet: number;
  /** Pixels-per-foot, computed from A, B, and distanceFeet. */
  pixelsPerFoot: number;
  /** North heading in degrees (0 = up; clockwise positive). */
  northDeg: number;
}

interface Props {
  /** The image file the user picked. */
  file: File;
  /** Default plan label (typically file.name minus extension). */
  defaultLabel: string;
  onCancel: () => void;
  onConfirm: (result: CalibrationResult) => void;
}

type Tool = "origin" | "pointA" | "pointB" | "pan";

const LOUPE_PX = 140;
const LOUPE_ZOOM = 2.5;

export function FloorPlanCalibrationSheet({
  file,
  defaultLabel,
  onCancel,
  onConfirm,
}: Props) {
  const [imageEl, setImageEl] = useState<HTMLImageElement | null>(null);
  const [imageError, setImageError] = useState<string | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [stageSize, setStageSize] = useState<{ w: number; h: number }>({
    w: 0,
    h: 0,
  });
  // View transform: scale and offset for the stage's internal
  // coordinate system. Image is drawn at `(0,0)` in stage coords;
  // the stage's `scale` and `position` apply the user's pan/zoom.
  const [view, setView] = useState<{
    scale: number;
    x: number;
    y: number;
  }>({ scale: 1, x: 0, y: 0 });
  const [tool, setTool] = useState<Tool>("origin");
  const [origin, setOrigin] = useState<{ x: number; y: number } | null>(null);
  const [pointA, setPointA] = useState<{ x: number; y: number } | null>(null);
  const [pointB, setPointB] = useState<{ x: number; y: number } | null>(null);
  const [distanceFeet, setDistanceFeet] = useState<string>("");
  const [northDeg, setNorthDeg] = useState<string>("0");
  const [label, setLabel] = useState<string>(defaultLabel);
  const [loupeAt, setLoupeAt] = useState<{
    /** Image-natural-pixel coords under the cursor. */
    imgX: number;
    imgY: number;
    /** CSS-pixel coords inside the container (for placing the loupe). */
    cssX: number;
    cssY: number;
  } | null>(null);
  const loupeCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const isPanningRef = useRef(false);
  const lastPanRef = useRef<{ x: number; y: number } | null>(null);

  // Load the underlying HTMLImageElement from the picked File.
  useEffect(() => {
    const url = URL.createObjectURL(file);
    const img = new window.Image();
    img.onload = () => setImageEl(img);
    img.onerror = () => setImageError("Couldn't decode that image.");
    img.src = url;
    return () => URL.revokeObjectURL(url);
  }, [file]);

  // Measure the container + initialize the view to fit the image.
  useEffect(() => {
    if (!containerRef.current || !imageEl) return;
    function measure() {
      if (!containerRef.current || !imageEl) return;
      const rect = containerRef.current.getBoundingClientRect();
      const w = rect.width;
      const h = rect.height;
      setStageSize({ w, h });
      // Initial fit: scale so the image fully fits in the stage.
      const fitScale = Math.min(w / imageEl.naturalWidth, h / imageEl.naturalHeight);
      // Center it.
      const x = (w - imageEl.naturalWidth * fitScale) / 2;
      const y = (h - imageEl.naturalHeight * fitScale) / 2;
      setView({ scale: fitScale, x, y });
    }
    measure();
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, [imageEl]);

  // Convert a stage-pixel coord to natural-image pixel coord.
  function stageToImage(stagePos: { x: number; y: number }): {
    x: number;
    y: number;
  } {
    return {
      x: (stagePos.x - view.x) / view.scale,
      y: (stagePos.y - view.y) / view.scale,
    };
  }

  // Convert a natural-image pixel coord to stage-pixel coord.
  function imageToStage(imgPos: { x: number; y: number }): {
    x: number;
    y: number;
  } {
    return {
      x: imgPos.x * view.scale + view.x,
      y: imgPos.y * view.scale + view.y,
    };
  }

  function handleStageClick(e: Konva.KonvaEventObject<MouseEvent>) {
    if (tool === "pan") return;
    const stage = e.target.getStage();
    const pos = stage?.getPointerPosition();
    if (!pos || !imageEl) return;
    const img = stageToImage(pos);
    // Clamp to image bounds; clicks outside the image are ignored.
    if (
      img.x < 0 ||
      img.y < 0 ||
      img.x > imageEl.naturalWidth ||
      img.y > imageEl.naturalHeight
    ) {
      return;
    }
    const point = { x: Math.round(img.x), y: Math.round(img.y) };
    if (tool === "origin") setOrigin(point);
    else if (tool === "pointA") setPointA(point);
    else if (tool === "pointB") setPointB(point);
    // Auto-advance the tool so the user steps through O → A → B.
    if (tool === "origin" && !pointA) setTool("pointA");
    else if (tool === "pointA" && !pointB) setTool("pointB");
  }

  function handleWheel(e: Konva.KonvaEventObject<WheelEvent>) {
    e.evt.preventDefault();
    const stage = e.target.getStage();
    if (!stage) return;
    const oldScale = view.scale;
    const pointer = stage.getPointerPosition();
    if (!pointer) return;
    const mousePointTo = {
      x: (pointer.x - view.x) / oldScale,
      y: (pointer.y - view.y) / oldScale,
    };
    const factor = e.evt.deltaY > 0 ? 1 / 1.15 : 1.15;
    const newScale = Math.max(0.05, Math.min(20, oldScale * factor));
    setView({
      scale: newScale,
      x: pointer.x - mousePointTo.x * newScale,
      y: pointer.y - mousePointTo.y * newScale,
    });
  }

  function handlePointerDown(e: Konva.KonvaEventObject<MouseEvent>) {
    if (tool !== "pan") return;
    const pos = e.target.getStage()?.getPointerPosition();
    if (!pos) return;
    isPanningRef.current = true;
    lastPanRef.current = pos;
  }
  function handlePointerMove(e: Konva.KonvaEventObject<MouseEvent>) {
    const stage = e.target.getStage();
    const pos = stage?.getPointerPosition();
    if (!pos) return;
    if (isPanningRef.current && lastPanRef.current) {
      const dx = pos.x - lastPanRef.current.x;
      const dy = pos.y - lastPanRef.current.y;
      lastPanRef.current = pos;
      setView((v) => ({ ...v, x: v.x + dx, y: v.y + dy }));
      return;
    }
    if (!imageEl) return;
    const img = stageToImage(pos);
    if (
      img.x < 0 ||
      img.y < 0 ||
      img.x > imageEl.naturalWidth ||
      img.y > imageEl.naturalHeight
    ) {
      setLoupeAt(null);
      return;
    }
    setLoupeAt({
      imgX: img.x,
      imgY: img.y,
      cssX: pos.x,
      cssY: pos.y,
    });
  }
  function handlePointerUp() {
    isPanningRef.current = false;
    lastPanRef.current = null;
  }

  // Paint the loupe each frame the cursor moves.
  useEffect(() => {
    const canvas = loupeCanvasRef.current;
    if (!canvas || !imageEl || !loupeAt) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    canvas.width = LOUPE_PX;
    canvas.height = LOUPE_PX;
    ctx.clearRect(0, 0, LOUPE_PX, LOUPE_PX);

    // Source rect on the natural image — region around (imgX, imgY)
    // that the loupe zooms into.
    const half = LOUPE_PX / (2 * LOUPE_ZOOM);
    const sx = loupeAt.imgX - half;
    const sy = loupeAt.imgY - half;
    const sSize = LOUPE_PX / LOUPE_ZOOM;

    // Clip to circular.
    ctx.save();
    ctx.beginPath();
    ctx.arc(LOUPE_PX / 2, LOUPE_PX / 2, LOUPE_PX / 2 - 1, 0, Math.PI * 2);
    ctx.clip();
    ctx.drawImage(imageEl, sx, sy, sSize, sSize, 0, 0, LOUPE_PX, LOUPE_PX);
    ctx.restore();

    // Crosshair.
    ctx.strokeStyle = "rgba(255, 60, 60, 0.9)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(LOUPE_PX / 2, 0);
    ctx.lineTo(LOUPE_PX / 2, LOUPE_PX);
    ctx.moveTo(0, LOUPE_PX / 2);
    ctx.lineTo(LOUPE_PX, LOUPE_PX / 2);
    ctx.stroke();

    // Ring border.
    ctx.beginPath();
    ctx.strokeStyle = "rgba(255, 255, 255, 0.85)";
    ctx.lineWidth = 2;
    ctx.arc(LOUPE_PX / 2, LOUPE_PX / 2, LOUPE_PX / 2 - 1, 0, Math.PI * 2);
    ctx.stroke();
  }, [loupeAt, imageEl]);

  const pixelDist = useMemo(() => {
    if (!pointA || !pointB) return 0;
    const dx = pointB.x - pointA.x;
    const dy = pointB.y - pointA.y;
    return Math.sqrt(dx * dx + dy * dy);
  }, [pointA, pointB]);

  const parsedFeet = useMemo(() => {
    const v = Number.parseFloat(distanceFeet);
    return Number.isFinite(v) && v > 0 ? v : null;
  }, [distanceFeet]);
  const parsedNorth = useMemo(() => {
    const v = Number.parseFloat(northDeg);
    return Number.isFinite(v) ? v : 0;
  }, [northDeg]);

  const pixelsPerFoot =
    parsedFeet && pixelDist > 0 ? pixelDist / parsedFeet : null;

  const canConfirm =
    origin != null &&
    pointA != null &&
    pointB != null &&
    pixelsPerFoot != null &&
    label.trim().length > 0;

  function confirm() {
    if (!origin || !pointA || !pointB || !pixelsPerFoot) return;
    onConfirm({
      label: label.trim(),
      anchorPixelX: origin.x,
      anchorPixelY: origin.y,
      pointAX: pointA.x,
      pointAY: pointA.y,
      pointBX: pointB.x,
      pointBY: pointB.y,
      calibrationDistanceFeet: parsedFeet ?? 10,
      pixelsPerFoot,
      northDeg: parsedNorth,
    });
  }

  function resetAll() {
    setOrigin(null);
    setPointA(null);
    setPointB(null);
    setDistanceFeet("");
    setTool("origin");
  }

  // Konva component positions (stage coords).
  const originStage = origin ? imageToStage(origin) : null;
  const pointAStage = pointA ? imageToStage(pointA) : null;
  const pointBStage = pointB ? imageToStage(pointB) : null;

  return (
    <div
      role="dialog"
      aria-modal="true"
      className="fixed inset-0 z-50 flex flex-col bg-black/80 p-4"
    >
      <div className="mb-2 flex items-center justify-between text-sm text-neutral-200">
        <span className="font-semibold">Calibrate floor plan</span>
        <button
          type="button"
          onClick={onCancel}
          className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-200 hover:bg-neutral-800"
        >
          Cancel
        </button>
      </div>

      {imageError && (
        <div className="mb-2 rounded border border-red-800 bg-red-950/40 p-2 text-xs text-red-300">
          {imageError}
        </div>
      )}

      {/* Toolbar */}
      <div className="mb-2 flex flex-wrap items-center gap-2 rounded border border-neutral-800 bg-neutral-900/60 p-2 text-xs">
        <span className="text-neutral-500">Tool:</span>
        <ToolButton
          active={tool === "origin"}
          done={origin != null}
          color="#22c55e"
          label="Origin"
          onClick={() => setTool("origin")}
        />
        <ToolButton
          active={tool === "pointA"}
          done={pointA != null}
          color="#3b82f6"
          label="Point A"
          onClick={() => setTool("pointA")}
        />
        <ToolButton
          active={tool === "pointB"}
          done={pointB != null}
          color="#a855f7"
          label="Point B"
          onClick={() => setTool("pointB")}
        />
        <button
          type="button"
          onClick={() => setTool("pan")}
          className={
            tool === "pan"
              ? "rounded border border-blue-500 bg-blue-900/40 px-2 py-1 text-blue-100"
              : "rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800"
          }
        >
          ✋ Pan
        </button>

        <span className="ml-3 text-neutral-500">A↔B distance (ft):</span>
        <input
          type="number"
          inputMode="decimal"
          step="0.01"
          min="0"
          value={distanceFeet}
          onChange={(e) => setDistanceFeet(e.target.value)}
          placeholder="e.g. 10"
          className="w-20 rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-neutral-100 placeholder:text-neutral-600 focus:border-blue-600 focus:outline-none"
        />

        <span className="ml-2 text-neutral-500">North (°):</span>
        <input
          type="number"
          inputMode="decimal"
          step="1"
          value={northDeg}
          onChange={(e) => setNorthDeg(e.target.value)}
          className="w-16 rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-neutral-100 focus:border-blue-600 focus:outline-none"
        />

        <span className="ml-2 text-neutral-500">Label:</span>
        <input
          type="text"
          value={label}
          onChange={(e) => setLabel(e.target.value)}
          placeholder="Plan 1"
          className="rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-neutral-100 placeholder:text-neutral-600 focus:border-blue-600 focus:outline-none"
        />

        <div className="ml-auto flex items-center gap-2">
          <button
            type="button"
            onClick={resetAll}
            className="rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800"
          >
            Reset
          </button>
          <button
            type="button"
            onClick={confirm}
            disabled={!canConfirm}
            className="rounded border border-blue-600 bg-blue-900/40 px-3 py-1 text-blue-100 hover:bg-blue-900/70 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Save plan
          </button>
        </div>
      </div>

      {/* Status row */}
      <div className="mb-2 grid grid-cols-2 gap-2 rounded border border-neutral-800 bg-neutral-900/40 px-3 py-2 text-[11px] text-neutral-300 sm:grid-cols-4">
        <Status
          color="#22c55e"
          label="Origin"
          value={origin ? `(${origin.x.toFixed(0)}, ${origin.y.toFixed(0)})` : "—"}
        />
        <Status
          color="#3b82f6"
          label="Point A"
          value={pointA ? `(${pointA.x.toFixed(0)}, ${pointA.y.toFixed(0)})` : "—"}
        />
        <Status
          color="#a855f7"
          label="Point B"
          value={pointB ? `(${pointB.x.toFixed(0)}, ${pointB.y.toFixed(0)})` : "—"}
        />
        <Status
          color="#facc15"
          label="px / ft"
          value={
            pixelsPerFoot
              ? `${pixelsPerFoot.toFixed(2)} (${pixelDist.toFixed(0)}px ÷ ${parsedFeet ?? 0}ft)`
              : "—"
          }
        />
      </div>

      <div
        ref={containerRef}
        className="relative min-h-0 flex-1 overflow-hidden rounded border border-neutral-800 bg-neutral-950"
        style={{ cursor: tool === "pan" ? "grab" : "crosshair" }}
      >
        {imageEl && (
          <Stage
            width={stageSize.w}
            height={stageSize.h}
            onWheel={handleWheel}
            onClick={handleStageClick}
            onMouseDown={handlePointerDown}
            onMouseMove={handlePointerMove}
            onMouseUp={handlePointerUp}
            onMouseLeave={() => setLoupeAt(null)}
          >
            <Layer>
              <KImage
                image={imageEl}
                x={view.x}
                y={view.y}
                scaleX={view.scale}
                scaleY={view.scale}
                listening={false}
              />
              {pointAStage && pointBStage && (
                <Line
                  points={[
                    pointAStage.x,
                    pointAStage.y,
                    pointBStage.x,
                    pointBStage.y,
                  ]}
                  stroke="#a855f7"
                  strokeWidth={2}
                  dash={[4, 4]}
                  listening={false}
                />
              )}
              {originStage && (
                <Crosshair stagePos={originStage} color="#22c55e" label="O" />
              )}
              {pointAStage && (
                <Crosshair stagePos={pointAStage} color="#3b82f6" label="A" />
              )}
              {pointBStage && (
                <Crosshair stagePos={pointBStage} color="#a855f7" label="B" />
              )}
            </Layer>
          </Stage>
        )}

        {/* Magnifier loupe */}
        {loupeAt && imageEl && (
          <div
            style={{
              position: "absolute",
              left: loupeAt.cssX + 16,
              top: loupeAt.cssY + 16,
              width: LOUPE_PX,
              height: LOUPE_PX,
              pointerEvents: "none",
              borderRadius: "50%",
              boxShadow: "0 4px 16px rgba(0,0,0,0.6)",
            }}
          >
            <canvas ref={loupeCanvasRef} width={LOUPE_PX} height={LOUPE_PX} />
          </div>
        )}
      </div>

      <p className="mt-2 text-[11px] text-neutral-500">
        Click on the image to place each crosshair — switch tool with
        the buttons above. Scroll-wheel to zoom; switch to ✋ Pan to
        drag the image around. The magnifier loupe shows a {LOUPE_ZOOM}× view
        around the cursor for pixel-precise placement.
      </p>
    </div>
  );
}

function Crosshair({
  stagePos,
  color,
  label,
}: {
  stagePos: { x: number; y: number };
  color: string;
  label: string;
}) {
  const R = 10;
  return (
    <>
      <Circle x={stagePos.x} y={stagePos.y} radius={R} stroke={color} strokeWidth={2} />
      <Line
        points={[stagePos.x - R, stagePos.y, stagePos.x + R, stagePos.y]}
        stroke={color}
        strokeWidth={1}
      />
      <Line
        points={[stagePos.x, stagePos.y - R, stagePos.x, stagePos.y + R]}
        stroke={color}
        strokeWidth={1}
      />
      <Text
        x={stagePos.x + R + 4}
        y={stagePos.y - 6}
        text={label}
        fill={color}
        fontStyle="bold"
        fontSize={14}
      />
    </>
  );
}

function ToolButton({
  active,
  done,
  color,
  label,
  onClick,
}: {
  active: boolean;
  done: boolean;
  color: string;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={
        active
          ? "rounded border border-white bg-neutral-900 px-2 py-1 text-neutral-100"
          : "rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800"
      }
      style={
        active
          ? { boxShadow: `inset 0 0 0 2px ${color}` }
          : undefined
      }
    >
      <span
        className="mr-1 inline-block h-2 w-2 rounded-full align-middle"
        style={{ background: color }}
      />
      {label}
      {done && <span className="ml-1 text-green-400">✓</span>}
    </button>
  );
}

function Status({
  color,
  label,
  value,
}: {
  color: string;
  label: string;
  value: string;
}) {
  return (
    <div className="flex items-center gap-2">
      <span
        className="inline-block h-2.5 w-2.5 rounded-full"
        style={{ background: color }}
      />
      <span className="text-neutral-500">{label}:</span>
      <span className="font-mono text-neutral-200">{value}</span>
    </div>
  );
}
