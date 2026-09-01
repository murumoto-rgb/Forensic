import type { FloorPlan, Photo, Project } from "@forensic/shared";

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

/**
 * Re-calibrate an existing plan (Build #6.39.1).
 *
 * Pin and distress coordinates are stored in plan-image pixels, so
 * they stay on the same crack when scale/origin/north change. Feet
 * (`localXFeet/Y`) re-derive from the new calibration so move-to-
 * level and PDF distances stay honest. Photos without pixel coords
 * are left untouched.
 */
export interface PlanRecalibration {
  pixelsPerFoot: number;
  calibrationDistanceFeet: number;
  anchorPixelX: number;
  anchorPixelY: number;
  northDeg: number;
  label?: string;
}

export function applyPlanRecalibration(
  project: Project,
  planId: string,
  cal: PlanRecalibration
): Project {
  const planIdx = project.floorPlans.findIndex((p) => p.id === planId);
  if (planIdx === -1) return project;
  const existing = project.floorPlans[planIdx]!;
  const updatedPlan: FloorPlan = {
    ...existing,
    pixelsPerFoot: cal.pixelsPerFoot,
    calibrationDistanceFeet: cal.calibrationDistanceFeet,
    anchorPixelX: cal.anchorPixelX,
    anchorPixelY: cal.anchorPixelY,
    northDeg: cal.northDeg,
    label: cal.label?.trim() ? cal.label.trim() : existing.label,
  };
  const plans = [...project.floorPlans];
  plans[planIdx] = updatedPlan;

  const remap = (photo: Photo): Photo => {
    if (photo.floorPlanID !== planId) return photo;
    if (photo.planPixelX == null || photo.planPixelY == null) return photo;
    const feet = pixelsToLocalFeet(
      updatedPlan,
      photo.planPixelX,
      photo.planPixelY
    );
    if (!feet) return photo;
    return { ...photo, localXFeet: feet.lx, localYFeet: feet.ly };
  };

  return {
    ...project,
    floorPlans: plans,
    photos: project.photos.map(remap),
    trashedPhotos: project.trashedPhotos.map(remap),
  };
}
