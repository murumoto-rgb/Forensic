import { Circle, Line, Group } from "react-konva";
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
 * `{ x, y }` object. Phase 3 PR-B will tighten this to a
 * structured `{ x, y }` object in the manifest.
 */
interface Props {
  mark: DistressMark;
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

export function DistressGlyph({ mark }: Props) {
  const color = COLORS[mark.kind] ?? "#ef4444";
  const parsed = mark.points
    .map(parsePoint)
    .filter((p): p is { x: number; y: number } => p !== null);

  // crackFloor renders as a connected stroke; everything else is a
  // single dot at the first point.
  if (mark.kind === "crackFloor" && parsed.length >= 2) {
    const flat: number[] = [];
    for (const p of parsed) {
      flat.push(p.x, p.y);
    }
    return (
      <Line
        points={flat}
        stroke={color}
        strokeWidth={4}
        lineCap="round"
        lineJoin="round"
        opacity={0.9}
      />
    );
  }

  const first = parsed[0];
  if (!first) return null;

  return (
    <Group x={first.x} y={first.y}>
      <Circle radius={10} fill={color} opacity={0.85} />
      <Circle radius={10} stroke="white" strokeWidth={2} opacity={0.9} />
    </Group>
  );
}
