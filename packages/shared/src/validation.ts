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

/**
 * Wraps a zod schema in "accept null OR missing, normalize to null".
 *
 * iOS encoders use `encodeIfPresent` for optional fields, which OMITS
 * the key when the value is nil. Plain `.nullable()` requires the
 * key to be present (as string or null) and rejects undefined /
 * missing. This helper allows either shape:
 *
 *   `{ "startedAt": "2026-05-28T11:23:00Z" }`  → "2026-…"
 *   `{ "startedAt": null }`                    → null
 *   `{}` (key missing)                          → null
 *
 * The `.transform(v => v ?? null)` normalizes undefined to null so
 * downstream code (database storage, response shape) sees a clean
 * `T | null` instead of `T | null | undefined`.
 *
 * The parity contract test's normalizer collapses `ZodEffects(
 * ZodOptional(ZodNullable<X>))` back to `nullable<X>` so the iOS-side
 * `T?` descriptor still matches.
 */
function nullable<T extends z.ZodTypeAny>(schema: T) {
  return schema
    .nullable()
    .optional()
    .transform((v) => v ?? null);
}

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
  parentTag: nullable(z.string()),
});

export const TagSuggestionSchema = z.object({
  label: z.string(),
  confidence: z.number().min(0).max(1),
  source: TagSourceSchema,
  parentTag: nullable(z.string()),
});

export const AIPhotoAnalysisSchema = z.object({
  photoID: z.string(),
  primaryTags: z.array(z.string()),
  secondaryTagsByPrimary: z.record(z.string(), z.array(z.string())),
  tagConfidences: z.record(z.string(), z.number()),
  locationInferred: z.string(),
  scalePresent: ScalePresentSchema,
  measurementVisible: nullable(z.string()),
  summaryObservation: z.string(),
  captionDraft: z.string(),
  recommendedUse: RecommendedUseSchema,
  reviewerFlag: z.string(),
  validationErrors: z.array(z.string()),
  rawResponse: nullable(z.string()),
  parseFailed: z.boolean(),
});

export const PhotoSchema = z.object({
  id: uuid,
  sequenceNumber: z.number().int(),
  timestamp: isoDate,
  imageFilename: z.string(),
  thumbnailFilename: nullable(z.string()),

  floorPlanID: nullable(uuid),
  localXFeet: nullable(z.number()),
  localYFeet: nullable(z.number()),
  planPixelX: nullable(z.number()),
  planPixelY: nullable(z.number()),
  headingDegrees: nullable(z.number()),

  positionSource: PositionSourceSchema,
  groupID: nullable(uuid),
  isPrimary: z.boolean(),
  cameraZoom: z.number(),
  lensName: nullable(z.string()),
  flashMode: FlashModeSchema,

  aiDescription: nullable(z.string()),
  aiSeverity: nullable(z.string()),
  aiObservation: nullable(z.string()),
  aiFollowUp: nullable(z.string()),
  aiAnalysis: nullable(AIPhotoAnalysisSchema),

  tags: z.array(TagSchema),
  pendingSuggestions: z.array(TagSuggestionSchema),

  bucketID: nullable(uuid),
  markupOverlayFilename: nullable(z.string()),
  markupDrawingFilename: nullable(z.string()),
  reshootsPhotoID: nullable(uuid),
  isFavorite: z.boolean(),
  trashedAt: nullable(isoDate),
  userCaption: nullable(z.string()),
  userObservation: nullable(z.string()),
  previewRotation: z.number().int(),
});

export const DistressMarkSchema = z.object({
  id: uuid,
  kind: DistressKindSchema,
  // Opaque pass-through for Phase 0 — see comment on `DistressMark`
  // in `manifest.ts`. Switches to a structured `{ x, y }` shape in
  // Phase 3 when distress sync to web goes live.
  points: z.array(z.record(z.string(), z.unknown())),
  note: nullable(z.string()),
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
  altitude: nullable(z.number()),
  accuracyFeet: nullable(z.number()),
  timestamp: isoDate,
});

export const BucketSchema = z.object({
  id: uuid,
  name: z.string(),
  colorHex: z.string().regex(/^#?[0-9a-fA-F]{6}$/),
  sortOrder: z.number().int(),
  libraryCategoryID: nullable(uuid),
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
  startedAt: nullable(isoDate),
  lastResumedAt: nullable(isoDate),
  lastStoppedAt: nullable(isoDate),
  stopped: z.boolean(),
  projectGPS: nullable(ProjectGPSSchema),
  projectAddress: nullable(z.string()),
  photos: z.array(PhotoSchema),
  trashedPhotos: z.array(PhotoSchema),
  floorPlans: z.array(FloorPlanSchema),
  activeFloorPlanID: nullable(uuid),
  folderName: nullable(z.string()),
  aiInstructions: nullable(z.string()),
  buckets: z.array(BucketSchema),
  tagSelection: nullable(ProjectTagSelectionSchema),
  aiExtraVocabulary: nullable(ProjectExtraVocabularySchema),
  manifestSchemaVersion: z.number().int().min(1),
});
