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
}

const HEADING_LENGTH = 22;
const PIN_RADIUS = 10;
const BADGE_RADIUS = 7;
const BADGE_OFFSET_X = PIN_RADIUS - 1;
const BADGE_OFFSET_Y = -PIN_RADIUS + 1;

export function PhotoPin({
  photo,
  groupSize = 1,
  onClick,
  onDragEnd,
  highlighted,
}: Props) {
  if (photo.planPixelX == null || photo.planPixelY == null) {
    return null;
  }

  // Heading vector: 0° is north (up on screen, -y), 90° is east
  // (right, +x). Same convention as iOS.
  const heading = photo.headingDegrees;
  let arrowEndX: number | null = null;
  let arrowEndY: number | null = null;
  if (heading != null) {
    const rad = ((heading - 90) * Math.PI) / 180;
    arrowEndX = HEADING_LENGTH * Math.cos(rad);
    arrowEndY = HEADING_LENGTH * Math.sin(rad);
  }

  return (
    <Group
      x={photo.planPixelX}
      y={photo.planPixelY}
      onClick={onClick}
      onTap={onClick}
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
          strokeWidth={3}
          lineCap="round"
        />
      )}
      <Circle
        radius={PIN_RADIUS}
        fill={highlighted ? "#fbbf24" : "#3b82f6"}
        stroke="white"
        strokeWidth={2}
      />
      <Text
        text={String(photo.sequenceNumber)}
        fontSize={11}
        fontStyle="bold"
        fill="white"
        // Center the number inside the pin. Konva renders text from
        // the top-left, so offset by half the rendered size.
        x={-PIN_RADIUS}
        y={-6}
        width={PIN_RADIUS * 2}
        align="center"
      />
      {groupSize > 1 && (
        <>
          <Circle
            x={BADGE_OFFSET_X}
            y={BADGE_OFFSET_Y}
            radius={BADGE_RADIUS}
            fill="#f59e0b"
            stroke="white"
            strokeWidth={1.5}
          />
          <Text
            text={`+${groupSize - 1}`}
            fontSize={9}
            fontStyle="bold"
            fill="white"
            x={BADGE_OFFSET_X - BADGE_RADIUS}
            y={BADGE_OFFSET_Y - 4.5}
            width={BADGE_RADIUS * 2}
            align="center"
          />
        </>
      )}
    </Group>
  );
}
