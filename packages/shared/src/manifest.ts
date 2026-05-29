/**
 * Canonical TypeScript types for the Forensic project manifest.
 *
 * Every iOS Codable struct in `ios/SitePhoto/Models/` mirrors a type
 * defined here, field-for-field. The parity contract test in
 * `tests/ios-parity.test.ts` enforces this against a checked-in snapshot
 * of the iOS struct shapes (`fixtures/ios-models.json`).
 *
 * Convention for nullability:
 * - A field declared `T | null` in TS corresponds to an `Optional<T>` /
 *   `T?` field in Swift that is decoded with `decodeIfPresent`. The wire
 *   format uses JSON `null` (or absence) for the missing case.
 * - A field declared just `T` is required.
 *
 * Date fields are ISO-8601 strings on the wire. iOS encodes/decodes them
 * via the default `JSONEncoder` strategy (deferredToDate). Server-side
 * we normalize on read.
 */

export const MANIFEST_SCHEMA_VERSION = 1 as const;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

export type PositionSource = "manual" | "gps" | "none";

export type FlashMode = "auto" | "on" | "off";

export type TagSource = "vision" | "claude";

export type DistressKind =
  | "outOfPlumbDoor"
  | "doorNotLatching"
  | "crackGradeBeam"
  | "crackFloor";

/**
 * Constrained-string enum from the AI analysis. iOS preserves whatever
 * the model emitted in an `.unknown(String)` case; on the wire the
 * value is just the string ("Yes", "Relative", "No", or whatever
 * came back). Validation surfaces unknown values rather than dropping
 * them.
 */
export type ScalePresent = string;

/** Same pattern as ScalePresent — preserves the raw string on the wire. */
export type RecommendedUse = string;

// ---------------------------------------------------------------------------
// Tag types
// ---------------------------------------------------------------------------

export interface Tag {
  label: string;
  confidence: number;
  parentTag: string | null;
}

export interface TagSuggestion {
  label: string;
  confidence: number;
  source: TagSource;
  parentTag: string | null;
}

// ---------------------------------------------------------------------------
// AI analysis (schema 2)
// ---------------------------------------------------------------------------

export interface AIPhotoAnalysis {
  photoID: string;
  primaryTags: string[];
  secondaryTagsByPrimary: Record<string, string[]>;
  tagConfidences: Record<string, number>;
  locationInferred: string;
  scalePresent: ScalePresent;
  measurementVisible: string | null;
  summaryObservation: string;
  captionDraft: string;
  recommendedUse: RecommendedUse;
  reviewerFlag: string;
  validationErrors: string[];
  rawResponse: string | null;
  parseFailed: boolean;
}

// ---------------------------------------------------------------------------
// Photo
// ---------------------------------------------------------------------------

export interface Photo {
  id: string;
  sequenceNumber: number;
  timestamp: string;
  imageFilename: string;
  thumbnailFilename: string | null;

  floorPlanID: string | null;
  localXFeet: number | null;
  localYFeet: number | null;
  planPixelX: number | null;
  planPixelY: number | null;
  headingDegrees: number | null;

  positionSource: PositionSource;
  groupID: string | null;
  isPrimary: boolean;
  cameraZoom: number;
  lensName: string | null;
  flashMode: FlashMode;

  aiDescription: string | null;
  aiSeverity: string | null;
  aiObservation: string | null;
  aiFollowUp: string | null;
  aiAnalysis: AIPhotoAnalysis | null;

  tags: Tag[];
  pendingSuggestions: TagSuggestion[];

  bucketID: string | null;
  markupOverlayFilename: string | null;
  markupDrawingFilename: string | null;
  reshootsPhotoID: string | null;
  isFavorite: boolean;
  trashedAt: string | null;
  userCaption: string | null;
  userObservation: string | null;
  previewRotation: number;
}

// ---------------------------------------------------------------------------
// Floor plan + distress
// ---------------------------------------------------------------------------

/**
 * A point on a distress stroke or marker. On iOS this is currently
 * stored as `[CGPoint]`, which Apple's default Codable encodes as a
 * `[x, y]` two-element array. We carry `points` as `unknown[]` on
 * the wire because the server doesn't interpret the elements —
 * they're stored as JSONB and round-tripped to the web. Phase 3's
 * distress-on-web work will either:
 *   - Switch iOS to a structured `{ x: number; y: number }` encoder
 *     (recommended; matches the type from then on), or
 *   - Have the web client interpret `[x, y]` two-element arrays
 *     directly.
 */
export interface DistressMark {
  id: string;
  kind: DistressKind;
  points: unknown[];
  note: string | null;
  createdAt: string;
}

export interface FloorPlan {
  id: string;
  label: string;
  imageFilename: string;
  pixelsPerFoot: number;
  calibrationDistanceFeet: number;
  anchorPixelX: number;
  anchorPixelY: number;
  anchorLocalXFeet: number;
  anchorLocalYFeet: number;
  northDeg: number;
  distress: DistressMark[];
}

// ---------------------------------------------------------------------------
// Project-level sub-structures
// ---------------------------------------------------------------------------

export interface ProjectGPS {
  latitude: number;
  longitude: number;
  altitude: number | null;
  accuracyFeet: number | null;
  timestamp: string;
}

export interface Bucket {
  id: string;
  name: string;
  colorHex: string;
  sortOrder: number;
  libraryCategoryID: string | null;
}

/**
 * Per-project AI tagging scope. Mirrors `ProjectTagSelection.swift` —
 * the sets are serialized as arrays on the wire (JSON has no native
 * Set), preserving the engineer-chosen order via the `contextIDs`
 * field at the top level.
 */
export interface ProjectTagSelection {
  contextIDs: string[];
  primariesByContext: Record<string, string[]>;
  deselectedSecondariesByPrimary: Record<string, string[]>;
}

/**
 * Per-project additions to the controlled vocabulary. The internal
 * `PrimaryTagEntry` / `SecondaryTagEntry` shapes are not part of the
 * manifest contract today — they live in iOS-side TagLibrary code and
 * sync to web in Phase 4. For now we carry them as opaque records so
 * round-tripping through server is loss-free.
 */
export interface ProjectExtraVocabulary {
  primaries: Array<Record<string, unknown>>;
}

// ---------------------------------------------------------------------------
// Project
// ---------------------------------------------------------------------------

export interface Project {
  id: string;
  name: string;
  createdAt: string;
  startedAt: string | null;
  lastResumedAt: string | null;
  lastStoppedAt: string | null;
  stopped: boolean;
  projectGPS: ProjectGPS | null;
  projectAddress: string | null;
  photos: Photo[];
  trashedPhotos: Photo[];
  floorPlans: FloorPlan[];
  activeFloorPlanID: string | null;
  folderName: string | null;
  aiInstructions: string | null;
  buckets: Bucket[];
  tagSelection: ProjectTagSelection | null;
  aiExtraVocabulary: ProjectExtraVocabulary | null;
  /**
   * Integer schema version of this manifest. Server rejects writes
   * whose version exceeds what it knows about (forces the server to be
   * updated first). Bumped in iOS + shared + server in one PR.
   */
  manifestSchemaVersion: number;
}
