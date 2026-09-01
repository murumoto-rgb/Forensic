/**
 * Floor-plan pin fill for the active color mode (Build #6.26.1,
 * shared in #6.39.1 so the web canvas and the server PDF use the
 * same function).
 *
 *  - "status"     → web's established blue. iOS's on-screen/PDF
 *                   default stays its historical green — each
 *                   native surface keeps that look; this helper
 *                   is the office/web exporter.
 *  - "bucket"     → the photo's bucket `colorHex`, neutral grey
 *                   when unbucketed or the bucket was deleted.
 *  - "primaryTag" → a deterministic hue from the first primary
 *                   tag label. iOS spaces hues by controlled-
 *                   vocabulary rank; web/server hash the label.
 *                   Same grouping, different palette — documented
 *                   in the parity matrix.
 */

import type { Photo, Project } from "./manifest.ts";

export type PlanColorMode = "status" | "bucket" | "primaryTag";

export const PLAN_COLOR_MODES: PlanColorMode[] = [
  "status",
  "bucket",
  "primaryTag",
];

export const DEFAULT_PIN_COLOR = "#3b82f6";
export const NEUTRAL_PIN_COLOR = "#8a8a8a";

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

function primaryLabelFor(photo: Photo): string | null {
  for (const tag of photo.tags) {
    const candidate = tag.parentTag ?? tag.label;
    if (candidate.trim().length > 0) return candidate.toLowerCase();
  }
  return null;
}

function hueColor(label: string): string {
  let hash = 0;
  for (let i = 0; i < label.length; i++) {
    hash = (hash * 31 + label.charCodeAt(i)) >>> 0;
  }
  const hue = (hash * 0.61803398875) % 1;
  return `hsl(${Math.round(hue * 360)}, 78%, 52%)`;
}
