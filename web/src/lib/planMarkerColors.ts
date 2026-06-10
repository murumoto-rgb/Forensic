import type { Photo, Project } from "@forensic/shared";
import type { PlanColorMode } from "./useUserPrefs";

/**
 * Resolve a floor-plan pin's fill color for the active color mode
 * (Build #6.26.1) — the web counterpart of iOS's `PlanMarkerColors`.
 *
 *  - "status"     → the legacy single color (web's standard blue;
 *                   iOS's default is its historical green — each
 *                   platform keeps its established default look).
 *  - "bucket"     → the photo's bucket `colorHex`, neutral grey when
 *                   unbucketed or the bucket was deleted.
 *  - "primaryTag" → a deterministic hue derived from the photo's
 *                   first primary tag label. iOS spaces hues by the
 *                   controlled-vocabulary rank; web has no bundled
 *                   vocabulary module, so it hashes the label to a
 *                   hue instead — stable across sessions and
 *                   distinct between primaries, though the exact
 *                   colors differ from iOS's (documented in the
 *                   parity matrix).
 */
export const DEFAULT_PIN_COLOR = "#3b82f6";
const NEUTRAL_PIN_COLOR = "#8a8a8a";

export function pinColorFor(
  photo: Photo,
  mode: PlanColorMode,
  project: Project
): string {
  switch (mode) {
    case "status":
      return DEFAULT_PIN_COLOR;
    case "bucket": {
      const bucket = photo.bucketID
        ? project.buckets.find((b) => b.id === photo.bucketID)
        : undefined;
      return bucket?.colorHex ?? NEUTRAL_PIN_COLOR;
    }
    case "primaryTag": {
      const primary = primaryLabelFor(photo);
      if (!primary) return NEUTRAL_PIN_COLOR;
      return hueColor(primary);
    }
  }
}

/** First primary on the photo: a standalone primary tag, or the
 *  parent of the first secondary. Mirrors iOS's resolution order
 *  closely enough for visual grouping. */
function primaryLabelFor(photo: Photo): string | null {
  for (const tag of photo.tags) {
    const candidate = tag.parentTag ?? tag.label;
    if (candidate.trim().length > 0) return candidate.toLowerCase();
  }
  return null;
}

/** Deterministic label → HSL color. Golden-ratio hue stepping off a
 *  simple string hash gives well-separated hues for nearby labels. */
function hueColor(label: string): string {
  let hash = 0;
  for (let i = 0; i < label.length; i++) {
    hash = (hash * 31 + label.charCodeAt(i)) >>> 0;
  }
  const hue = (hash * 0.61803398875) % 1;
  return `hsl(${Math.round(hue * 360)}, 78%, 52%)`;
}
