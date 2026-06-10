import { Circle, Group, Line, Text } from "react-konva";
import type { KonvaEventObject } from "konva/lib/Node";
import type { Photo } from "@forensic/shared";

/**
 * Photo pin on the floor plan canvas — a small numbered dot at
 * `(planPixelX, planPixelY)` with an optional heading arrow if the
 * photo carries a `headingDegrees`. Click handler is wired up so a
 * parent can open the preview panel at that photo's index.
 *
 * When `onDragEnd` is provided, the pin becomes draggable. Konva
 * distinguishes a click from a drag by movement threshold — a tap
 * fires `onClick`, a drag fires `onDragEnd`. Caller is responsible
 * for persisting the new position via the manifest PUT.
 *
 * Coordinates are plan-image pixels — identical units to what iOS
 * stores, so the same pin renders in the same place on both
 * platforms.
 *
 * "More photos here" indicator (Build #5.27.1): when `hasMore` is
 * true, a black band strokes the bubble's outer rim — same visual
 * iOS uses (see PlanViewerView.swift `bubble(for:radius:)`). It
 * signals "this pin represents > 1 photo" without committing to a
 * specific count. Two ways a pin can be in that state, both surfaced
 * via the same band so the user doesn't need to mentally model the
 * distinction:
 *   - iOS photo-group lead: this is the primary of a `groupID` and
 *     N-1 other photos in the same group sit behind it.
 *   - Spatial cluster rep: multiple unrelated primaries fell within
 *     a bubble-radius of each other on the plan; this pin stands in
 *     for all of them at the cluster centroid.
 * Click → caller's `onClick` opens either the preview panel (single
 * group lead) or the cluster picker popover (spatial cluster).
 */
interface Props {
  photo: Photo;
  /**
   * When true, render a black band around the bubble's outer rim to
   * indicate "more than one photo at this location" — whether
   * because of an iOS group, a spatial cluster, or both. No count is
   * shown; the count (if any) is surfaced in the click target. Build
   * #5.27.1 replaced the previous orange +N badge with this band.
   */
  hasMore?: boolean;
  onClick?: () => void;
  onDragEnd?: (newPlanPixelX: number, newPlanPixelY: number) => void;
  highlighted?: boolean;
  /**
   * Uniform scale factor for the pin's visual footprint (radius,
   * badge, text). 1.0 is the default size; the toolbar +/- buttons
   * adjust this so engineers can crank it up on a dense plan or
   * shrink it for a busy one. Plan-pixel coordinates are unaffected
   * — only the rendered geometry scales (Build #5.26.1).
   */
  scale?: number;
  /**
   * Override the position the pin renders at, in plan pixels. Used
   * by spatial clustering: a cluster representative renders at the
   * cluster centroid, not at the lead photo's actual position. When
   * undefined the pin renders at `photo.planPixelX/Y` as before.
   */
  renderX?: number;
  renderY?: number;
  /**
   * When true the pin's heading arrow is suppressed. Used for
   * spatial cluster reps where the cluster members can have wildly
   * different bearings and rendering the lead's would mislead.
   */
  suppressHeadingArrow?: boolean;
  /**
   * Pin fill color (Build #6.26.1 — plan color modes). The caller
   * resolves the active mode (status / bucket / primaryTag) into a
   * concrete color via `pinColorFor`; default is the legacy blue.
   * `highlighted` still wins (amber) so the selected pin stays
   * findable in any mode.
   */
  fillColor?: string;
}

const BASE_HEADING_LENGTH = 22;
const BASE_PIN_RADIUS = 10;
const BASE_FONT_SIZE = 11;

export function PhotoPin({
  photo,
  hasMore = false,
  onClick,
  onDragEnd,
  highlighted,
  scale = 1,
  renderX,
  renderY,
  suppressHeadingArrow = false,
  fillColor = "#3b82f6",
}: Props) {
  const x = renderX ?? photo.planPixelX;
  const y = renderY ?? photo.planPixelY;
  if (x == null || y == null) return null;

  // Scale every visual dimension uniformly. Plan-pixel x/y unchanged.
  const HEADING_LENGTH = BASE_HEADING_LENGTH * scale;
  const PIN_RADIUS = BASE_PIN_RADIUS * scale;
  const FONT_SIZE = BASE_FONT_SIZE * scale;
  // Band width matches iOS's `max(2, radius * 0.18)`. It's an inner
  // strokeBorder (Konva: stroke + strokeWidth on a Circle at PIN_RADIUS,
  // since strokeAlign isn't on Konva — we adjust the visible radius
  // when the band is on so the band sits inside the fill rather than
  // extending outside it).
  const BAND_WIDTH = Math.max(2, PIN_RADIUS * 0.18);

  const heading = suppressHeadingArrow ? null : photo.headingDegrees;
  let arrowEndX: number | null = null;
  let arrowEndY: number | null = null;
  if (heading != null) {
    const rad = ((heading - 90) * Math.PI) / 180;
    arrowEndX = HEADING_LENGTH * Math.cos(rad);
    arrowEndY = HEADING_LENGTH * Math.sin(rad);
  }

  return (
    <Group
      x={x}
      y={y}
      // Stop click/tap from bubbling up to the Stage. Without this,
      // a click on a pin while distress mode is on would ALSO fire
      // the Stage's onClick — which would then try to place a new
      // distress mark at the pin's location (Build #5.24.1 fix).
      onClick={
        onClick
          ? (e: KonvaEventObject<MouseEvent>) => {
              e.cancelBubble = true;
              onClick();
            }
          : undefined
      }
      onTap={
        onClick
          ? (e: KonvaEventObject<TouchEvent>) => {
              e.cancelBubble = true;
              onClick();
            }
          : undefined
      }
      // Stroke-drawing in distress mode listens to mousedown on the
      // Stage; stop the bubble here so mousedown on a pin doesn't
      // also start a stroke at the pin's location.
      onMouseDown={(e: KonvaEventObject<MouseEvent>) => {
        e.cancelBubble = true;
      }}
      onTouchStart={(e: KonvaEventObject<TouchEvent>) => {
        e.cancelBubble = true;
      }}
      // When draggable, Konva fires onClick on a simple tap and
      // onDragEnd on a click-and-drag. Both handlers can coexist;
      // Konva picks whichever the gesture matches based on its
      // built-in drag-distance threshold.
      draggable={onDragEnd != null}
      onDragEnd={(e: KonvaEventObject<DragEvent>) => {
        onDragEnd?.(e.target.x(), e.target.y());
        // After dropping, the pointer is still over the pin — restore
        // the "move" affordance (drag end can reset it to default).
        const container = e.target.getStage()?.container();
        if (container) container.style.cursor = "move";
      }}
      onMouseEnter={(e: KonvaEventObject<MouseEvent>) => {
        const container = e.target.getStage()?.container();
        if (!container) return;
        container.style.cursor =
          onDragEnd != null ? "move" : onClick != null ? "zoom-in" : "default";
      }}
      onMouseLeave={(e: KonvaEventObject<MouseEvent>) => {
        const container = e.target.getStage()?.container();
        if (container) container.style.cursor = "grab";
      }}
      listening={onClick != null || onDragEnd != null}
    >
      {arrowEndX != null && arrowEndY != null && (
        <Line
          points={[0, 0, arrowEndX, arrowEndY]}
          stroke={highlighted ? "#fbbf24" : fillColor}
          strokeWidth={3 * scale}
          lineCap="round"
        />
      )}
      {/* Bubble fill. White outer ring is the standard pin stroke;
          when hasMore is true an extra inner black band is drawn on
          top of the fill to mark the bubble as a group / cluster
          lead, matching iOS PlanViewerView.swift. */}
      <Circle
        radius={PIN_RADIUS}
        fill={highlighted ? "#fbbf24" : fillColor}
        stroke="white"
        strokeWidth={2 * scale}
      />
      {hasMore && (
        <Circle
          // Inner band: draw at radius - bandWidth/2 with strokeWidth
          // = bandWidth so the band's outer edge meets the white ring
          // and its inner edge eats into the fill — exact mirror of
          // iOS's `.strokeBorder(Color.black, lineWidth: ...)`.
          radius={PIN_RADIUS - BAND_WIDTH / 2}
          stroke="black"
          strokeWidth={BAND_WIDTH}
          listening={false}
        />
      )}
      <Text
        text={String(photo.sequenceNumber)}
        fontSize={FONT_SIZE}
        fontStyle="bold"
        fill="white"
        x={-PIN_RADIUS}
        y={-FONT_SIZE * 0.55}
        width={PIN_RADIUS * 2}
        align="center"
        listening={false}
      />
    </Group>
  );
}
