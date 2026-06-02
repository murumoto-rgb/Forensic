import { Circle, Line, Group } from "react-konva";
import type { KonvaEventObject } from "konva/lib/Node";
import type { DistressMark } from "@forensic/shared";

/**
 * Render a single distress mark on the floor plan canvas. Three of
 * the four `DistressKind` values are point distress (a single
 * location); the fourth — `crackFloor` — is a freeform stroke with
 * many `(x, y)` points.
 *
 * `points` is typed as `unknown[]` in the shared schema because
 * Apple's CGPoint encodes as `[x, y]` arrays (see Build #1.1.5).
 * We accept both shapes here defensively: `[x, y]` array or
 * `{ x, y }` object. New marks written from web use `[x, y]` to
 * match iOS's encoder exactly so round-trips are lossless.
 *
 * Click handler: when `editable` is true, the glyph listens for
 * clicks and forwards them to `onClick`. The parent uses this to
 * open an editor (change kind / note / delete). When `editable` is
 * false (the default), the glyph is non-interactive so it can't
 * swallow clicks intended for pin placement / pan.
 */
interface Props {
  mark: DistressMark;
  editable?: boolean;
  onClick?: () => void;
}

const COLORS: Record<string, string> = {
  outOfPlumbDoor: "#ef4444", // red-500
  doorNotLatching: "#f97316", // orange-500
  crackGradeBeam: "#a855f7", // purple-500
  crackFloor: "#fb923c", // orange-400 (stroke)
};

function parsePoint(p: unknown): { x: number; y: number } | null {
  if (Array.isArray(p) && p.length >= 2 && typeof p[0] === "number" && typeof p[1] === "number") {
    return { x: p[0], y: p[1] };
  }
  if (typeof p === "object" && p !== null) {
    const obj = p as Record<string, unknown>;
    if (typeof obj.x === "number" && typeof obj.y === "number") {
      return { x: obj.x, y: obj.y };
    }
  }
  return null;
}

export function DistressGlyph({ mark, editable, onClick }: Props) {
  const color = COLORS[mark.kind] ?? "#ef4444";
  const parsed = mark.points
    .map(parsePoint)
    .filter((p): p is { x: number; y: number } => p !== null);

  // Konva propagates clicks up the tree; stop the bubble at the
  // glyph so the Stage's click handler (which would try to place a
  // new distress mark) doesn't also fire from the same click.
  // Accepts the MouseEvent | TouchEvent union so the same body backs
  // both `onClick` (mouse) and `onTap` (touch).
  function handleClick(
    e: KonvaEventObject<MouseEvent> | KonvaEventObject<TouchEvent>
  ) {
    if (!onClick) return;
    e.cancelBubble = true;
    onClick();
  }

  function handleMouseEnter(e: KonvaEventObject<MouseEvent>) {
    if (!editable) return;
    const container = e.target.getStage()?.container();
    if (container) container.style.cursor = "pointer";
  }
  function handleMouseLeave(e: KonvaEventObject<MouseEvent>) {
    if (!editable) return;
    const container = e.target.getStage()?.container();
    if (container) container.style.cursor = "crosshair";
  }

  // crackFloor renders as a connected stroke; everything else is a
  // single dot at the first point.
  if (mark.kind === "crackFloor" && parsed.length >= 2) {
    const flat: number[] = [];
    for (const p of parsed) {
      flat.push(p.x, p.y);
    }
    // Wrap the Line in a Group so the click target has consistent
    // hit-testing across kinds. `hitStrokeWidth` widens the
    // clickable area beyond the visible stroke for usability.
    return (
      <Group
        onClick={editable ? (e) => handleClick(e) : undefined}
        onTap={editable ? (e) => handleClick(e) : undefined}
        onMouseEnter={editable ? handleMouseEnter : undefined}
        onMouseLeave={editable ? handleMouseLeave : undefined}
        listening={editable === true}
      >
        <Line
          points={flat}
          stroke={color}
          strokeWidth={4}
          lineCap="round"
          lineJoin="round"
          opacity={0.9}
          hitStrokeWidth={editable ? 16 : undefined}
        />
      </Group>
    );
  }

  const first = parsed[0];
  if (!first) return null;

  return (
    <Group
      x={first.x}
      y={first.y}
      onClick={editable ? handleClick : undefined}
      onTap={editable ? handleClick : undefined}
      onMouseEnter={editable ? handleMouseEnter : undefined}
      onMouseLeave={editable ? handleMouseLeave : undefined}
      listening={editable === true}
    >
      <Circle radius={10} fill={color} opacity={0.85} />
      <Circle radius={10} stroke="white" strokeWidth={2} opacity={0.9} />
    </Group>
  );
}
