import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import {
  DEFAULT_PIN_COLOR,
  NEUTRAL_PIN_COLOR,
  pinColorFor,
} from "../src/planMarkerColors.ts";
import type { Photo, Project } from "../src/manifest.ts";

function photo(partial: Partial<Photo> = {}): Photo {
  return {
    id: "p1",
    sequenceNumber: 1,
    timestamp: "2026-01-01T00:00:00Z",
    imageFilename: "p1.jpg",
    thumbnailFilename: null,
    floorPlanID: null,
    localXFeet: null,
    localYFeet: null,
    planPixelX: null,
    planPixelY: null,
    headingDegrees: null,
    positionSource: "none",
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
    ...partial,
  };
}

function project(partial: Partial<Project> = {}): Project {
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
    photos: [],
    trashedPhotos: [],
    floorPlans: [],
    activeFloorPlanID: null,
    folderName: null,
    aiInstructions: null,
    buckets: [],
    tagSelection: null,
    aiExtraVocabulary: null,
    inspectionChecklist: [],
    inspectionSessions: [],
    reportLayout: null,
    manifestSchemaVersion: 4,
    ...partial,
  };
}

describe("pinColorFor", () => {
  it("uses the web default in status mode", () => {
    assert.equal(pinColorFor(photo(), "status", project()), DEFAULT_PIN_COLOR);
  });

  it("uses the bucket hex when the photo is bucketed", () => {
    const p = project({
      buckets: [
        {
          id: "b1",
          name: "Foundation",
          colorHex: "#c45c26",
          sortOrder: 0,
          libraryCategoryID: null,
        },
      ],
    });
    assert.equal(
      pinColorFor(photo({ bucketID: "b1" }), "bucket", p),
      "#c45c26"
    );
  });

  it("falls back to neutral when the bucket is missing", () => {
    assert.equal(
      pinColorFor(photo({ bucketID: "gone" }), "bucket", project()),
      NEUTRAL_PIN_COLOR
    );
  });

  it("hashes the primary tag to a stable hsl color", () => {
    const tagged = photo({
      tags: [{ label: "Crack", confidence: 1, parentTag: "Foundation / Grade Beam" }],
    });
    const a = pinColorFor(tagged, "primaryTag", project());
    const b = pinColorFor(tagged, "primaryTag", project());
    assert.match(a, /^hsl\(\d+, 78%, 52%\)$/);
    assert.equal(a, b);
  });
});
