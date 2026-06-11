import type { FloorPlan } from "@forensic/shared";

/**
 * Pixel ↔ local-feet conversion for floor-plan placement.
 *
 * Mirrors iOS `ProjectStore.setPhotoLocation` /
 * `ProjectStore.setPhotoFloorPlan`. A photo's canonical
 * real-world position on a plan is `(localXFeet, localYFeet)`;
 * the pixel coords are a per-plan projection of that position
 * onto the current image. Whenever the plan changes (move-to-
 * level, calibration edit), pixels are re-derived from feet.
 *
 * Formula matches iOS exactly:
 *   lx = (pxX − anchorPixelX) / pixelsPerFoot
 *   px = anchorPixelX + lx * pixelsPerFoot
 *
 * `FloorPlan.anchorLocalXFeet` / `anchorLocalYFeet` exist on the
 * wire but are unused by either platform's conversion today —
 * iOS treats local coords as a delta from the anchor pixel with
 * the anchor's local feet implicitly zero. Carried on the wire
 * for future use, not folded into the formula here.
 *
 * Returns `null` when the plan is uncalibrated (`pixelsPerFoot
 * <= 0`) so callers preserve existing values rather than emit
 * NaN / Infinity.
 */

export interface PixelPoint {
  pxX: number;
  pxY: number;
}

export interface LocalFeetPoint {
  lx: number;
  ly: number;
}

export function pixelsToLocalFeet(
  plan: FloorPlan,
  pxX: number,
  pxY: number,
): LocalFeetPoint | null {
  if (!(plan.pixelsPerFoot > 0)) return null;
  return {
    lx: (pxX - plan.anchorPixelX) / plan.pixelsPerFoot,
    ly: (pxY - plan.anchorPixelY) / plan.pixelsPerFoot,
  };
}

export function localFeetToPixels(
  plan: FloorPlan,
  lx: number,
  ly: number,
): PixelPoint | null {
  if (!(plan.pixelsPerFoot > 0)) return null;
  return {
    pxX: plan.anchorPixelX + lx * plan.pixelsPerFoot,
    pxY: plan.anchorPixelY + ly * plan.pixelsPerFoot,
  };
}
