import { describe, expect, it } from "vitest";
import type { FloorPlan, Photo, Project } from "@forensic/shared";
import { applyPlanRecalibration, pixelsToLocalFeet } from "./planCoords";

function plan(over: Partial<FloorPlan> = {}): FloorPlan {
  return {
    id: "plan-1",
    label: "Level 1",
    imageFilename: "plan-1.jpg",
    pixelsPerFoot: 10,
    calibrationDistanceFeet: 10,
    anchorPixelX: 0,
    anchorPixelY: 0,
    anchorLocalXFeet: 0,
    anchorLocalYFeet: 0,
    northDeg: 0,
    distress: [],
    ...over,
  };
}

function photo(over: Partial<Photo> = {}): Photo {
  return {
    id: "photo-1",
    sequenceNumber: 1,
    timestamp: "2026-01-01T00:00:00Z",
    imageFilename: "photo-1.jpg",
    thumbnailFilename: null,
    floorPlanID: "plan-1",
    localXFeet: 10,
    localYFeet: 5,
    planPixelX: 100,
    planPixelY: 50,
    headingDegrees: null,
    positionSource: "manual",
    groupID: null,
    isPrimary: true,
    cameraZoom: 1,
    lensName: null,
    flashMode: "off",
    aiDescription: null,
    aiSeverity: null,
    aiObservation: null,
    aiFollowUp: null,
    aiAnalysis: null,
    tags: [],
    pendingSuggestions: [],
    bucketID: null,
    markupOverlayFilename: null,
    markupDrawingFilename: null,
    reshootsPhotoID: null,
    isFavorite: false,
    trashedAt: null,
    userCaption: null,
    userObservation: null,
    previewRotation: 0,
    ...over,
  };
}

function project(over: Partial<Project> = {}): Project {
  return {
    id: "proj",
    name: "Site",
    createdAt: "2026-01-01T00:00:00Z",
    startedAt: null,
    lastResumedAt: null,
    lastStoppedAt: null,
    stopped: false,
    isDeleted: false,
    isFrozen: false,
    projectGPS: null,
    projectAddress: null,
    photos: [photo()],
    trashedPhotos: [],
    floorPlans: [plan()],
    activeFloorPlanID: "plan-1",
    folderName: null,
    aiInstructions: null,
    buckets: [],
    tagSelection: null,
    aiExtraVocabulary: null,
    inspectionChecklist: [],
    inspectionSessions: [],
    reportLayout: null,
    manifestSchemaVersion: 4,
    ...over,
  };
}

describe("applyPlanRecalibration", () => {
  it("keeps pin pixels and re-derives feet from the new origin and scale", () => {
    const next = applyPlanRecalibration(project(), "plan-1", {
      pixelsPerFoot: 20,
      calibrationDistanceFeet: 5,
      anchorPixelX: 20,
      anchorPixelY: 10,
      northDeg: 90,
      label: "Level 1 recast",
    });
    const updated = next.floorPlans[0]!;
    expect(updated.pixelsPerFoot).toBe(20);
    expect(updated.anchorPixelX).toBe(20);
    expect(updated.northDeg).toBe(90);
    expect(updated.label).toBe("Level 1 recast");
    const placed = next.photos[0]!;
    expect(placed.planPixelX).toBe(100);
    expect(placed.planPixelY).toBe(50);
    expect(placed.localXFeet).toBeCloseTo((100 - 20) / 20);
    expect(placed.localYFeet).toBeCloseTo((50 - 10) / 20);
    const check = pixelsToLocalFeet(updated, 100, 50);
    expect(placed.localXFeet).toBeCloseTo(check!.lx);
    expect(placed.localYFeet).toBeCloseTo(check!.ly);
  });

  it("does not move photos on a different plan", () => {
    const other = photo({
      id: "photo-2",
      floorPlanID: "plan-2",
      planPixelX: 1,
      planPixelY: 1,
      localXFeet: 99,
      localYFeet: 99,
    });
    const next = applyPlanRecalibration(
      project({ photos: [photo(), other] }),
      "plan-1",
      {
        pixelsPerFoot: 20,
        calibrationDistanceFeet: 5,
        anchorPixelX: 0,
        anchorPixelY: 0,
        northDeg: 0,
      }
    );
    expect(next.photos[1]!.localXFeet).toBe(99);
    expect(next.photos[1]!.planPixelX).toBe(1);
  });
});
