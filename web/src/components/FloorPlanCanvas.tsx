import { useEffect, useRef, useState } from "react";
import { Stage, Layer, Image as KonvaImage, Rect } from "react-konva";
import type { FloorPlan, Photo } from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { PhotoPin } from "./PhotoPin";
import { DistressGlyph } from "./DistressGlyph";

/**
 * react-konva canvas hosting the floor plan image as background +
 * photo pins + distress marks overlaid in plan-pixel coordinates.
 *
 * Auto-fits the image to the container width on mount and on window
 * resize; pan/zoom comes in Phase 3 PR-B alongside drag editing.
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

export function FloorPlanCanvas({
  projectId,
  plan,
  photos,
  onSelectPhoto,
  highlightedPhotoId,
}: Props) {
  const [imageState, setImageState] = useState<ImageState>({ kind: "loading" });
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [containerWidth, setContainerWidth] = useState(800);

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
        // 404 = plan binary not in R2 yet (Phase 2 iOS only uploads
        // photos; plan upload lands in Phase 3 PR-B). Show the
        // amber "pending upload" banner; pins/distress still render
        // over the blank canvas.
        if (e instanceof ApiError && e.status === 404) {
          setImageState({ kind: "pending" });
        } else if (e instanceof ApiError) {
          setImageState({
            kind: "error",
            message: `${e.status} ${e.errorCode}: ${e.message}`,
          });
        } else {
          // Non-ApiError = pre-response failure (network, CORS,
          // throw inside the fetch wrapper). Surface the underlying
          // message instead of swallowing it so the user can see
          // the actual cause.
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

  // Photos that belong to this plan.
  const planPhotos = photos.filter((p) => p.floorPlanID === plan.id);

  // Compute scale + stage size based on container width vs plan
  // dimensions.
  const planWidth =
    imageState.kind === "ready" ? imageState.width : FALLBACK_PLAN_WIDTH;
  const planHeight =
    imageState.kind === "ready" ? imageState.height : FALLBACK_PLAN_HEIGHT;
  const scale = containerWidth / planWidth;
  const stageWidth = containerWidth;
  const stageHeight = planHeight * scale;

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
      <Stage
        width={stageWidth}
        height={stageHeight}
        scaleX={scale}
        scaleY={scale}
        style={{ background: "#0a0a0a" }}
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
          {planPhotos.map((photo) => {
            const photoIndex = photos.indexOf(photo);
            return (
              <PhotoPin
                key={photo.id}
                photo={photo}
                highlighted={highlightedPhotoId === photo.id}
                onClick={
                  onSelectPhoto ? () => onSelectPhoto(photoIndex) : undefined
                }
              />
            );
          })}
        </Layer>
      </Stage>
      <div className="mt-2 text-xs text-neutral-500">
        {planPhotos.length} photo{planPhotos.length === 1 ? "" : "s"} on this
        plan · {plan.distress.length} distress mark
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
