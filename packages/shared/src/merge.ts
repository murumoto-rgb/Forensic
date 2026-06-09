/**
 * Deterministic 3-way merge for project manifests (Build #5.116.1 —
 * cloud-first foundation, Phase 1).
 *
 * The server is becoming the source of truth. When a client pushes an
 * edited manifest it also sends the **base** — the manifest it started
 * from. The server merges `(base, server-current, client-edited)` and
 * stores the result, so two clients editing the same project never
 * clobber each other (the old "local wins" / "reload, lose your edits"
 * behaviour is gone).
 *
 * Design properties (enforced by `tests/merge.test.ts`):
 *  - **Idempotent / convergent.** `merge(base, X, X) === X`. Re-merging
 *    an already-merged state is a no-op, so repeated syncs reach a
 *    fixed point.
 *  - **One side wins cleanly.** `merge(base, server, base) === server`
 *    (client made no changes) and `merge(base, base, client) === client`
 *    (server unchanged).
 *  - **Additive on adds, base-aware on deletes.** A row added on either
 *    side survives; a row deleted on one side is honoured only when the
 *    other side left it untouched (modify-beats-delete so an in-flight
 *    edit is never silently dropped).
 *  - **No hard-fail.** Every field resolves to a deterministic winner;
 *    genuine both-changed conflicts are recorded in `MergeReport` (for
 *    logging / audit) but never throw.
 *
 * The merged object is built as a full `Project` literal, so adding a
 * field to `Project` is a compile error here until a merge rule for it
 * exists — that's the exhaustiveness guard the parity-style test backs
 * up.
 */

import type {
  Project,
  Photo,
  FloorPlan,
  Bucket,
  Tag,
  TagSuggestion,
  ProjectGPS,
  DistressMark,
  ProjectTagSelection,
  ProjectExtraVocabulary,
} from "./manifest.js";

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

export interface MergeConflict {
  /** Dotted/bracketed path of the field that both sides changed, e.g.
   *  `name` or `photos[<id>].userCaption`. */
  path: string;
  serverValue: unknown;
  clientValue: unknown;
  /** Which value the deterministic tie-break kept. */
  chosen: "server" | "client" | "other";
}

export interface MergeReport {
  /** Every field where both sides diverged from base and a winner was
   *  forced. Empty on a clean (non-conflicting) merge. */
  conflicts: MergeConflict[];
}

class Ctx {
  readonly conflicts: MergeConflict[] = [];
  record(c: MergeConflict): void {
    this.conflicts.push(c);
  }
}

// ---------------------------------------------------------------------------
// Structural equality (key-order-independent)
// ---------------------------------------------------------------------------

export function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a === null || b === null || a === undefined || b === undefined) {
    return a === b;
  }
  if (typeof a !== "object" || typeof b !== "object") return false;
  const aArr = Array.isArray(a);
  const bArr = Array.isArray(b);
  if (aArr || bArr) {
    if (!aArr || !bArr) return false;
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  const ao = a as Record<string, unknown>;
  const bo = b as Record<string, unknown>;
  const ak = Object.keys(ao);
  const bk = Object.keys(bo);
  if (ak.length !== bk.length) return false;
  for (const k of ak) {
    if (!Object.prototype.hasOwnProperty.call(bo, k)) return false;
    if (!deepEqual(ao[k], bo[k])) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Scalar 3-way + tie-break strategies
// ---------------------------------------------------------------------------

type TieResult<T> = { value: T; chosen: "server" | "client" | "other" };
type Tie<T> = (server: T, client: T) => TieResult<T>;

/**
 * 3-way scalar merge. Equal sides → that value; only one side moved off
 * `base` → that side; both moved differently → field-specific `tie`
 * (recorded as a conflict).
 */
function scalar3<T>(
  base: T,
  server: T,
  client: T,
  tie: Tie<T>,
  ctx: Ctx,
  path: string
): T {
  if (deepEqual(server, client)) return server;
  if (deepEqual(client, base)) return server; // only server changed
  if (deepEqual(server, base)) return client; // only client changed
  const r = tie(server, client);
  ctx.record({ path, serverValue: server, clientValue: client, chosen: r.chosen });
  return r.value;
}

function clientWins<T>(_server: T, client: T): TieResult<T> {
  return { value: client, chosen: "client" };
}

/** Prefer a non-null value; otherwise the client's. */
function nonNullThenClient<T>(server: T, client: T): TieResult<T> {
  if (client === null && server !== null) return { value: server, chosen: "server" };
  return { value: client, chosen: "client" };
}

/** Boolean "true wins" — the protective / terminal / destructive state. */
function trueWins(server: boolean, client: boolean): TieResult<boolean> {
  const value = server === true || client === true;
  return { value, chosen: server === true ? "server" : "client" };
}

/** Later ISO timestamp wins; null-tolerant (prefer non-null). */
function laterIso(
  server: string | null,
  client: string | null
): TieResult<string | null> {
  if (server === null) return { value: client, chosen: "client" };
  if (client === null) return { value: server, chosen: "server" };
  return server >= client
    ? { value: server, chosen: "server" }
    : { value: client, chosen: "client" };
}

/** Smaller number wins (stable ordering fields like sequenceNumber). */
function minNumber(server: number, client: number): TieResult<number> {
  return server <= client
    ? { value: server, chosen: "server" }
    : { value: client, chosen: "client" };
}

/** trashedAt: a set (non-null) value wins (deletion intent); if both
 *  set, the earlier trashing wins deterministically. */
function trashedAtTie(
  server: string | null,
  client: string | null
): TieResult<string | null> {
  if (server === null) return { value: client, chosen: "client" };
  if (client === null) return { value: server, chosen: "server" };
  return server <= client
    ? { value: server, chosen: "server" }
    : { value: client, chosen: "client" };
}

/** ProjectGPS: atomic fix; the one with the newer inner timestamp wins. */
function gpsTie(
  server: ProjectGPS | null,
  client: ProjectGPS | null
): TieResult<ProjectGPS | null> {
  if (server === null) return { value: client, chosen: "client" };
  if (client === null) return { value: server, chosen: "server" };
  return server.timestamp >= client.timestamp
    ? { value: server, chosen: "server" }
    : { value: client, chosen: "client" };
}

// ---------------------------------------------------------------------------
// Keyed collection 3-way (adds + base-aware deletes + per-element merge)
// ---------------------------------------------------------------------------

function indexBy<T>(arr: T[], keyOf: (t: T) => string): Map<string, T> {
  const m = new Map<string, T>();
  for (const t of arr) m.set(keyOf(t), t);
  return m;
}

/**
 * Merge two collections against a common base. Order: the client's
 * order first (the active editor's arrangement), then any server-only
 * survivors appended in server order.
 */
function keyedMerge3<T>(
  keyOf: (t: T) => string,
  base: T[],
  server: T[],
  client: T[],
  elementMerge: (b: T | undefined, s: T, c: T) => T
): T[] {
  const bMap = indexBy(base, keyOf);
  const sMap = indexBy(server, keyOf);
  const cMap = indexBy(client, keyOf);
  const out: T[] = [];
  const emitted = new Set<string>();
  const consider = (k: string): void => {
    if (emitted.has(k)) return;
    emitted.add(k);
    const b = bMap.get(k);
    const s = sMap.get(k);
    const c = cMap.get(k);
    if (s !== undefined && c !== undefined) {
      out.push(elementMerge(b, s, c));
    } else if (s !== undefined) {
      // client-only-absent: a delete iff base had it AND server left it
      // unchanged. Otherwise (server added, or server modified vs a
      // client delete) keep the server's version.
      if (b !== undefined && deepEqual(s, b)) return;
      out.push(s);
    } else if (c !== undefined) {
      if (b !== undefined && deepEqual(c, b)) return;
      out.push(c);
    }
  };
  for (const t of client) consider(keyOf(t));
  for (const t of server) consider(keyOf(t));
  return out;
}

// ---------------------------------------------------------------------------
// Tag / suggestion unions (base-aware, max-confidence)
// ---------------------------------------------------------------------------

const tagKey = (t: Tag): string => `${t.label} ${t.parentTag ?? ""}`;
const suggestionKey = (s: TagSuggestion): string =>
  `${s.source}:${s.parentTag ?? ""}|${s.label.toLowerCase()}`;

/** Confidence merge: 3-way so a deliberate lowering is honoured, but a
 *  both-changed tie keeps the higher confidence (deterministic, and AI
 *  re-tagging on both sides converges). */
function mergeConfidence(
  baseConf: number | undefined,
  server: number,
  client: number
): number {
  if (server === client) return server;
  if (baseConf !== undefined) {
    if (client === baseConf) return server;
    if (server === baseConf) return client;
  }
  return Math.max(server, client);
}

function mergeTags(base: Tag[], server: Tag[], client: Tag[]): Tag[] {
  return keyedMerge3(tagKey, base, server, client, (b, s, c) => ({
    label: c.label,
    parentTag: c.parentTag,
    confidence: mergeConfidence(b?.confidence, s.confidence, c.confidence),
  }));
}

function mergeSuggestions(
  base: TagSuggestion[],
  server: TagSuggestion[],
  client: TagSuggestion[]
): TagSuggestion[] {
  return keyedMerge3(suggestionKey, base, server, client, (b, s, c) => ({
    label: c.label,
    source: c.source,
    parentTag: c.parentTag,
    confidence: mergeConfidence(b?.confidence, s.confidence, c.confidence),
  }));
}

// ---------------------------------------------------------------------------
// Sub-structure merges
// ---------------------------------------------------------------------------

function mergeBucket(
  base: Bucket | undefined,
  server: Bucket,
  client: Bucket,
  ctx: Ctx
): Bucket {
  const p = `buckets[${server.id}]`;
  const b = base ?? server;
  return {
    id: server.id,
    name: scalar3(b.name, server.name, client.name, clientWins, ctx, `${p}.name`),
    colorHex: scalar3(b.colorHex, server.colorHex, client.colorHex, clientWins, ctx, `${p}.colorHex`),
    sortOrder: scalar3(b.sortOrder, server.sortOrder, client.sortOrder, minNumber, ctx, `${p}.sortOrder`),
    libraryCategoryID: scalar3(
      b.libraryCategoryID,
      server.libraryCategoryID,
      client.libraryCategoryID,
      clientWins,
      ctx,
      `${p}.libraryCategoryID`
    ),
  };
}

function mergeDistress(
  base: DistressMark | undefined,
  server: DistressMark,
  client: DistressMark,
  ctx: Ctx
): DistressMark {
  const p = `distress[${server.id}]`;
  const b = base ?? server;
  return {
    id: server.id,
    kind: scalar3(b.kind, server.kind, client.kind, clientWins, ctx, `${p}.kind`),
    points: scalar3(b.points, server.points, client.points, clientWins, ctx, `${p}.points`),
    note: scalar3(b.note, server.note, client.note, clientWins, ctx, `${p}.note`),
    createdAt: scalar3(b.createdAt, server.createdAt, client.createdAt, clientWins, ctx, `${p}.createdAt`),
  };
}

function mergeFloorPlan(
  base: FloorPlan | undefined,
  server: FloorPlan,
  client: FloorPlan,
  ctx: Ctx
): FloorPlan {
  const p = `floorPlans[${server.id}]`;
  const b = base ?? server;
  return {
    id: server.id,
    label: scalar3(b.label, server.label, client.label, clientWins, ctx, `${p}.label`),
    imageFilename: scalar3(b.imageFilename, server.imageFilename, client.imageFilename, nonNullThenClient, ctx, `${p}.imageFilename`),
    pixelsPerFoot: scalar3(b.pixelsPerFoot, server.pixelsPerFoot, client.pixelsPerFoot, clientWins, ctx, `${p}.pixelsPerFoot`),
    calibrationDistanceFeet: scalar3(b.calibrationDistanceFeet, server.calibrationDistanceFeet, client.calibrationDistanceFeet, clientWins, ctx, `${p}.calibrationDistanceFeet`),
    anchorPixelX: scalar3(b.anchorPixelX, server.anchorPixelX, client.anchorPixelX, clientWins, ctx, `${p}.anchorPixelX`),
    anchorPixelY: scalar3(b.anchorPixelY, server.anchorPixelY, client.anchorPixelY, clientWins, ctx, `${p}.anchorPixelY`),
    anchorLocalXFeet: scalar3(b.anchorLocalXFeet, server.anchorLocalXFeet, client.anchorLocalXFeet, clientWins, ctx, `${p}.anchorLocalXFeet`),
    anchorLocalYFeet: scalar3(b.anchorLocalYFeet, server.anchorLocalYFeet, client.anchorLocalYFeet, clientWins, ctx, `${p}.anchorLocalYFeet`),
    northDeg: scalar3(b.northDeg, server.northDeg, client.northDeg, clientWins, ctx, `${p}.northDeg`),
    distress: keyedMerge3(
      (d) => d.id,
      base?.distress ?? [],
      server.distress,
      client.distress,
      (db, ds, dc) => mergeDistress(db, ds, dc, ctx)
    ),
  };
}

function mergePhoto(
  base: Photo | undefined,
  server: Photo,
  client: Photo,
  ctx: Ctx
): Photo {
  const p = `photos[${server.id}]`;
  const b = base ?? server;
  const s = server;
  const c = client;
  return {
    id: s.id,
    sequenceNumber: scalar3(b.sequenceNumber, s.sequenceNumber, c.sequenceNumber, minNumber, ctx, `${p}.sequenceNumber`),
    timestamp: scalar3(b.timestamp, s.timestamp, c.timestamp, clientWins, ctx, `${p}.timestamp`),
    imageFilename: scalar3(b.imageFilename, s.imageFilename, c.imageFilename, nonNullThenClient, ctx, `${p}.imageFilename`),
    thumbnailFilename: scalar3(b.thumbnailFilename, s.thumbnailFilename, c.thumbnailFilename, nonNullThenClient, ctx, `${p}.thumbnailFilename`),
    floorPlanID: scalar3(b.floorPlanID, s.floorPlanID, c.floorPlanID, clientWins, ctx, `${p}.floorPlanID`),
    localXFeet: scalar3(b.localXFeet, s.localXFeet, c.localXFeet, clientWins, ctx, `${p}.localXFeet`),
    localYFeet: scalar3(b.localYFeet, s.localYFeet, c.localYFeet, clientWins, ctx, `${p}.localYFeet`),
    planPixelX: scalar3(b.planPixelX, s.planPixelX, c.planPixelX, clientWins, ctx, `${p}.planPixelX`),
    planPixelY: scalar3(b.planPixelY, s.planPixelY, c.planPixelY, clientWins, ctx, `${p}.planPixelY`),
    headingDegrees: scalar3(b.headingDegrees, s.headingDegrees, c.headingDegrees, clientWins, ctx, `${p}.headingDegrees`),
    positionSource: scalar3(b.positionSource, s.positionSource, c.positionSource, clientWins, ctx, `${p}.positionSource`),
    groupID: scalar3(b.groupID, s.groupID, c.groupID, clientWins, ctx, `${p}.groupID`),
    isPrimary: scalar3(b.isPrimary, s.isPrimary, c.isPrimary, clientWins, ctx, `${p}.isPrimary`),
    cameraZoom: scalar3(b.cameraZoom, s.cameraZoom, c.cameraZoom, clientWins, ctx, `${p}.cameraZoom`),
    lensName: scalar3(b.lensName, s.lensName, c.lensName, clientWins, ctx, `${p}.lensName`),
    flashMode: scalar3(b.flashMode, s.flashMode, c.flashMode, clientWins, ctx, `${p}.flashMode`),
    aiDescription: scalar3(b.aiDescription, s.aiDescription, c.aiDescription, nonNullThenClient, ctx, `${p}.aiDescription`),
    aiSeverity: scalar3(b.aiSeverity, s.aiSeverity, c.aiSeverity, nonNullThenClient, ctx, `${p}.aiSeverity`),
    aiObservation: scalar3(b.aiObservation, s.aiObservation, c.aiObservation, nonNullThenClient, ctx, `${p}.aiObservation`),
    aiFollowUp: scalar3(b.aiFollowUp, s.aiFollowUp, c.aiFollowUp, nonNullThenClient, ctx, `${p}.aiFollowUp`),
    aiAnalysis: scalar3(b.aiAnalysis, s.aiAnalysis, c.aiAnalysis, nonNullThenClient, ctx, `${p}.aiAnalysis`),
    tags: mergeTags(b.tags, s.tags, c.tags),
    pendingSuggestions: mergeSuggestions(b.pendingSuggestions, s.pendingSuggestions, c.pendingSuggestions),
    bucketID: scalar3(b.bucketID, s.bucketID, c.bucketID, clientWins, ctx, `${p}.bucketID`),
    markupOverlayFilename: scalar3(b.markupOverlayFilename, s.markupOverlayFilename, c.markupOverlayFilename, nonNullThenClient, ctx, `${p}.markupOverlayFilename`),
    markupDrawingFilename: scalar3(b.markupDrawingFilename, s.markupDrawingFilename, c.markupDrawingFilename, nonNullThenClient, ctx, `${p}.markupDrawingFilename`),
    reshootsPhotoID: scalar3(b.reshootsPhotoID, s.reshootsPhotoID, c.reshootsPhotoID, clientWins, ctx, `${p}.reshootsPhotoID`),
    isFavorite: scalar3(b.isFavorite, s.isFavorite, c.isFavorite, clientWins, ctx, `${p}.isFavorite`),
    trashedAt: scalar3(b.trashedAt, s.trashedAt, c.trashedAt, trashedAtTie, ctx, `${p}.trashedAt`),
    userCaption: scalar3(b.userCaption, s.userCaption, c.userCaption, clientWins, ctx, `${p}.userCaption`),
    userObservation: scalar3(b.userObservation, s.userObservation, c.userObservation, clientWins, ctx, `${p}.userObservation`),
    previewRotation: scalar3(b.previewRotation, s.previewRotation, c.previewRotation, clientWins, ctx, `${p}.previewRotation`),
  };
}

/**
 * Merge `photos` + `trashedPhotos` as one logical keyspace (a photo's
 * residence is decided by the merged `trashedAt`: non-null → trashed).
 * A side's struct comes from whichever array holds the id, so an edit
 * made while the other side trashed the photo still lands on the now-
 * trashed photo (no edit lost).
 */
function mergePhotoSets(
  base: Project,
  server: Project,
  client: Project,
  ctx: Ctx
): { photos: Photo[]; trashedPhotos: Photo[] } {
  const combined = (p: Project): Map<string, Photo> => {
    const m = new Map<string, Photo>();
    for (const ph of p.photos) m.set(ph.id, ph);
    for (const ph of p.trashedPhotos) if (!m.has(ph.id)) m.set(ph.id, ph);
    return m;
  };
  const bMap = combined(base);
  const sMap = combined(server);
  const cMap = combined(client);

  const photos: Photo[] = [];
  const trashed: Photo[] = [];
  const place = (ph: Photo): void => {
    if (ph.trashedAt !== null) trashed.push(ph);
    else photos.push(ph);
  };
  const emitted = new Set<string>();
  const consider = (id: string): void => {
    if (emitted.has(id)) return;
    emitted.add(id);
    const b = bMap.get(id);
    const s = sMap.get(id);
    const c = cMap.get(id);
    if (s !== undefined && c !== undefined) {
      place(mergePhoto(b, s, c, ctx));
    } else if (s !== undefined) {
      if (b !== undefined && deepEqual(s, b)) return; // client hard-deleted, server unchanged
      place(s);
    } else if (c !== undefined) {
      if (b !== undefined && deepEqual(c, b)) return;
      place(c);
    }
  };
  // Client order first (active then trashed), then server-only survivors.
  for (const ph of client.photos) consider(ph.id);
  for (const ph of client.trashedPhotos) consider(ph.id);
  for (const ph of server.photos) consider(ph.id);
  for (const ph of server.trashedPhotos) consider(ph.id);
  return { photos, trashedPhotos: trashed };
}

// ---------------------------------------------------------------------------
// Additive record/array unions (tagSelection, aiExtraVocabulary)
// ---------------------------------------------------------------------------

function unionStrings(client: string[], server: string[]): string[] {
  const out = [...client];
  const seen = new Set(client);
  for (const x of server) if (!seen.has(x)) { seen.add(x); out.push(x); }
  return out;
}

function unionRecordOfArrays(
  server: Record<string, string[]>,
  client: Record<string, string[]>
): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const k of Object.keys(client)) out[k] = [...(client[k] ?? [])];
  for (const k of Object.keys(server)) {
    const existing = out[k];
    const sv = server[k] ?? [];
    out[k] = existing ? unionStrings(existing, sv) : [...sv];
  }
  return out;
}

function mergeTagSelection(
  server: ProjectTagSelection | null,
  client: ProjectTagSelection | null
): ProjectTagSelection | null {
  if (server === null && client === null) return null;
  if (server === null) return client;
  if (client === null) return server;
  return {
    contextIDs: unionStrings(client.contextIDs, server.contextIDs),
    primariesByContext: unionRecordOfArrays(server.primariesByContext, client.primariesByContext),
    deselectedSecondariesByPrimary: unionRecordOfArrays(
      server.deselectedSecondariesByPrimary,
      client.deselectedSecondariesByPrimary
    ),
  };
}

function mergeExtraVocab(
  server: ProjectExtraVocabulary | null,
  client: ProjectExtraVocabulary | null
): ProjectExtraVocabulary | null {
  if (server === null && client === null) return null;
  if (server === null) return client;
  if (client === null) return server;
  const keyOf = (r: Record<string, unknown>): string =>
    typeof r.id === "string" ? `id:${r.id}` : `j:${JSON.stringify(r)}`;
  const out: Array<Record<string, unknown>> = [];
  const seen = new Set<string>();
  for (const r of client.primaries) {
    const k = keyOf(r);
    if (!seen.has(k)) { seen.add(k); out.push(r); }
  }
  for (const r of server.primaries) {
    const k = keyOf(r);
    if (!seen.has(k)) { seen.add(k); out.push(r); }
  }
  return { primaries: out };
}

// ---------------------------------------------------------------------------
// Top-level manifest merge
// ---------------------------------------------------------------------------

/**
 * 3-way merge of a project manifest.
 *
 * @param base   The manifest the writing client started from.
 * @param server The current stored manifest (source of truth).
 * @param client The writing client's edited manifest.
 */
export function mergeManifest(
  base: Project,
  server: Project,
  client: Project
): { merged: Project; report: MergeReport } {
  const ctx = new Ctx();

  const floorPlans = keyedMerge3(
    (f) => f.id,
    base.floorPlans,
    server.floorPlans,
    client.floorPlans,
    (b, s, c) => mergeFloorPlan(b, s, c, ctx)
  );
  const floorPlanIds = new Set(floorPlans.map((f) => f.id));

  const { photos, trashedPhotos } = mergePhotoSets(base, server, client, ctx);

  // activeFloorPlanID: client wins, but null it out if the chosen plan
  // didn't survive the merge.
  let activeFloorPlanID = scalar3(
    base.activeFloorPlanID,
    server.activeFloorPlanID,
    client.activeFloorPlanID,
    clientWins,
    ctx,
    "activeFloorPlanID"
  );
  if (activeFloorPlanID !== null && !floorPlanIds.has(activeFloorPlanID)) {
    activeFloorPlanID = null;
  }

  const merged: Project = {
    id: server.id,
    name: scalar3(base.name, server.name, client.name, clientWins, ctx, "name"),
    // createdAt is immutable; if they somehow differ keep the earliest.
    createdAt: server.createdAt <= client.createdAt ? server.createdAt : client.createdAt,
    startedAt: scalar3(base.startedAt, server.startedAt, client.startedAt, laterIso, ctx, "startedAt"),
    lastResumedAt: scalar3(base.lastResumedAt, server.lastResumedAt, client.lastResumedAt, laterIso, ctx, "lastResumedAt"),
    lastStoppedAt: scalar3(base.lastStoppedAt, server.lastStoppedAt, client.lastStoppedAt, laterIso, ctx, "lastStoppedAt"),
    stopped: scalar3(base.stopped, server.stopped, client.stopped, trueWins, ctx, "stopped"),
    isDeleted: scalar3(base.isDeleted, server.isDeleted, client.isDeleted, trueWins, ctx, "isDeleted"),
    isFrozen: scalar3(base.isFrozen, server.isFrozen, client.isFrozen, trueWins, ctx, "isFrozen"),
    projectGPS: scalar3(base.projectGPS, server.projectGPS, client.projectGPS, gpsTie, ctx, "projectGPS"),
    projectAddress: scalar3(base.projectAddress, server.projectAddress, client.projectAddress, nonNullThenClient, ctx, "projectAddress"),
    photos,
    trashedPhotos,
    floorPlans,
    activeFloorPlanID,
    folderName: scalar3(base.folderName, server.folderName, client.folderName, nonNullThenClient, ctx, "folderName"),
    aiInstructions: scalar3(base.aiInstructions, server.aiInstructions, client.aiInstructions, clientWins, ctx, "aiInstructions"),
    buckets: keyedMerge3(
      (bk) => bk.id,
      base.buckets,
      server.buckets,
      client.buckets,
      (b, s, c) => mergeBucket(b, s, c, ctx)
    ),
    tagSelection: mergeTagSelection(server.tagSelection, client.tagSelection),
    aiExtraVocabulary: mergeExtraVocab(server.aiExtraVocabulary, client.aiExtraVocabulary),
    // Never downgrade the stored schema version.
    manifestSchemaVersion: Math.max(server.manifestSchemaVersion, client.manifestSchemaVersion),
  };

  return { merged, report: { conflicts: ctx.conflicts } };
}
