/**
 * Zod schemas for the manifest models. The server uses these to
 * validate incoming writes; the web app uses them to validate
 * responses from the server.
 *
 * Each schema's shape must match the corresponding TypeScript type in
 * `manifest.ts` exactly — the parity contract test checks both
 * structural agreement and that every model has a zod schema.
 */

import { z } from "zod";

const isoDate = z.string().datetime({ offset: true });
const uuid = z.string().uuid();

export const PositionSourceSchema = z.enum(["manual", "gps", "none"]);
export const FlashModeSchema = z.enum(["auto", "on", "off"]);
export const TagSourceSchema = z.enum(["vision", "claude"]);
export const DistressKindSchema = z.enum([
  "outOfPlumbDoor",
  "doorNotLatching",
  "crackGradeBeam",
  "crackFloor",
]);

// Constrained-string enums: kept as bare strings on the wire so unknown
// model outputs survive a round-trip. Validation lives at the call
// site, not in the type.
export const ScalePresentSchema = z.string();
export const RecommendedUseSchema = z.string();

export const TagSchema = z.object({
  label: z.string(),
  confidence: z.number().min(0).max(1),
  parentTag: z.string().nullable(),
});

export const TagSuggestionSchema = z.object({
  label: z.string(),
  confidence: z.number().min(0).max(1),
  source: TagSourceSchema,
  parentTag: z.string().nullable(),
});

export const AIPhotoAnalysisSchema = z.object({
  photoID: z.string(),
  primaryTags: z.array(z.string()),
  secondaryTagsByPrimary: z.record(z.string(), z.array(z.string())),
  tagConfidences: z.record(z.string(), z.number()),
  locationInferred: z.string(),
  scalePresent: ScalePresentSchema,
  measurementVisible: z.string().nullable(),
  summaryObservation: z.string(),
  captionDraft: z.string(),
  recommendedUse: RecommendedUseSchema,
  reviewerFlag: z.string(),
  validationErrors: z.array(z.string()),
  rawResponse: z.string().nullable(),
  parseFailed: z.boolean(),
});

export const PhotoSchema = z.object({
  id: uuid,
  sequenceNumber: z.number().int(),
  timestamp: isoDate,
  imageFilename: z.string(),
  thumbnailFilename: z.string().nullable(),

  floorPlanID: uuid.nullable(),
  localXFeet: z.number().nullable(),
  localYFeet: z.number().nullable(),
  planPixelX: z.number().nullable(),
  planPixelY: z.number().nullable(),
  headingDegrees: z.number().nullable(),

  positionSource: PositionSourceSchema,
  groupID: uuid.nullable(),
  isPrimary: z.boolean(),
  cameraZoom: z.number(),
  lensName: z.string().nullable(),
  flashMode: FlashModeSchema,

  aiDescription: z.string().nullable(),
  aiSeverity: z.string().nullable(),
  aiObservation: z.string().nullable(),
  aiFollowUp: z.string().nullable(),
  aiAnalysis: AIPhotoAnalysisSchema.nullable(),

  tags: z.array(TagSchema),
  pendingSuggestions: z.array(TagSuggestionSchema),

  bucketID: uuid.nullable(),
  markupOverlayFilename: z.string().nullable(),
  markupDrawingFilename: z.string().nullable(),
  reshootsPhotoID: uuid.nullable(),
  isFavorite: z.boolean(),
  trashedAt: isoDate.nullable(),
  userCaption: z.string().nullable(),
  userObservation: z.string().nullable(),
  previewRotation: z.number().int(),
});

export const DistressMarkSchema = z.object({
  id: uuid,
  kind: DistressKindSchema,
  // Opaque pass-through for Phase 0 — see comment on `DistressMark`
  // in `manifest.ts`. Switches to a structured `{ x, y }` shape in
  // Phase 3 when distress sync to web goes live.
  points: z.array(z.record(z.string(), z.unknown())),
  note: z.string().nullable(),
  createdAt: isoDate,
});

export const FloorPlanSchema = z.object({
  id: uuid,
  label: z.string(),
  imageFilename: z.string(),
  pixelsPerFoot: z.number(),
  calibrationDistanceFeet: z.number(),
  anchorPixelX: z.number(),
  anchorPixelY: z.number(),
  anchorLocalXFeet: z.number(),
  anchorLocalYFeet: z.number(),
  northDeg: z.number(),
  distress: z.array(DistressMarkSchema),
});

export const ProjectGPSSchema = z.object({
  latitude: z.number(),
  longitude: z.number(),
  altitude: z.number().nullable(),
  accuracyFeet: z.number().nullable(),
  timestamp: isoDate,
});

export const BucketSchema = z.object({
  id: uuid,
  name: z.string(),
  colorHex: z.string().regex(/^#?[0-9a-fA-F]{6}$/),
  sortOrder: z.number().int(),
  libraryCategoryID: uuid.nullable(),
});

export const ProjectTagSelectionSchema = z.object({
  contextIDs: z.array(uuid),
  primariesByContext: z.record(uuid, z.array(uuid)),
  deselectedSecondariesByPrimary: z.record(uuid, z.array(uuid)),
});

export const ProjectExtraVocabularySchema = z.object({
  primaries: z.array(z.record(z.string(), z.unknown())),
});

export const ProjectSchema = z.object({
  id: uuid,
  name: z.string(),
  createdAt: isoDate,
  startedAt: isoDate.nullable(),
  lastResumedAt: isoDate.nullable(),
  lastStoppedAt: isoDate.nullable(),
  stopped: z.boolean(),
  projectGPS: ProjectGPSSchema.nullable(),
  projectAddress: z.string().nullable(),
  photos: z.array(PhotoSchema),
  trashedPhotos: z.array(PhotoSchema),
  floorPlans: z.array(FloorPlanSchema),
  activeFloorPlanID: uuid.nullable(),
  folderName: z.string().nullable(),
  aiInstructions: z.string().nullable(),
  buckets: z.array(BucketSchema),
  tagSelection: ProjectTagSelectionSchema.nullable(),
  aiExtraVocabulary: ProjectExtraVocabularySchema.nullable(),
  manifestSchemaVersion: z.number().int().min(1),
});
