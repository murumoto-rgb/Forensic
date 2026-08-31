import Fastify, { type FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const ids = { project: "11111111-1111-4111-8111-111111111111", photo: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", plan: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", bucket: "cccccccc-cccc-4ccc-8ccc-cccccccccccc" };
const photo = (overrides: Record<string, unknown> = {}) => ({ id: ids.photo, sequenceNumber: 1, timestamp: "2026-08-30T00:00:00Z", imageFilename: "photo.jpg", thumbnailFilename: null, positionSource: "none", isPrimary: false, cameraZoom: 1, flashMode: "auto", tags: [], pendingSuggestions: [], isFavorite: false, previewRotation: 0, userCaption: null, userObservation: null, aiAnalysis: null, bucketID: "deleted-bucket", markupOverlayFilename: null, markupDrawingFilename: null, ...overrides });
const baseProject = (p = photo()) => ({ id: ids.project, name: "Case", photos: [p], floorPlans: [], buckets: [], manifestSchemaVersion: 4 });
const state = vi.hoisted(() => ({ manifest: null as any, files: [] as any[], revision: "revision-snapshot", projectSelects: [] as string[], replaceSnapshotOnRegistryRead: false, presigns: [] as string[] }));

vi.mock("../src/middleware/auth.js", () => ({ authPlugin: async (app: any) => { app.decorateRequest("user", null); app.addHook("preHandler", async (req: any) => { req.user = { id: "33333333-3333-4333-8333-333333333333" }; }); } }));
vi.mock("../src/access.js", () => ({ assertProjectAccess: vi.fn(async () => undefined), sendAccessError: vi.fn(() => false) }));
vi.mock("../src/r2.js", () => ({ presignedGet: vi.fn(async ({ objectKey }: any) => { state.presigns.push(objectKey); return `https://storage.invalid/${objectKey}`; }), deleteObjects: vi.fn() }));
vi.mock("../src/resourceLimits.js", () => ({ sendExportLimit: vi.fn() }));
vi.mock("../src/supabase.js", () => ({ supabaseAdmin: { from: (table: string) => {
  const filters: any[] = [];
  const equal = (a: unknown, b: unknown) => typeof a === "string" && typeof b === "string" ? a.toLowerCase() === b.toLowerCase() : a === b;
  const run = async (single = false) => {
    if (table === "projects") return { data: single ? { manifest: state.manifest, revision: state.revision } : [{ manifest: state.manifest, revision: state.revision }], error: null };
    if (table !== "current_project_files") throw new Error(`Unexpected table ${table}`);
    if (state.replaceSnapshotOnRegistryRead) { state.manifest = { ...state.manifest, name: "Later project name" }; state.revision = "revision-later"; }
    const data = state.files.filter(row => filters.every(([key, value]) => Array.isArray(value) ? value.some(item => equal(item, row[key])) : equal(row[key], value)));
    return { data: single ? data[0] ?? null : data, error: null };
  };
  const q: any = { select: (fields: string) => { if (table === "projects") state.projectSelects.push(fields); return q; }, eq: (k: string, v: any) => { filters.push([k, v]); return q; }, in: (k: string, v: any[]) => { filters.push([k, v]); return q; }, order: () => q, limit: () => q, maybeSingle: () => run(true), then: (resolve: any, reject: any) => run().then(resolve, reject) };
  return q;
} } }));
import { projectExportsRoute } from "../src/routes/projectExports.js";

const kinds = ["photo", "plan", "markup_png", "markup_drawing"] as const;
function completeFixture() {
  state.manifest = baseProject(photo({ markupOverlayFilename: "overlay.png", markupDrawingFilename: "strokes.json" }));
  state.manifest.floorPlans = [{ id: ids.plan, imageFilename: "plan.png", label: "Floor", pixelsPerFoot: 1, calibrationDistanceFeet: 1, northDeg: 0, distress: [] }];
  state.files = [
    { project_id: ids.project, photo_id: ids.photo, object_key: "photo-key", kind: "photo", size_bytes: 10, source_filename: "photo.jpg" },
    { project_id: ids.project, photo_id: ids.plan, object_key: "plan-key", kind: "plan", size_bytes: 40, source_filename: "plan.png" },
    { project_id: ids.project, photo_id: ids.photo, object_key: "overlay-key", kind: "markup_png", size_bytes: 20, source_filename: "overlay.png" },
    { project_id: ids.project, photo_id: ids.photo, object_key: "drawing-key", kind: "markup_drawing", size_bytes: 30, source_filename: "strokes.json" },
  ];
}
let app: FastifyInstance;
beforeEach(async () => {
  state.files = []; state.manifest = baseProject(); state.revision = "revision-snapshot"; state.projectSelects = []; state.presigns = []; state.replaceSnapshotOnRegistryRead = false;
  app = Fastify(); app.addHook("onRequest", async (req: any) => { req.user = { id: "33333333-3333-4333-8333-333333333333" }; });
  await app.register(projectExportsRoute); await app.ready();
});
afterEach(async () => { await app.close(); });
const request = () => app.inject({ method: "GET", url: `/v1/projects/${ids.project}/folder-export-manifest` });

describe("folder export manifest completeness and snapshot binding", () => {
  it("returns 409 instead of silently dropping a missing registry row", async () => {
    const response = await request();
    expect(response.statusCode, response.body).toBe(409); expect(response.json().details.missing).toContain(`photo ${ids.photo}`); expect(state.presigns).toEqual([]);
  });
  it("includes all required assets and normalizes unknown buckets to unbucketed", async () => {
    completeFixture();
    const response = await request();
    expect(response.statusCode, response.body).toBe(200); const manifest = response.json().manifest;
    expect(manifest.photos).toHaveLength(1); expect(manifest.photos[0].bucketId).toBeNull();
    expect(manifest.unbucketedFolderName).toBe("99 Unbucketed"); expect(manifest.attachments).toHaveLength(2); expect(manifest.plans).toHaveLength(1); expect(manifest.totalSizeBytes).toBe(100);
    expect(state.presigns.sort()).toEqual(["drawing-key", "overlay-key", "photo-key", "plan-key"]);
    expect(manifest.revision).toBe("revision-snapshot");
  });
  it.each(kinds.flatMap(kind => [null, "replacement.bin"].map(filename => [kind, filename] as const)))
  ("returns 409 before any presign when %s filename is %s", async (kind, filename) => {
    completeFixture(); state.files.find(row => row.kind === kind).source_filename = filename;
    const response = await request();
    expect(response.statusCode, response.body).toBe(409);
    expect(response.json().error).toBe("export_incomplete");
    expect(response.json().details.filenameMismatches).toHaveLength(1);
    expect(response.json().message).toContain("filename differs from the export snapshot");
    expect(state.presigns).toEqual([]);
  });
  it("uses canonical bucket IDs so mixed UUID case still matches the browser bucket map", async () => {
    completeFixture();
    state.manifest.photos[0].id = ids.photo.toUpperCase();
    state.manifest.photos[0].bucketID = ids.bucket.toUpperCase();
    state.manifest.floorPlans[0].id = ids.plan.toUpperCase();
    state.manifest.buckets = [{ id: ids.bucket, name: "Evidence", sortOrder: 0 }];
    const response = await request(); expect(response.statusCode, response.body).toBe(200);
    const manifest = response.json().manifest;
    const folderById = new Map(manifest.buckets.map((bucket: any) => [bucket.id, bucket.folderName]));
    expect(folderById.get(manifest.photos[0].bucketId)).toBe("01 Evidence");
    expect(state.presigns).toHaveLength(4);
  });
  it("returns the revision read with the manifest even if the live project changes during file lookup", async () => {
    completeFixture(); state.replaceSnapshotOnRegistryRead = true;
    const response = await request(); expect(response.statusCode, response.body).toBe(200);
    expect(response.json().manifest).toMatchObject({ projectName: "Case", revision: "revision-snapshot" });
    expect(state.revision).toBe("revision-later"); expect(state.projectSelects).toEqual(["manifest, revision"]);
  });
});
