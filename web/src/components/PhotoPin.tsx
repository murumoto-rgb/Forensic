import { Circle, Group, Line, Text } from "react-konva";
import type { Photo } from "@forensic/shared";

/**
 * Photo pin on the floor plan canvas — a small numbered dot at
 * `(planPixelX, planPixelY)` with an optional heading arrow if the
 * photo carries a `headingDegrees`. Click handler is wired up so a
 * parent can open the lightbox at that photo's index.
 *
 * Coordinates are plan-image pixels — identical units to what iOS
 * stores, so the same pin renders in the same place on both
 * platforms.
 */
interface Props {
  photo: Photo;
  onClick?: () => void;
  highlighted?: boolean;
}

const HEADING_LENGTH = 22;
const PIN_RADIUS = 10;

export function PhotoPin({ photo, onClick, highlighted }: Props) {
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
      listening={onClick != null}
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
    </Group>
  );
}
