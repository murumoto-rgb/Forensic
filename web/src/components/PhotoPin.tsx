import { Circle, Group, Line, Text } from "react-konva";
import type { KonvaEventObject } from "konva/lib/Node";
import type { Photo } from "@forensic/shared";

/**
 * Photo pin on the floor plan canvas — a small numbered dot at
 * `(planPixelX, planPixelY)` with an optional heading arrow if the
 * photo carries a `headingDegrees`. Click handler is wired up so a
 * parent can open the lightbox at that photo's index.
 *
 * When `onDragEnd` is provided, the pin becomes draggable. Konva
 * distinguishes a click from a drag by movement threshold — a tap
 * fires `onClick`, a drag fires `onDragEnd`. Caller is responsible
 * for persisting the new position via the manifest PUT.
 *
 * Coordinates are plan-image pixels — identical units to what iOS
 * stores, so the same pin renders in the same place on both
 * platforms.
 */
interface Props {
  photo: Photo;
  /**
   * Total number of photos in the same group (including this primary).
   * When > 1, a small "+N" badge renders on the upper-right of the
   * pin so the user can see at a glance that this position has
   * additional reshoots stacked underneath. Defaults to 1 (single
   * photo).
   */
  groupSize?: number;
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
   * Override the badge text + count. Used by spatial clustering to
   * show a "+N other pins here" indicator (different from the
   * per-group `groupSize` count). When undefined the existing
   * `groupSize` badge behavior applies.
   */
  badgeOverride?: { count: number } | null;
}

const BASE_HEADING_LENGTH = 22;
const BASE_PIN_RADIUS = 10;
const BASE_BADGE_RADIUS = 7;
const BASE_FONT_SIZE = 11;
const BASE_BADGE_FONT_SIZE = 9;

export function PhotoPin({
  photo,
  groupSize = 1,
  onClick,
  onDragEnd,
  highlighted,
  scale = 1,
  renderX,
  renderY,
  badgeOverride,
}: Props) {
  const x = renderX ?? photo.planPixelX;
  const y = renderY ?? photo.planPixelY;
  if (x == null || y == null) return null;

  // Scale every visual dimension uniformly. Plan-pixel x/y unchanged.
  const HEADING_LENGTH = BASE_HEADING_LENGTH * scale;
  const PIN_RADIUS = BASE_PIN_RADIUS * scale;
  const BADGE_RADIUS = BASE_BADGE_RADIUS * scale;
  const BADGE_OFFSET_X = PIN_RADIUS - 1 * scale;
  const BADGE_OFFSET_Y = -PIN_RADIUS + 1 * scale;
  const FONT_SIZE = BASE_FONT_SIZE * scale;
  const BADGE_FONT_SIZE = BASE_BADGE_FONT_SIZE * scale;

  // Heading vector: 0° is north (up on screen, -y), 90° is east
  // (right, +x). Same convention as iOS. Suppress the arrow when this
  // pin is acting as a spatial cluster representative — the cluster
  // members can have wildly different bearings, and rendering one
  // would mislead the engineer about the others.
  const heading = badgeOverride ? null : photo.headingDegrees;
  let arrowEndX: number | null = null;
  let arrowEndY: number | null = null;
  if (heading != null) {
    const rad = ((heading - 90) * Math.PI) / 180;
    arrowEndX = HEADING_LENGTH * Math.cos(rad);
    arrowEndY = HEADING_LENGTH * Math.sin(rad);
  }

  // Effective badge: cluster override wins over the existing groupSize
  // badge so the user sees one consistent indicator at a time.
  const effectiveBadgeCount =
    badgeOverride?.count ?? (groupSize > 1 ? groupSize - 1 : 0);
  const showBadge = effectiveBadgeCount > 0;

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
      // Cursor affordance: show the move cursor over a draggable pin,
      // and the zoom-in cursor over a click-only pin (opens lightbox).
      // On leave, hand the cursor back to the stage's "grab" (pan).
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
          stroke={highlighted ? "#fbbf24" : "#3b82f6"}
          strokeWidth={3 * scale}
          lineCap="round"
        />
      )}
      <Circle
        radius={PIN_RADIUS}
        fill={highlighted ? "#fbbf24" : "#3b82f6"}
        stroke="white"
        strokeWidth={2 * scale}
      />
      <Text
        text={String(photo.sequenceNumber)}
        fontSize={FONT_SIZE}
        fontStyle="bold"
        fill="white"
        // Center the number inside the pin. Konva renders text from
        // the top-left, so offset by half the rendered size.
        x={-PIN_RADIUS}
        y={-FONT_SIZE * 0.55}
        width={PIN_RADIUS * 2}
        align="center"
      />
      {showBadge && (
        <>
          <Circle
            x={BADGE_OFFSET_X}
            y={BADGE_OFFSET_Y}
            radius={BADGE_RADIUS}
            fill="#f59e0b"
            stroke="white"
            strokeWidth={1.5 * scale}
          />
          <Text
            text={`+${effectiveBadgeCount}`}
            fontSize={BADGE_FONT_SIZE}
            fontStyle="bold"
            fill="white"
            x={BADGE_OFFSET_X - BADGE_RADIUS}
            y={BADGE_OFFSET_Y - BADGE_FONT_SIZE * 0.5}
            width={BADGE_RADIUS * 2}
            align="center"
          />
        </>
      )}
    </Group>
  );
}
