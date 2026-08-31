import { Readable } from "node:stream";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PhotoSchema, ProjectSchema, type Project } from "@forensic/shared";

type FailureMode = "missing" | "short" | "long" | "error";
interface FileRow { project_id: string; photo_id: string; kind: string; object_key: string; size_bytes: number; source_filename: string | null }
const state = vi.hoisted(() => ({
  project: null as unknown as Project, files: [] as FileRow[], failures: new Map<string, FailureMode>(),
  reads: [] as string[], completed: [] as string[], consumed: new Map<string, number>(),
  updates: [] as Array<Record<string, unknown>>, aborts: 0, dones: 0, active: 0, maxActive: 0,
  zipSize: 123 as number | null, uploaded: [] as Buffer[],
  bodyOverrides: new Map<string, Buffer>(),
  lookupSizes: [] as number[], failLookup: 0,
}));
vi.mock("../src/supabase.js", () => ({ supabaseAdmin: { from: (table: string) => {
  const filters: Array<[string, unknown]> = [];
  const equal = (a: unknown, b: unknown) => typeof a === "string" && typeof b === "string" ? a.toLowerCase() === b.toLowerCase() : a === b;
  const run = async (single = false) => {
    if (table === "projects") return { data: single ? { manifest: state.project } : [{ manifest: state.project }], error: null };
    if (table === "project_exports") return { data: single ? null : [], error: null };
    if (table !== "current_project_files") throw new Error(`Unexpected table ${table}`);
    const requestedIds = filters.find(([key]) => key === "photo_id")?.[1] as string[];
    state.lookupSizes.push(requestedIds.length);
    if (requestedIds.length > 100 || state.lookupSizes.length === state.failLookup) return { data: null, error: { message: "Registry query failed" } };
    // PostgreSQL UUID comparisons are case-insensitive, unlike JS map keys.
    const rows = state.files.filter(row => filters.every(([key, value]) => Array.isArray(value)
      ? value.some(item => equal(item, row[key as keyof FileRow])) : equal(row[key as keyof FileRow], value)));
    return { data: rows, error: null };
  };
  const q = { select: () => q, eq: (key: string, value: unknown) => { filters.push([key, value]); return q; }, in: (key: string, value: unknown[]) => { filters.push([key, value]); return q; }, order: () => q, limit: () => q, update: (value: Record<string, unknown>) => { state.updates.push(value); return q; }, maybeSingle: () => run(true), then: (resolve: never, reject: never) => run().then(resolve, reject) };
  return q;
} } }));
vi.mock("../src/r2.js", () => ({ r2: {}, r2Bucket: "test", getObjectSize: async () => state.zipSize, getObjectStream: async (key: string) => {
  state.reads.push(key);
  const mode = state.failures.get(key);
  if (mode === "missing") throw new Error(`missing object ${key}`);
  state.active++; state.maxActive = Math.max(state.maxActive, state.active);
  async function* body() {
    try {
      // Allow queued sidecar/archive events to fire between individual chunks.
      const bytes = state.bodyOverrides.get(key) ?? Buffer.from(mode === "short" ? "ab" : mode === "long" ? "abcd" : "abc");
      yield bytes.subarray(0, 1); state.consumed.set(key, 1);
      await new Promise(resolve => setTimeout(resolve, 1));
      yield bytes.subarray(1); state.consumed.set(key, bytes.length);
      if (mode === "error") throw new Error(`mid-stream failure ${key}`);
      if (mode === undefined) state.completed.push(key);
    } finally { state.active--; }
  }
  return Readable.from(body());
} }));
vi.mock("@aws-sdk/lib-storage", () => ({ Upload: class {
  body: Readable;
  constructor(args: { params: { Body: Readable } }) { this.body = args.params.Body; }
  done() { state.dones++; return (async () => { for await (const bytes of this.body) state.uploaded.push(Buffer.from(bytes)); return {}; })(); }
  async abort() { state.aborts++; }
} }));
vi.mock("../src/sentry.js", () => ({ captureException: vi.fn() }));
import { runFolderExportJob } from "../src/exports/folderBundleWorker.js";

const pid = "11111111-1111-4111-8111-111111111111";
const photoId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const planId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const bucketId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const job = { id: "33333333-3333-4333-8333-333333333333", project_id: pid, options: {}, kind: "folder" as const, status: "running" as const, created_by: pid, object_key: null, size_bytes: null, error_message: null, created_at: "2026-08-30T00:00:00Z", started_at: null, completed_at: null, progress_done: null, progress_total: null };
const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() } as any;
const original: FileRow = { project_id: pid, photo_id: photoId, kind: "photo", object_key: "photo-key", size_bytes: 3, source_filename: "photo.jpg" };
const kinds = ["photo", "markup_png", "markup_drawing", "plan"] as const;
function allAssets() {
  state.project.photos[0]!.markupOverlayFilename = "overlay.png";
  state.project.photos[0]!.markupDrawingFilename = "drawing.data";
  state.project.floorPlans = [{ id: planId, label: "Plan", imageFilename: "plan.png", pixelsPerFoot: 1, calibrationDistanceFeet: 1, anchorPixelX: 0, anchorPixelY: 0, anchorLocalXFeet: 0, anchorLocalYFeet: 0, northDeg: 0, distress: [] }];
  state.files = [{ ...original },
    { ...original, kind: "markup_png", object_key: "overlay-key", source_filename: "overlay.png" },
    { ...original, kind: "markup_drawing", object_key: "drawing-key", source_filename: "drawing.data" },
    { ...original, photo_id: planId, kind: "plan", object_key: "plan-key", source_filename: "plan.png" },
  ];
}
function largeFixture() {
  allAssets();
  const firstPhoto = state.project.photos[0]!; const firstPlan = state.project.floorPlans[0]!;
  state.project.photos = []; state.project.floorPlans = []; state.files = [];
  for (let i = 0; i < 205; i++) {
    const photoId = `aaaaaaaa-aaaa-4aaa-8aaa-${String(i).padStart(12, "0")}`;
    const planId = `bbbbbbbb-bbbb-4bbb-8bbb-${String(i).padStart(12, "0")}`;
    state.project.photos.push({ ...firstPhoto, id: photoId.toUpperCase(), sequenceNumber: i + 1, imageFilename: `photo-${i}.jpg`, markupOverlayFilename: `overlay-${i}.png`, markupDrawingFilename: `drawing-${i}.data` });
    state.project.floorPlans.push({ ...firstPlan, id: planId.toUpperCase(), imageFilename: `plan-${i}.png`, label: `Plan ${i}` });
    for (const [kind, entityId, filename] of [["photo", photoId, `photo-${i}.jpg`], ["plan", planId, `plan-${i}.png`], ["markup_png", photoId, `overlay-${i}.png`], ["markup_drawing", photoId, `drawing-${i}.data`]] as const) {
      state.files.push({ project_id: pid, photo_id: entityId, object_key: `${kind}-${i}`, kind, size_bytes: 3, source_filename: filename });
    }
  }
}
function zipEntries(): Array<{ name: string; bytes: number }> {
  const zip = Buffer.concat(state.uploaded); const entries: Array<{ name: string; bytes: number }> = [];
  // Read actual central-directory records, not the worker's append arguments.
  let offset = zip.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  while (offset >= 0 && zip.readUInt32LE(offset) === 0x02014b50) {
    const length = zip.readUInt16LE(offset + 28);
    entries.push({ name: zip.subarray(offset + 46, offset + 46 + length).toString(), bytes: zip.readUInt32LE(offset + 24) });
    offset += 46 + length + zip.readUInt16LE(offset + 30) + zip.readUInt16LE(offset + 32);
  }
  return entries;
}
function expectAborted() { expect(state.aborts).toBe(1); expect(state.updates.some(update => update.status === "done")).toBe(false); }
beforeEach(() => {
  state.project = ProjectSchema.parse({ id: pid, name: "Case", createdAt: "2026-08-30T00:00:00Z", stopped: false, photos: [PhotoSchema.parse({ id: photoId, sequenceNumber: 1, timestamp: "2026-08-30T00:00:00Z", imageFilename: "photo.jpg", positionSource: "none", isPrimary: false, cameraZoom: 1, flashMode: "auto", tags: [], pendingSuggestions: [], isFavorite: false, previewRotation: 0 })], trashedPhotos: [], floorPlans: [], buckets: [], manifestSchemaVersion: 4 });
  state.files = [{ ...original }]; state.failures.clear(); state.reads = []; state.completed = []; state.consumed.clear();
  state.updates = []; state.aborts = 0; state.dones = 0; state.active = 0; state.maxActive = 0; state.zipSize = 123; state.uploaded = [];
  state.bodyOverrides.clear();
  state.lookupSizes = []; state.failLookup = 0;
});

describe("folder export worker snapshot and streaming boundaries", () => {
  it("chunks large photo/markup and plan lookups while retaining every actual ZIP entry", async () => {
    largeFixture();
    await runFolderExportJob(job, log);
    expect(state.lookupSizes).toEqual([100, 100, 5, 100, 100, 5]);
    expect(state.reads).toHaveLength(820); expect(state.completed).toEqual(state.reads); expect(state.maxActive).toBe(1);
    expect(state.reads.slice(612, 615)).toEqual(["photo-204", "markup_png-204", "markup_drawing-204"]);
    expect(state.reads.at(-1)).toBe("plan-204");
    const entries = zipEntries(); expect(entries).toHaveLength(822);
    expect(entries).toEqual(expect.arrayContaining([
      { name: "99 Unbucketed/Case - 205 - 260830.jpg", bytes: 3 },
      { name: "01 Markups/overlay-204.png", bytes: 3 }, { name: "01 Markups/drawing-204.data", bytes: 3 },
      { name: "00 Floor Plans/205 Plan 204.png", bytes: 3 },
    ]));
    expect(state.updates).toContainEqual({ progress_done: 820 });
    expect(state.updates.at(-1)).toMatchObject({ status: "done" });
  });
  it.each([2, 5])("aborts without Done if registry chunk %s fails", async chunk => {
    largeFixture(); state.failLookup = chunk;
    await expect(runFolderExportJob(job, log)).rejects.toThrow(/Registry query failed/);
    expect(state.lookupSizes).toHaveLength(chunk); expect(state.lookupSizes.every(size => size <= 100)).toBe(true);
    expectAborted();
    if (chunk === 2) expect(state.reads).toEqual([]);
    else { expect(state.completed).toHaveLength(615); expect(state.reads.some(key => key.startsWith("plan-"))).toBe(false); }
  });
  it("aborts multipart when the original registration is missing", async () => {
    state.files = [];
    await expect(runFolderExportJob(job, log)).rejects.toThrow(/Missing required photo/);
    expectAborted(); expect(state.reads).toEqual([]);
  });
  it("consumes original, overlay, drawing and plan serially and includes each in the actual ZIP", async () => {
    allAssets();
    await runFolderExportJob(job, log);
    expect(state.reads).toEqual(["photo-key", "overlay-key", "drawing-key", "plan-key"]);
    expect(state.completed).toEqual(state.reads); expect(state.maxActive).toBe(1); expect(state.active).toBe(0);
    expect(state.updates[0]).toMatchObject({ progress_total: 4, progress_done: 0 });
    expect(state.updates).toContainEqual({ progress_done: 4 });
    expect(state.updates.at(-1)).toMatchObject({ status: "done", size_bytes: 123 });
    expect(state.aborts).toBe(0); expect(state.dones).toBe(1);
    expect(zipEntries()).toEqual(expect.arrayContaining([
      { name: "99 Unbucketed/Case - 1 - 260830.jpg", bytes: 3 },
      { name: "01 Markups/overlay.png", bytes: 3 }, { name: "01 Markups/drawing.data", bytes: 3 },
      { name: "00 Floor Plans/01 Plan.png", bytes: 3 },
    ]));
  });
  it.each(kinds.flatMap(kind => (["short", "long", "missing", "error"] as FailureMode[]).map(mode => [kind, mode] as const)))
  ("targets %s %s failure after earlier assets succeed, aborting without Done", async (kind, mode) => {
    allAssets();
    const target = state.files.find(row => row.kind === kind)!;
    state.failures.set(target.object_key, mode);
    await expect(runFolderExportJob(job, log)).rejects.toThrow(new RegExp(target.object_key));
    expectAborted();
    expect(state.reads.at(-1)).toBe(target.object_key);
    expect(state.updates[0]).toMatchObject({ progress_total: 4, progress_done: 0 });
    expect(state.updates).not.toContainEqual({ progress_done: 4 });
    if (kind !== "photo") { expect(state.completed).toContain("photo-key"); expect(state.consumed.get("photo-key")).toBe(3); }
    if (kind === "plan") expect(state.completed).toEqual(["photo-key", "overlay-key", "drawing-key"]);
    expect(state.maxActive).toBeLessThanOrEqual(1);
    await vi.waitFor(() => expect(state.active).toBe(0));
  });
  it.each(kinds.flatMap(kind => [null, "concurrently-replaced.bin"].map(filename => [kind, filename] as const)))
  ("rejects %s registration with snapshot filename %s before reading that object", async (kind, filename) => {
    allAssets();
    const target = state.files.find(row => row.kind === kind)!; target.source_filename = filename;
    await expect(runFolderExportJob(job, log)).rejects.toThrow(/filename changed or is unverified/);
    expectAborted(); expect(state.reads).not.toContain(target.object_key);
  });
  it("normalizes mixed-case bucket and selected-photo UUIDs without omitting an archive entry", async () => {
    state.project.photos[0]!.bucketID = bucketId.toUpperCase();
    state.project.buckets = [{ id: bucketId, name: "Evidence", sortOrder: 0, colorHex: "#123456", libraryCategoryID: null }];
    state.project.photos[0]!.id = photoId.toUpperCase();
    await runFolderExportJob({ ...job, options: { scope: "selected", selectedPhotoIds: [photoId] } }, log);
    expect(state.reads).toEqual(["photo-key"]);
    expect(zipEntries()).toContainEqual({ name: "01 Evidence/Case - 1 - 260830.jpg", bytes: 3 });
    expect(state.updates).toContainEqual({ progress_done: 1 });
  });
  it("drains each bucket sidecar before opening the next source body", async () => {
    const secondId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    state.project.photos.push({ ...state.project.photos[0]!, id: secondId, sequenceNumber: 2, imageFilename: "second.jpg" });
    state.project.photos[0]!.bucketID = bucketId;
    state.project.buckets = [{ id: bucketId, name: "Evidence", sortOrder: 0, colorHex: "#123456", libraryCategoryID: null }];
    state.files.push({ ...original, photo_id: secondId, object_key: "second-key", source_filename: "second.jpg" });
    await runFolderExportJob(job, log);
    expect(state.completed).toEqual(["photo-key", "second-key"]); expect(state.maxActive).toBe(1);
    expect(zipEntries().filter(entry => entry.name.endsWith(".jpg"))).toHaveLength(2);
  });
  it.each([null, 0, -1, Number.NaN])("refuses Done when final ZIP HEAD size is %s", async size => {
    state.zipSize = size;
    await expect(runFolderExportJob(job, log)).rejects.toThrow(/Uploaded ZIP is unavailable/);
    expect(state.completed).toEqual(["photo-key"]); expectAborted();
  });
  it.each(kinds)("rejects a zero-byte %s registration even if its body is also empty", async kind => {
    allAssets();
    const target = state.files.find(row => row.kind === kind)!;
    target.size_bytes = 0; state.bodyOverrides.set(target.object_key, Buffer.alloc(0));
    await expect(runFolderExportJob(job, log)).rejects.toThrow(/invalid registered size/);
    expectAborted(); expect(state.reads).not.toContain(target.object_key);
  });
  it.each(["identical markup", "truncated markup", "identical photo"])("rejects %s archive-path collisions before starting any upload or append", async collision => {
    const secondId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    const second = { ...state.project.photos[0]!, id: secondId, sequenceNumber: collision === "identical photo" ? 1 : 2, imageFilename: "second.jpg" };
    state.project.photos.push(second);
    state.files.push({ ...original, photo_id: secondId, object_key: "second-key", source_filename: "second.jpg" });
    if (collision !== "identical photo") {
      const firstName = collision === "truncated markup" ? `${"a".repeat(80)}-first.png` : "overlay.png";
      const secondName = collision === "truncated markup" ? `${"a".repeat(80)}-second.png` : "overlay.png";
      state.project.photos[0]!.markupOverlayFilename = firstName; second.markupOverlayFilename = secondName;
      state.files.push({ ...original, kind: "markup_png", object_key: "first-overlay", source_filename: firstName },
        { ...original, photo_id: secondId, kind: "markup_png", object_key: "second-overlay", source_filename: secondName });
    }
    await expect(runFolderExportJob(job, log)).rejects.toThrow(/Duplicate export path/);
    expect(state.dones).toBe(0); expect(state.reads).toEqual([]); expect(state.uploaded).toEqual([]);
    expect(state.updates.some(update => update.status === "done")).toBe(false);
  });
});
