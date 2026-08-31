import { useEffect, useRef, useState } from "react";
import { Stage, Layer, Image as KImage, Line } from "react-konva";
import type Konva from "konva";
import type { Photo, Project } from "@forensic/shared";
import { api } from "../lib/api";
import { uploadFile } from "../lib/uploadFile";

/**
 * Photo markup canvas (Build #5.91.1).
 *
 * Non-PencilKit web equivalent of iOS markup. Opens as a modal
 * with the photo as a background `<image>` on a Konva stage and a
 * transparent drawing layer on top. Tools:
 *   - Pen (color + width).
 *   - Eraser (drawn as a destination-out line — same shape, just
 *     erases prior strokes).
 *   - Undo / Redo (single stack of stroke operations).
 *   - Clear (drops every stroke; one undo will bring them back
 *     because Clear pushes the prior stack onto the undo log).
 *
 * On Save:
 *   1. Render the drawing-only layer to a PNG via Konva's
 *      `toDataURL` at the natural photo dimensions.
 *   2. Convert dataURL to Blob.
 *   3. Upload as `kind=markup_png` via the existing presigned-PUT
 *      pipeline (PR #7).
 *   4. Write `markupOverlayFilename: <photoId>.png` on the photo
 *      so iOS knows it has markup; persist via `onPhotoUpdated`.
 *
 * iOS reads the PNG and renders it on top of the photo — round-
 * trip compatible.
 */

interface Stroke {
  /** Hex color. For eraser strokes, this is ignored (composite
   *  mode draws transparent). */
  color: string;
  /** Stroke width in canvas-CSS pixels. */
  width: number;
  /** Whether this stroke is an eraser. */
  erase: boolean;
  /** Flat array of [x, y, x, y, …] — Konva `Line` `points` format. */
  points: number[];
}

interface Props {
  projectId: string;
  project: Project;
  photo: Photo;
  onClose: () => void;
  onPhotoUpdated: (next: Photo) => void;
}

const PEN_COLORS = ["#ef4444", "#fbbf24", "#22c55e", "#3b82f6", "#a855f7", "#ffffff"];
const PEN_WIDTHS = [2, 4, 8, 16];

export function PhotoMarkupCanvas({
  projectId,
  project,
  photo,
  onClose,
  onPhotoUpdated,
}: Props) {
  const latest = useRef({ project, photo });
  latest.current = { project, photo };
  const [imageUrl, setImageUrl] = useState<string | null>(null);
  const [imageError, setImageError] = useState<string | null>(null);
  const [naturalSize, setNaturalSize] = useState<{ w: number; h: number } | null>(
    null
  );
  const [stageSize, setStageSize] = useState<{ w: number; h: number }>({
    w: 0,
    h: 0,
  });
  const [tool, setTool] = useState<"pen" | "eraser">("pen");
  const [color, setColor] = useState<string>(PEN_COLORS[0]!);
  const [width, setWidth] = useState<number>(PEN_WIDTHS[1]!);
  const [strokes, setStrokes] = useState<Stroke[]>([]);
  const [redoStack, setRedoStack] = useState<Stroke[][]>([]);
  const [isDrawing, setIsDrawing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const drawLayerRef = useRef<Konva.Layer | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);

  // Fetch the photo image URL on mount.
  useEffect(() => {
    let cancelled = false;
    api
      .getPhotoImageUrl(projectId, photo.id)
      .then((resp) => {
        if (cancelled) return;
        setImageUrl(resp.url);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setImageError(
          e instanceof Error ? e.message : "Failed to load photo image."
        );
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, photo.id]);

  // Load the underlying HTMLImageElement so we know natural dims.
  useEffect(() => {
    if (!imageUrl) return;
    const img = new window.Image();
    img.crossOrigin = "anonymous";
    img.onload = () => setNaturalSize({ w: img.naturalWidth, h: img.naturalHeight });
    img.onerror = () => setImageError("Failed to decode photo bitmap.");
    img.src = imageUrl;
  }, [imageUrl]);

  // Fit the stage to its container while preserving photo aspect.
  useEffect(() => {
    if (!naturalSize || !containerRef.current) return;
    function measure() {
      if (!containerRef.current || !naturalSize) return;
      const rect = containerRef.current.getBoundingClientRect();
      const containerW = rect.width;
      const containerH = rect.height;
      const ratio = naturalSize.w / naturalSize.h;
      let w = containerW;
      let h = w / ratio;
      if (h > containerH) {
        h = containerH;
        w = h * ratio;
      }
      setStageSize({ w, h });
    }
    measure();
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, [naturalSize]);

  function pushStroke(stroke: Stroke) {
    setStrokes((cur) => [...cur, stroke]);
    setRedoStack([]);
  }

  function startDrawing(x: number, y: number) {
    setIsDrawing(true);
    pushStroke({
      color,
      width,
      erase: tool === "eraser",
      points: [x, y],
    });
  }

  function extendDrawing(x: number, y: number) {
    setStrokes((cur) => {
      if (cur.length === 0) return cur;
      const next = [...cur];
      const last = next[next.length - 1]!;
      next[next.length - 1] = { ...last, points: [...last.points, x, y] };
      return next;
    });
  }

  function endDrawing() {
    setIsDrawing(false);
  }

  function undo() {
    setStrokes((cur) => {
      if (cur.length === 0) return cur;
      const last = cur[cur.length - 1]!;
      setRedoStack((r) => [...r, [last]]);
      return cur.slice(0, -1);
    });
  }

  function redo() {
    setRedoStack((cur) => {
      if (cur.length === 0) return cur;
      const restoreGroup = cur[cur.length - 1]!;
      setStrokes((s) => [...s, ...restoreGroup]);
      return cur.slice(0, -1);
    });
  }

  function clearAll() {
    if (strokes.length === 0) return;
    setRedoStack((r) => [...r, strokes]);
    setStrokes([]);
  }

  async function save() {
    if (!naturalSize || saving) return;
    setSaving(true);
    setSaveError(null);
    try {
      const layer = drawLayerRef.current;
      if (!layer) throw new Error("Drawing layer not ready.");
      // Render at natural photo dimensions so the overlay is pixel-
      // accurate when iOS composites it on top of the photo. The
      // current stage may be downscaled to fit the modal; pixelRatio
      // multiplies to compensate.
      const pixelRatio = naturalSize.w / Math.max(1, stageSize.w);
      const dataUrl = layer.toDataURL({
        mimeType: "image/png",
        pixelRatio,
      });
      const blob = await dataUrlToBlob(dataUrl);
      const filename = `${photo.id}-${crypto.randomUUID()}.png`;
      await uploadFile({
        projectId,
        photoId: photo.id,
        kind: "markup_png",
        sourceFilename: filename,
        file: blob,
        contentType: "image/png",
      });
      const current = latest.current.project.photos.find((p) => p.id === photo.id);
      if (!current || latest.current.project.isFrozen) throw new Error("This photo is no longer editable. Your saved project was left unchanged.");
      // A fresh filename lets another device notice the new overlay. Web
      // replaces the raster markup, so an older PencilKit drawing is stale.
      onPhotoUpdated({ ...current, markupOverlayFilename: filename, markupDrawingFilename: null });
      onClose();
    } catch (e: unknown) {
      setSaveError(e instanceof Error ? e.message : "Save failed.");
    } finally {
      setSaving(false);
    }
  }

  function clearMarkupOnly() {
    // Clear the saved overlay entirely (clears `markupOverlayFilename`).
    if (!window.confirm("Clear the saved markup for this photo?")) return;
    onPhotoUpdated({ ...photo, markupOverlayFilename: null });
    onClose();
  }

  // Map screen-space pointer coords to stage coords, accounting for
  // the modal centering. The stage's `pointerPosition` already gives
  // us coords relative to the stage.
  function onStagePointerDown(e: Konva.KonvaEventObject<MouseEvent | TouchEvent>) {
    const stage = e.target.getStage();
    const pos = stage?.getPointerPosition();
    if (!pos) return;
    startDrawing(pos.x, pos.y);
  }
  function onStagePointerMove(e: Konva.KonvaEventObject<MouseEvent | TouchEvent>) {
    if (!isDrawing) return;
    const stage = e.target.getStage();
    const pos = stage?.getPointerPosition();
    if (!pos) return;
    extendDrawing(pos.x, pos.y);
  }
  function onStagePointerUp() {
    endDrawing();
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      className="fixed inset-0 z-50 flex flex-col bg-black/80 p-4"
    >
      <div className="mb-2 flex items-center justify-between text-sm text-neutral-200">
        <div className="flex items-center gap-3">
          <span className="font-semibold">Markup · photo #{photo.sequenceNumber}</span>
          {imageError && <span className="text-red-400">{imageError}</span>}
        </div>
        <button
          type="button"
          onClick={onClose}
          className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-200 hover:bg-neutral-800"
        >
          Cancel
        </button>
      </div>

      {/* Toolbar */}
      <div className="mb-2 flex flex-wrap items-center gap-3 rounded border border-neutral-800 bg-neutral-900/60 p-2 text-xs">
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={() => setTool("pen")}
            className={
              tool === "pen"
                ? "rounded border border-blue-500 bg-blue-900/40 px-2 py-1 text-blue-100"
                : "rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800"
            }
          >
            Pen
          </button>
          <button
            type="button"
            onClick={() => setTool("eraser")}
            className={
              tool === "eraser"
                ? "rounded border border-blue-500 bg-blue-900/40 px-2 py-1 text-blue-100"
                : "rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800"
            }
          >
            Eraser
          </button>
        </div>

        <div className="flex items-center gap-1">
          {PEN_COLORS.map((c) => (
            <button
              key={c}
              type="button"
              onClick={() => setColor(c)}
              disabled={tool === "eraser"}
              aria-label={`Color ${c}`}
              className={
                color === c
                  ? "h-5 w-5 rounded-full border-2 border-white disabled:opacity-30"
                  : "h-5 w-5 rounded-full border border-neutral-700 hover:border-neutral-400 disabled:opacity-30"
              }
              style={{ background: c }}
            />
          ))}
        </div>

        <div className="flex items-center gap-1">
          <span className="text-neutral-500">Width:</span>
          {PEN_WIDTHS.map((w) => (
            <button
              key={w}
              type="button"
              onClick={() => setWidth(w)}
              className={
                width === w
                  ? "rounded border border-blue-500 bg-blue-900/40 px-2 py-1 text-blue-100"
                  : "rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800"
              }
            >
              {w}px
            </button>
          ))}
        </div>

        <div className="ml-auto flex items-center gap-1">
          <button
            type="button"
            onClick={undo}
            disabled={strokes.length === 0}
            className="rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Undo
          </button>
          <button
            type="button"
            onClick={redo}
            disabled={redoStack.length === 0}
            className="rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Redo
          </button>
          <button
            type="button"
            onClick={clearAll}
            disabled={strokes.length === 0}
            className="rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Clear
          </button>
          {photo.markupOverlayFilename && (
            <button
              type="button"
              onClick={clearMarkupOnly}
              className="rounded border border-red-800 px-2 py-1 text-red-300 hover:bg-red-950/40"
              title="Remove the saved markup overlay for this photo."
            >
              Delete saved markup
            </button>
          )}
          <button
            type="button"
            onClick={save}
            disabled={saving || strokes.length === 0 || !naturalSize}
            className="rounded border border-blue-600 bg-blue-900/40 px-3 py-1 text-blue-100 hover:bg-blue-900/70 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save"}
          </button>
        </div>
      </div>

      {saveError && (
        <div className="mb-2 rounded border border-red-800 bg-red-950/40 p-2 text-xs text-red-300">
          {saveError}
        </div>
      )}

      <div
        ref={containerRef}
        className="flex min-h-0 flex-1 items-center justify-center overflow-hidden rounded border border-neutral-800 bg-black"
      >
        {!imageUrl || !naturalSize ? (
          <div className="text-sm text-neutral-500">Loading photo…</div>
        ) : (
          <Stage
            width={stageSize.w}
            height={stageSize.h}
            onMouseDown={onStagePointerDown}
            onTouchStart={onStagePointerDown}
            onMouseMove={onStagePointerMove}
            onTouchMove={onStagePointerMove}
            onMouseUp={onStagePointerUp}
            onTouchEnd={onStagePointerUp}
            style={{ cursor: "crosshair" }}
          >
            <Layer listening={false}>
              <BackgroundImage url={imageUrl} width={stageSize.w} height={stageSize.h} />
            </Layer>
            <Layer ref={drawLayerRef as React.Ref<Konva.Layer>}>
              {strokes.map((s, i) => (
                <Line
                  key={i}
                  points={s.points}
                  stroke={s.color}
                  strokeWidth={s.width}
                  tension={0.4}
                  lineCap="round"
                  lineJoin="round"
                  globalCompositeOperation={
                    s.erase ? "destination-out" : "source-over"
                  }
                />
              ))}
            </Layer>
          </Stage>
        )}
      </div>

      <p className="mt-2 text-[11px] text-neutral-500">
        Markup is saved as a transparent PNG overlay at the photo's
        natural resolution. iOS reads the same field
        (`markupOverlayFilename`) and renders the overlay on top of
        the photo — round-trip compatible.
      </p>
    </div>
  );
}

function BackgroundImage({
  url,
  width,
  height,
}: {
  url: string;
  width: number;
  height: number;
}) {
  const [img, setImg] = useState<HTMLImageElement | null>(null);
  useEffect(() => {
    const i = new window.Image();
    i.crossOrigin = "anonymous";
    i.src = url;
    i.onload = () => setImg(i);
  }, [url]);
  if (!img) return null;
  return <KImage image={img} width={width} height={height} listening={false} />;
}

async function dataUrlToBlob(dataUrl: string): Promise<Blob> {
  const res = await fetch(dataUrl);
  return res.blob();
}
