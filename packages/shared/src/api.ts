/**
 * REST API request/response shapes shared by server and clients.
 *
 * Phase 0 keeps this minimal — just a healthcheck and the eventual
 * shape of the manifest read/write. Real endpoints land in Phase 1.
 */

import type { Project } from "./manifest.ts";

export interface HealthzResponse {
  status: "ok";
  serverManifestSchemaVersion: number;
  /** Git commit SHA the running server was built from, if known
   *  (Render sets `RENDER_GIT_COMMIT`). Lets anyone confirm which
   *  build is live by hitting `/healthz` — e.g. after a deploy,
   *  check this matches the merge commit before testing. `null`
   *  when the env var isn't set (local dev). */
  gitSha: string | null;
  /** Short form of `gitSha` (first 7 chars) for quick eyeballing
   *  against GitHub's short SHAs. `null` when `gitSha` is. */
  gitShaShort: string | null;
}

export interface GetManifestResponse {
  project: Project;
  /** Opaque server-side revision string. Clients echo it on write to
   *  enable optimistic concurrency in Phase 1. */
  revision: string;
  /**
   * Caller's effective role on this project (Build #5.122.1). UI hides
   * edit controls when `"viewer"`. `"editor"` covers project owners and
   * member-editors; `"admin"` is an Org Admin. Optional for backwards
   * compatibility with older servers — clients that don't see this
   * field should fall back to today's owner-only behaviour.
   */
  role?: ProjectRole;
}

export interface PutManifestRequest {
  project: Project;
  /** Revision from the last GET. Server rejects with 409 on mismatch
   *  (legacy path). On the merge path it's advisory — the server
   *  merges against current truth regardless. */
  expectedRevision: string;
  /**
   * The manifest this client started from (its last-synced snapshot).
   * **Presence flips the server onto the 3-way merge path** (Build
   * #5.116.1): the server merges `(baseManifest, current, project)`
   * and stores the result. Absent → the legacy optimistic-concurrency
   * path (blind overwrite on a matching `expectedRevision`, 409
   * otherwise), so old clients keep working unchanged.
   */
  baseManifest?: Project;
}

export interface PutManifestResponse {
  revision: string;
  /**
   * The merged manifest the server now holds — present only on the
   * merge path. Clients **adopt** this (replace local + advance their
   * base) so both sides converge. Absent on the legacy path.
   */
  project?: Project;
}

export interface ApiError {
  error: string;
  message: string;
  details?: unknown;
}

// ===========================================================================
// Phase 2 — Files (Cloudflare R2 via presigned URLs)
// ===========================================================================

/** Categories of binary we store. Mirrors the SQL CHECK constraint. */
export type FileKind =
  | "photo"
  | "thumb"
  | "markup_png"
  | "markup_drawing"
  | "plan";

/** Maximum size we'll accept for a single object (50 MB). */
export const FILE_MAX_BYTES = 50 * 1024 * 1024;

export interface UploadUrlRequest {
  photoId: string;
  kind: FileKind;
  sizeBytes: number;
  /** Optional content hash. Stored for future dedup / integrity. */
  sha256?: string;
  /** MIME type — clamped to the right family for the kind by the server. */
  contentType: string;
}

export interface UploadUrlResponse {
  uploadUrl: string;
  objectKey: string;
  expiresAt: string;
}

export interface CommitUploadRequest {
  objectKey: string;
  photoId: string;
  kind: FileKind;
  sizeBytes: number;
  sha256?: string;
}

export interface CommitUploadResponse {
  ok: true;
}

export interface SyncFilesCheckRequest {
  /** Object keys the client wants to verify against R2 + the registry. */
  objectKeys: string[];
}

export interface SyncFilesCheckResponse {
  /** Subset of input keys that already exist on the server. */
  existing: string[];
}

// ---------------------------------------------------------------------------
// Project exports (Build #5.97.1) — unified surface for PDF / folder / CSV
// ---------------------------------------------------------------------------

export type ExportKind = "pdf" | "folder" | "csv";
export type ExportStatus = "queued" | "running" | "done" | "failed";

/** Options for the "Folder by Bucket" export. Mirrors iOS's
 *  `FolderExportRunner` toggles. */
export interface FolderExportOptions {
  /** When true, server burns the photo's capture timestamp + GPS
   *  into the JPG itself (re-encodes; loses original EXIF in the
   *  process — a litigation-grade option). Default false. */
  burnTimestampAndGPS: boolean;
  /** Scope: which subset of project photos to include. */
  scope: "all" | "filtered" | "selected";
  /** When `scope === "selected"`, the photo IDs to include. */
  selectedPhotoIds: string[] | null;
}

/** Options for the AI Analysis CSV export. */
export interface AiAnalysisCsvOptions {
  /** When true, photos without an `aiAnalysis` block are skipped
   *  (default — most users only care about analyzed photos). */
  onlyAnalyzed: boolean;
  /** Tags below this confidence are dropped from the CSV. Defaults
   *  to 0.5 (matches iOS). */
  minConfidence: number;
}

/** Discriminated union of every export's options shape. */
export type ProjectExportOptions =
  | ({ kind: "pdf" } & Partial<PdfExportOptions>)
  | ({ kind: "folder" } & Partial<FolderExportOptions>)
  | ({ kind: "csv" } & Partial<AiAnalysisCsvOptions>);

export interface ProjectExport {
  id: string;
  projectId: string;
  kind: ExportKind;
  status: ExportStatus;
  /** Present once `status === "done"`. R2 object key the server
   *  resolves to a presigned-GET on demand. */
  objectKey: string | null;
  /** Size of the rendered artifact in bytes (populated on done). */
  sizeBytes: number | null;
  /** Optional progress counters populated by the folder + CSV
   *  workers (Build #5.106.1). For folder bundles, `progressDone`
   *  is the count of photos pulled from R2 so far;
   *  `progressTotal` is the full candidate set. Both null on
   *  exports created before progress tracking shipped. */
  progressDone: number | null;
  progressTotal: number | null;
  errorMessage: string | null;
  createdAt: string;
  startedAt: string | null;
  completedAt: string | null;
}

export interface CreateProjectExportRequest {
  kind: ExportKind;
  /** Per-kind options. Unknown fields are ignored; missing fields
   *  default to the worker's defaults. */
  options?: Partial<FolderExportOptions> | Partial<AiAnalysisCsvOptions> | Partial<PdfExportOptions>;
}

export interface CreateProjectExportResponse {
  export: ProjectExport;
}

export interface ListProjectExportsResponse {
  exports: ProjectExport[];
}

export interface GetProjectExportResponse {
  export: ProjectExport;
  /** Short-lived presigned-GET URL when status==='done'. */
  downloadUrl: string | null;
  downloadUrlExpiresAt: string | null;
}

// ---------------------------------------------------------------------------
// Client-side folder export manifest (Build #5.110.1)
// ---------------------------------------------------------------------------

/**
 * Server response for the manifest endpoint that powers the
 * browser-side ZIP build. The browser uses this to download
 * photos directly from R2 and assemble a ZIP locally — taking
 * the streaming / CPU work off the Render dyno entirely.
 */
export interface FolderExportManifestPhoto {
  id: string;
  /** R2 presigned-GET URL (15 min TTL — long enough for slow connections). */
  presignedUrl: string;
  /** Filename to use inside the ZIP (`<Project name> - <seq> - <date>.<ext>`). */
  filename: string;
  /** Bucket id, or null when unbucketed. */
  bucketId: string | null;
  sequenceNumber: number;
  timestamp: string;
  userCaption: string | null;
  userObservation: string | null;
  aiSummary: string | null;
  tags: string[];
}

export interface FolderExportManifestPlan {
  id: string;
  presignedUrl: string;
  filename: string;
  label: string;
  pixelsPerFoot: number;
  calibrationDistanceFeet: number;
  northDeg: number;
  distressMarkerCount: number;
}

export interface FolderExportManifestBucket {
  id: string;
  name: string;
  /** `01 Foundation`, `02 Framing`, …, `99 Unbucketed` for null. */
  folderName: string;
}

export interface FolderExportManifest {
  projectName: string;
  buckets: FolderExportManifestBucket[];
  /** Bucket entry to use for photos whose `bucketId` doesn't match
   *  any of the above (typically `99 Unbucketed`). */
  unbucketedFolderName: string;
  photos: FolderExportManifestPhoto[];
  plans: FolderExportManifestPlan[];
  /** Total bytes the browser is about to download. Useful for an
   *  "estimated 1.5 GB; ~3 min on a 50 Mbit/s connection" pre-flight. */
  totalSizeBytes: number;
  /** ISO timestamp the manifest was generated. */
  computedAt: string;
}

export interface GetFolderExportManifestResponse {
  manifest: FolderExportManifest;
}

// ---------------------------------------------------------------------------
// Per-user preferences (Build #5.95.1)
// ---------------------------------------------------------------------------

/**
 * Server-backed copy of the user's UI prefs. Web hydrates from
 * `GET /v1/me/prefs` on app load with a localStorage fallback for
 * 404s, and writes (debounced) on every change so the prefs follow
 * the user across browsers / devices.
 */
export interface UserPrefs {
  /** AI model used by the batch / single Re-tag controls. */
  aiModel: string | null;
  /** Tag confidence threshold (0–1). */
  tagConfidenceThreshold: number | null;
  /** Parallel AI request concurrency cap (1–20). */
  aiConcurrency: number | null;
  /** Floor-plan bubble (pin) size multiplier, 0.5–4 (Build #6.13.1).
   *  Cross-device sync of the FloorPlanTab's `+ / −` zoom controls;
   *  null = device default (1.5×, matching the iOS PDF default). */
  planBubbleScale: number | null;
  /** Floor-plan pin color mode (Build #6.26.1): "status" (default
   *  single color) | "bucket" | "primaryTag". Same rawValues as
   *  iOS's `PlanColorMode` so the two stores describe the same
   *  concept; null = status. */
  planColorMode: string | null;
}

export interface GetUserPrefsResponse {
  prefs: UserPrefs;
  /** Opaque token; clients echo on PUT for optimistic concurrency. */
  revision: string;
}

export interface PutUserPrefsRequest {
  prefs: UserPrefs;
  expectedRevision: string | null;
}

export interface PutUserPrefsResponse {
  revision: string;
}

// ---------------------------------------------------------------------------
// Per-user storage status (Build #5.100.1)
// ---------------------------------------------------------------------------

/**
 * Aggregated cloud-storage usage for the calling user — surfaced on
 * the Settings page (Storage section) so users can see how much
 * their projects + photos consume on the server. Phase 5
 * multi-user quotas will reuse this shape.
 */
export interface UserStorageStatus {
  /** Total projects owned by the user (active + trashed). */
  projectCount: number;
  /** Active (non-deleted) projects. */
  activeProjectCount: number;
  /** Total photos across all projects (manifest counts, not file rows). */
  photoCount: number;
  /** Total floor plans across all projects. */
  floorPlanCount: number;
  /** Sum of `size_bytes` across all `files` rows owned by the user. */
  totalBlobBytes: number;
  /** Per-kind blob breakdown — same `kind` values as `files.kind`. */
  blobBytesByKind: Record<string, number>;
}

export interface GetUserStorageStatusResponse {
  status: UserStorageStatus;
  /** Server time the aggregate was computed (browser caches 30s). */
  computedAt: string;
}

// ===========================================================================
// Phase 4 — AI tagging proxy (Build #5.32.1)
// ===========================================================================

/**
 * Models the server's `/v1/ai/tag-photo` endpoint accepts. iOS picks
 * from this list in the Settings sheet; the server validates against
 * it so a client typo can't bill cents per request to an unintended
 * model. Add new entries as Anthropic releases them — the underlying
 * Anthropic SDK call accepts any string the API recognizes.
 */
export type AITagPhotoModel =
  | "claude-sonnet-4-6"
  | "claude-haiku-4-5";

export interface AITagPhotoRequest {
  /** Project the photo lives in — used for ownership check + audit. */
  projectId: string;
  /** Photo whose bytes the server will fetch from R2 and pass to Anthropic. */
  photoId: string;
  /** Which Anthropic model to call. iOS Settings drives this. */
  model: AITagPhotoModel;
  /**
   * Full system prompt the client assembled (controlled vocabulary,
   * rules, output schema instructions, etc.).
   *
   * **Optional as of Build #5.46.1.** When omitted, the server
   * compiles the system prompt itself from the project's manifest
   * (read from the projects table) + the team's tag library and
   * AI rules template (read from `app_config`). Same
   * `compilePrompt(...)` shared logic the client uses, so the
   * output is byte-equivalent — the choice between client-side and
   * server-side compilation is a deployment / parity convenience,
   * not a behaviour difference.
   *
   * Clients that have their own customisation pipeline (current
   * iOS device-key path) keep sending the prompt themselves;
   * thin clients (future web admin tooling, ad-hoc CLIs) can
   * omit it and let the server do the work.
   */
  systemPrompt?: string;
  /**
   * User-message text accompanying the photo. Usually project
   * context + final per-photo instructions the client appends after
   * the system blocks.
   *
   * **Optional as of Build #5.46.1** for the same reason as
   * `systemPrompt`. When omitted, the server compiles the user
   * prompt via shared `compileUserPrompt(photo.imageFilename)`.
   */
  userText?: string;
  /**
   * Anthropic `max_tokens`. Optional — server defaults to 4096
   * (enough for a structured tag/analysis JSON; bump up for verbose
   * models). Capped server-side at 16384 so a client typo can't
   * force a 60-second response.
   */
  maxTokens?: number;
}

export interface AITagPhotoResponse {
  /**
   * Raw text the model emitted (concatenation of every `text`-type
   * content block). Client parses this into its own AIPhotoAnalysis
   * struct — server doesn't crack the schema open because iOS
   * already has a mature parser and we don't want to duplicate it.
   */
  rawText: string;
  /** Usage metrics straight from Anthropic, useful for cost tracking. */
  usage: {
    inputTokens: number;
    outputTokens: number;
    /**
     * Tokens that hit the Anthropic prompt cache (cheap, ~0.1×).
     * Will be 0 until iOS/web opt into prompt caching by adding
     * `cache_control` markers to the system prompt.
     */
    cacheReadTokens: number;
    /** Tokens written to the prompt cache this call (~1.25×). */
    cacheCreationTokens: number;
  };
  /** Wall-clock duration of the Anthropic call in milliseconds. */
  durationMs: number;
  /** Echoes back the model name for the client's audit log. */
  model: string;
}

export interface PhotoUrlResponse {
  /** Short-lived presigned R2 GET URL. Place into `<img src>` or
   *  fetch with URLSession directly — no auth header needed. */
  url: string;
  /** ISO date when the presigned URL stops working. */
  expiresAt: string;
}

/**
 * Batch counterpart of the single-photo URL endpoint. A photo grid
 * with N thumbnails would otherwise fire N parallel requests through
 * the server — on a free-tier Render instance with hundreds of
 * photos in a project that's a 502-storm waiting to happen
 * (Build #5.19.1 fix). This endpoint takes the photo IDs in one
 * round trip and returns a `{photoId: presignedUrl}` map.
 *
 * Up to 1000 photos per request. Server hard-caps any more.
 */
export interface PhotoUrlsBatchRequest {
  photoIds: string[];
  /** "thumb" returns thumbnails (falls back to the full photo if no
   *  separate thumb exists), "image" returns full-res originals. */
  kind: "thumb" | "image";
}

export interface PhotoUrlsBatchResponse {
  /** photoId → presigned URL. Missing IDs are simply absent from the
   *  map (no entry) — the client renders the same "pending" placeholder
   *  it would for an individual 404. */
  urls: Record<string, string>;
  /** ISO date when the presigned URLs in this response stop working.
   *  All URLs in one batch share the same expiry — the server uses
   *  the same TTL for every entry. */
  expiresAt: string;
}

// ===========================================================================
// Phase 4 — App-wide config sync (Build #5.35.1)
// ===========================================================================

import type { AppConfigKey, AppConfigValueByKey } from "./appConfig.js";

/**
 * Response shape for `GET /v1/config/:key`. The server returns 404
 * when no row exists yet (e.g. iOS hasn't pushed its tag library
 * yet on a fresh team), which clients treat as "fall back to
 * bundled defaults" rather than an error.
 */
export interface GetAppConfigResponse<K extends AppConfigKey = AppConfigKey> {
  key: K;
  value: AppConfigValueByKey[K];
  /** Opaque revision token. Clients echo on PUT for optimistic concurrency. */
  revision: string;
  /** ISO timestamp of the last write — useful for "X edited the tag
   *  library 2 minutes ago" UI affordances. */
  updatedAt: string;
}

/**
 * Bulk fetch — one round trip pulls every known key. Convenient on
 * iOS launch and on web first-load. Missing keys are absent from the
 * `entries` map (no 404 / null entry), letting clients merge with
 * their local defaults straight away.
 */
export interface GetAppConfigBundleResponse {
  entries: { [K in AppConfigKey]?: GetAppConfigResponse<K> };
}

export interface PutAppConfigRequest<K extends AppConfigKey = AppConfigKey> {
  value: AppConfigValueByKey[K];
  /** Last-known revision from a prior GET, or `null` for first push
   *  of this key. Mismatch → 409 so the caller pulls + merges
   *  rather than clobbering. */
  expectedRevision: string | null;
}

export interface PutAppConfigResponse {
  revision: string;
}

// ===========================================================================
// Phase 2 (belated) — Project edit locks (Build #5.59.1)
// ===========================================================================

/** Which client platform holds (or is acquiring) a lock. Drives the
 *  viewer banner copy ("Editing on web" / "Editing on iPad"). */
export type LockClient = "web" | "ios";

/**
 * A project's current lock state. Returned by the lock endpoints and
 * read by viewers to render the "Currently editing: X" banner.
 * `null`-shaped absence (404 from GET /lock) means the project is
 * free to edit.
 */
export interface ProjectLock {
  projectId: string;
  /** Supabase user id of the lock holder. */
  userId: string;
  /** Holder's email — shown in the viewer banner. */
  userEmail: string;
  client: LockClient;
  acquiredAt: string;
  lastHeartbeat: string;
  /** ISO timestamp the lock auto-expires at if no heartbeat lands. */
  expiresAt: string;
  /**
   * Per-tab session token the holder sent on acquire (Build #5.120.1).
   * Lets the server distinguish "same user, same tab" from "same user,
   * different tab" so a back-nav return doesn't render the user as
   * locked out by their own stale lock. `null` for iOS holders and
   * for old web binaries that don't send the token.
   */
  clientSession: string | null;
}

export interface AcquireLockRequest {
  client: LockClient;
  /** Per-tab session token (web only — see `ProjectLock.clientSession`).
   *  Generated from `sessionStorage`. */
  clientSession?: string;
}

/** Response to acquire / heartbeat — the now-current lock (held by
 *  the caller). Acquire returns 409 + `ApiError` when another live
 *  user holds it. */
export interface LockResponse {
  lock: ProjectLock;
}

/** GET /lock response (Build #5.120.1).
 *
 *  `lock` is null when the project is free (no row, or expired).
 *
 *  `heldByYou` tells the caller their relationship to the lock and
 *  is what fixes the back-button self-lock bug:
 *   - `"session"` → same user_id AND same client_session as the
 *     caller sent → the caller IS the holder (resume editing).
 *   - `"user"`    → same user_id, different client_session → another
 *     tab / device of the same user holds it (gentle re-acquire).
 *   - `null`      → someone else holds it, or it's free.
 *
 *  Old servers (pre-#5.120.1) omit `heldByYou`; clients should treat
 *  absence as `null` and fall back to the legacy "GET never sets
 *  holding" behaviour. */
export interface GetLockResponse {
  lock: ProjectLock | null;
  heldByYou?: "session" | "user" | null;
}

// ===========================================================================
// Phase 4 — Server-side PDF export (Build #5.62.1)
// ===========================================================================

/** Job lifecycle states. Worker transitions queued → running → done|failed. */
export type PdfExportStatus = "queued" | "running" | "done" | "failed";

/** What the web client sees about a job at any point in its lifecycle.
 *  Mirrors the `pdf_export_jobs` row, normalized to camelCase. */
export interface PdfExportJob {
  id: string;
  projectId: string;
  status: PdfExportStatus;
  /** Populated once the worker has uploaded the PDF to R2. */
  pdfObjectKey: string | null;
  /** Human-readable failure reason; null until/unless status is "failed". */
  errorMessage: string | null;
  createdAt: string;
  startedAt: string | null;
  completedAt: string | null;
  /** Chunks rendered so far (Build #5.75.1). Null before the worker
   *  reports its first chunk, or for jobs persisted before this
   *  field existed. */
  progressDoneChunks: number | null;
  /** Total chunks this render will produce. Null until the worker
   *  has computed the chunk list. */
  progressTotalChunks: number | null;
}

/** Paper size for the rendered PDF. iOS export defaults to letter
 *  (US engineering convention); A4 is the European-team affordance.
 *  Web-only option (iOS PDF service is hard-coded to Letter). */
export type PdfPageSize = "letter" | "a4";

/**
 * Legacy fixed-set of photos-per-page (Build #5.64.1). Superseded by
 * the iOS-parity `perPage: number` field added in #5.67.1 — the new
 * field is a flexible Int in the 1-12 range, matching the iOS
 * `PDFExportOptions.perPage` field. Kept for backwards compatibility
 * with old `pdf_export_jobs.options` rows during the parity rollout;
 * the renderer reads `perPage` first and falls back to this.
 *
 * @deprecated since #5.67.1 — use `perPage` instead.
 */
export type PdfPhotosPerPage = 1 | 2 | 4;

/**
 * Legacy single-mode photo filter (Build #5.64.1). Superseded by
 * `selectedFloorIds: string[] | null` (multi-select, matching iOS)
 * in #5.67.1. Kept for backwards compatibility — the renderer prefers
 * the new field when present, falls back to this otherwise.
 *
 * @deprecated since #5.67.1 — use `selectedFloorIds` (with `null`
 *   meaning "include every floor plan").
 */
export type PdfPhotoFilter = "all" | "favorites" | "byFloorPlan";

/**
 * Plan-page render mode (Build #5.67.1 — iOS parity). Mirrors the iOS
 * `PDFExportOptions.PlanRenderMode` enum field-for-field. Default
 * `photoOnly` matches the prior web behaviour (and iOS's own default)
 * so existing clients keep producing the same output. The four modes
 * cover the cross-product of {photo pins, distress marks} × {separate
 * pages, one merged page}.
 */
export type PdfPlanMode =
  | "photoOnly"
  | "distressOnly"
  | "photoAndDistressSeparate"
  | "merged";

/**
 * Optional section in the rendered PDF, ordered by `sectionOrder`
 * (Build #5.67.1). Mirrors iOS's `PDFExportOptions.Section`. The
 * cover page is always page 1 and is NOT in this list — it can't be
 * reordered or removed (matches iOS). Sections whose underlying data
 * isn't applicable get skipped (no floor plans → skip `plan`,
 * `includeMetadataTable === false` → skip `metadataTable`).
 */
export type PdfSection = "plan" | "contactSheets" | "metadataTable";

/**
 * Per-photo annotations rendered under each contact-sheet cell
 * (Build #5.67.1). Mirrors iOS's `PDFExportOptions.AnnotationOptions`
 * field-for-field. Default keeps the legacy "tags only" behaviour
 * (matches iOS default).
 */
export interface PdfAnnotationOptions {
  includeTags: boolean;
  includeCaption: boolean;
  includeObservation: boolean;
  includeMeasurement: boolean;
  includeReviewerFlag: boolean;
}

/**
 * Per-job options passed alongside the create request.
 *
 * Build #5.67.1 brought the field set up to iOS parity. The renderer
 * prefers the new iOS-mirror fields (`perPage`, `groupByBucket`,
 * `includeMetadataTable`, `annotations`, `sectionOrder`,
 * `selectedFloorIds`, `planMode`) when present, falling back to the
 * legacy #5.64.1 fields (`photosPerPage`, `photoFilter`,
 * `floorPlanId`, `includeFloorPlanPages`) so old jobs and old web
 * clients keep working through the rollout.
 *
 * All fields carry sensible defaults — the worker substitutes
 * defaults for any missing field rather than rejecting — so a
 * client that POSTs `{}` still produces a valid PDF.
 */
export interface PdfExportOptions {
  // ----- iOS parity fields (#5.67.1) -----

  /**
   * Photos per contact-sheet page. iOS-style flexible Int. Matches
   * iOS `PDFExportOptions.perPage` (default 6). Server clamps to the
   * 1-12 range; anything outside falls back to the default.
   */
  perPage: number;
  /** Mirrors iOS `groupByBucket`. Default false. */
  groupByBucket: boolean;
  /** Mirrors iOS `includeMetadataTable`. Default false. */
  includeMetadataTable: boolean;
  /** Mirrors iOS `annotations`. Default: tags-only. */
  annotations: PdfAnnotationOptions;
  /** Mirrors iOS `sectionOrder`. Default: [plan, contactSheets, metadataTable]. */
  sectionOrder: PdfSection[];
  /**
   * Mirrors iOS `selectedFloorIDs`. `null` means "include every
   * floor plan" (matching iOS's nil-default). Photos not on any
   * included plan land in a trailing "Unlocated photos" group so
   * nothing gets dropped.
   */
  selectedFloorIds: string[] | null;
  /** Mirrors iOS `planMode`. Default `photoOnly`. */
  planMode: PdfPlanMode;

  // ----- Web-specific carryover from #5.64.1 -----

  pageSize: PdfPageSize;
  /** Include photos with a non-null `trashedAt`. Default false.
   *  iOS hides trashed photos unconditionally — this is a web
   *  affordance for the office reviewer who occasionally wants to
   *  audit what's been hidden. */
  includeTrashed: boolean;
  /** Include the project cover page. Default true. iOS always
   *  renders the cover (not toggleable); web exposes it for the
   *  office staff who want a minimal printout. */
  includeCoverPage: boolean;
  /** Floor-plan pin/bubble size multiplier on plan pages
   *  (Build #6.20.1). Web sends the user's on-screen pin-size
   *  setting (`planBubbleScale`) so the exported PDF matches what
   *  they see — the same way the iOS exporter applies its
   *  `sitephoto.bubbleScale`. 1 = the legacy fixed size; the server
   *  clamps to 0.5–4. */
  pinScale: number;

  // ----- Legacy fields (kept for backwards compat) -----

  /** @deprecated #5.67.1 — use `perPage`. */
  photosPerPage?: PdfPhotosPerPage;
  /** @deprecated #5.67.1 — use `selectedFloorIds`. */
  photoFilter?: PdfPhotoFilter;
  /** @deprecated #5.67.1 — selecting via `selectedFloorIds` covers
   *  the single-plan case too. Required when `photoFilter === "byFloorPlan"`
   *  on legacy callers. */
  floorPlanId?: string | null;
  /** @deprecated #5.67.1 — use `sectionOrder` (omit `plan` to skip
   *  floor-plan pages, or pass an empty `selectedFloorIds` array). */
  includeFloorPlanPages?: boolean;
}

export interface CreatePdfExportRequest {
  /** Optional — the server applies a sensible-defaults block when
   *  omitted so legacy clients that POST `{}` still work. */
  options?: Partial<PdfExportOptions>;
}

export interface CreatePdfExportResponse {
  job: PdfExportJob;
}

/** GET /v1/exports/:jobId response. `downloadUrl` is populated only
 *  when status is "done" — a short-lived (5 min) presigned R2 GET URL
 *  the browser can hit directly without an auth header. */
export interface GetPdfExportResponse {
  job: PdfExportJob;
  downloadUrl: string | null;
  /** ISO timestamp when `downloadUrl` stops working. Null when there's
   *  no URL yet. */
  downloadUrlExpiresAt: string | null;
}


// ===========================================================================
// Phase 3 — Users, roles, per-project assignment (Build #5.122.1)
// ===========================================================================

/**
 * Effective role of a caller on a project.
 *
 *   - `"admin"`  — Org Admin. Can see and edit every project, manage
 *     users, set per-project member assignments.
 *   - `"editor"` — Owner of the project (implicit) OR a member with
 *     role `"editor"` from the `project_members` table. Can edit.
 *   - `"viewer"` — Member with role `"viewer"`. Read-only.
 *
 * Resolution order on the server:
 *     admin > owner (implicit editor) > member.role > none
 */
export type ProjectRole = "admin" | "editor" | "viewer";

/** Per-project assignment view shown on the admin users page so an
 *  admin can audit which projects each user can touch. */
export interface AdminUserAssignment {
  projectId: string;
  projectName: string;
  /** Member role only — owner/admin don't appear here (they're
   *  resolved via `projects.owner_id` and `profiles.is_admin`). */
  role: "editor" | "viewer";
}

/** A user row in the admin users page. `pending` is true when the
 *  user has been invited but never signed in (their profile has a
 *  null display_name AND auth.users.last_sign_in_at is null). */
export interface AdminUser {
  id: string;
  email: string;
  displayName: string | null;
  isAdmin: boolean;
  createdAt: string;
  pending: boolean;
  assignments: AdminUserAssignment[];
}

export interface ListAdminUsersResponse {
  users: AdminUser[];
}

export interface InviteUserRequest {
  email: string;
}
export interface InviteUserResponse {
  user: AdminUser;
}

export interface PatchUserRequest {
  isAdmin: boolean;
}
export interface PatchUserResponse {
  user: AdminUser;
}

export interface ProjectMemberAssignment {
  userId: string;
  role: "editor" | "viewer";
}
export interface SetProjectMembersRequest {
  members: ProjectMemberAssignment[];
}
export interface SetProjectMembersResponse {
  members: ProjectMemberAssignment[];
}

/**
 * `GET /v1/me` response (Build #5.122.1). Source of truth for the
 * web client's "am I admin?" gate. Not admin-gated — every signed-in
 * user calls it on mount to decide which admin links to render.
 */
export interface MeResponse {
  id: string;
  email: string;
  displayName: string | null;
  isAdmin: boolean;
}
