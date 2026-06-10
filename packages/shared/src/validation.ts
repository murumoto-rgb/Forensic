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
  // Phase 0 opaque pass-through. iOS stores points as `[CGPoint]`,
  // which Apple's default Codable encodes as a two-element
  // `[x, y]` array — NOT a `{ x, y }` object. We accept any
  // element shape on the wire and defer first-class typing to
  // Phase 3 when distress rendering on web requires interpreting
  // them (the web client at that point reads `point[0]`/`point[1]`
  // directly until iOS's encoder switches to keyed objects).
  points: z.array(z.unknown()),
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

// ===========================================================================
// App-wide config sync (Build #5.35.1)
// ===========================================================================
// Schemas for the `app_config` table values. Per-key dispatch in
// `server/src/routes/appConfig.ts` picks the right schema for an
// incoming PUT and rejects mismatched payloads with 400.

export const SecondaryTagEntrySchema = z.object({
  id: uuid,
  name: z.string(),
});

export const PrimaryTagEntrySchema = z.object({
  id: uuid,
  name: z.string(),
  secondaries: z.array(SecondaryTagEntrySchema),
});

export const InvestigationContextSchema = z.object({
  id: uuid,
  name: z.string(),
  primaries: z.array(PrimaryTagEntrySchema),
});

export const TagLibrarySchema = z.object({
  contexts: z.array(InvestigationContextSchema),
  // Older iOS pushes (pre-seed-v3) may omit seedVersion. Default to 1
  // at the boundary so the server can still record them.
  seedVersion: z.number().int().min(1).default(1),
});

export const AIRulesTemplateSchema = z.object({
  // Empty string is a legitimate state — the user can explicitly
  // wipe the template — so we don't require non-empty here.
  text: z.string(),
});

export const ReportBrandingSchema = z.object({
  titleOverride: nullable(z.string()),
  subtitleOverride: nullable(z.string()),
  footerOverride: nullable(z.string()),
  logoStoragePath: nullable(z.string()),
});

export const AIPromptTemplateSchema = z.object({
  id: uuid,
  name: z.string(),
  prompt: z.string(),
});

export const AIPromptTemplateLibrarySchema = z.object({
  templates: z.array(AIPromptTemplateSchema),
});

export const UserPrefsSchema = z.object({
  aiModel: nullable(z.string()),
  tagConfidenceThreshold: nullable(z.number().min(0).max(1)),
  aiConcurrency: nullable(z.number().int().min(1).max(20)),
  /** Build #6.13.1: cross-device floor-plan bubble size. */
  planBubbleScale: nullable(z.number().min(0.5).max(4)),
});

/** Folder-by-bucket export options. All fields optional on the wire;
 *  worker fills defaults. */
export const FolderExportOptionsSchema = z.object({
  burnTimestampAndGPS: z.boolean().optional(),
  scope: z.enum(["all", "filtered", "selected"]).optional(),
  selectedPhotoIds: z.array(z.string()).nullable().optional(),
});

/** AI Analysis CSV export options. */
export const AiAnalysisCsvOptionsSchema = z.object({
  onlyAnalyzed: z.boolean().optional(),
  minConfidence: z.number().min(0).max(1).optional(),
});

/** Project export creation body — kind + per-kind options. */
export const CreateProjectExportSchema = z.object({
  kind: z.enum(["pdf", "folder", "csv"]),
  // Loose validation here: per-kind shape is checked by the worker.
  // Empty object is fine; defaults apply.
  options: z.record(z.unknown()).optional(),
});

/**
 * Dispatch map: each `AppConfigKey` paired with the zod schema for
 * its value. Server's PUT route uses this to validate the incoming
 * payload against the right shape. Keeps the route handler small
 * and the per-key shape co-located with the schema declarations.
 */
export const AppConfigValueSchemaByKey = {
  tagLibrary: TagLibrarySchema,
  aiRulesTemplate: AIRulesTemplateSchema,
  // Build #5.48.1: read-only bundled-default mirrors. Same shapes
  // as the editable keys above — only the semantics differ (iOS
  // pushes these from its Swift constants every launch; nothing
  // else writes them).
  tagLibraryDefault: TagLibrarySchema,
  aiRulesTemplateDefault: AIRulesTemplateSchema,
  // Build #5.92.1: team-wide PDF export branding overrides. Both
  // iOS and web reads at render time.
  reportBranding: ReportBrandingSchema,
  // Build #5.104.1: saved AI prompt templates. Web admin today;
  // iOS picker / manager integration is a follow-on iOS PR.
  aiPromptTemplates: AIPromptTemplateLibrarySchema,
} as const;

export const ProjectSchema = z.object({
  id: uuid,
  name: z.string(),
  createdAt: isoDate,
  startedAt: nullable(isoDate),
  lastResumedAt: nullable(isoDate),
  lastStoppedAt: nullable(isoDate),
  stopped: z.boolean(),
  // Older manifests (pre-Build #5.6.1) didn't carry this field. We
  // accept payloads that omit it and default to false at the
  // server boundary so old iOS clients can still PUT cleanly while
  // the rollout propagates via TestFlight.
  isDeleted: z.boolean().default(false),
  // Build #5.126.1 (Phase 4) — project freeze flag. Same default-
  // on-absence discipline as isDeleted for older clients.
  isFrozen: z.boolean().default(false),
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

// ===========================================================================
// Phase 3 — Admin/team API request validators (Build #5.122.1)
// ===========================================================================

/** Bare email validator used by the invite endpoint. Server's
 *  Supabase Auth invite call does its own format check too; this is
 *  a fast-fail at the route boundary. */
export const InviteUserSchema = z.object({
  email: z.string().email(),
});

/** PATCH body for `PATCH /v1/admin/users/:id` — toggles the org-admin
 *  flag. Other profile fields aren't admin-editable. */
export const PatchUserSchema = z.object({
  isAdmin: z.boolean(),
});

/** PUT body for `PUT /v1/admin/projects/:projectId/members` — replaces
 *  the project's full member list. Server refuses to include the
 *  project owner here (owner is implicit editor; see migration 0014). */
export const SetProjectMembersSchema = z.object({
  members: z.array(
    z.object({
      userId: uuid,
      role: z.enum(["editor", "viewer"]),
    })
  ),
});
