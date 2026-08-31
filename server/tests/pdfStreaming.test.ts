import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { Readable } from "node:stream";
import { PDFDocument } from "pdf-lib";
import type { FastifyBaseLogger } from "fastify";
import { PhotoSchema, ProjectSchema, type Project } from "@forensic/shared";

const state = vi.hoisted(() => ({
  files: [] as Array<{ photo_id: string; kind: string; object_key: string; size_bytes: number; source_filename: string }>,
  reads: [] as string[], events: [] as string[], active: 0, maxActive: 0,
  badKey: "", malformedKey: "", registryError: false, imagesReady: true,
  updates: [] as Array<Record<string, unknown>>, uploads: 0, pdfCalls: 0, brandingCalls: 0, brandingError: false,
  customBytes: new Map<string, Buffer>(), html: [] as string[], printOptions: [] as Array<Record<string, unknown>>,
  project: null as unknown as Project, image: null as unknown as Buffer, pdf: null as unknown as Uint8Array,
}));
vi.mock("../src/supabase.js", () => ({ supabaseAdmin: { from: (table: string) => {
  let payload: Record<string, unknown> | null = null;
  const filters: Array<[string, unknown[]]> = [];
  const execute = () => {
    if (table === "pdf_export_jobs") { if (payload) state.updates.push(payload); return { data: null, error: null }; }
    if (table === "projects") return { data: { manifest: state.project }, error: null };
    if (table === "current_project_files") return { data: state.files.filter(row => filters.every(([key, values]) => key === "project_id" || values.includes(row[key as keyof typeof row]))), error: state.registryError ? new Error("registry unavailable") : null };
    throw new Error(`Unexpected table ${table}`);
  };
  const query = { select() { return query; }, eq(key: string, value: unknown) { filters.push([key, [value]]); return query; }, in(key: string, values: unknown[]) { filters.push([key, values]); return query; }, update(value: Record<string, unknown>) { payload = value; return query; }, maybeSingle() { return Promise.resolve(execute()); }, then(resolve: never, reject: never) { return Promise.resolve(execute()).then(resolve, reject); } };
  return query;
} } }));
vi.mock("../src/r2.js", () => ({
  getObjectStream: async (key: string) => {
    state.reads.push(key); state.events.push(`read:${key}`);
    if (key === state.badKey) throw new Error("Required object missing");
    const bytes = state.customBytes.get(key) ?? (key === state.malformedKey ? Buffer.alloc(state.image.length) : state.image);
    return Readable.from((async function* () {
      state.active++; state.maxActive = Math.max(state.active, state.maxActive);
      try { await new Promise(resolve => setTimeout(resolve, 1)); yield bytes; }
      finally { state.active--; }
    })());
  },
  putObjectBytes: async () => { state.uploads++; },
}));
vi.mock("../src/reportBranding.js", () => ({ loadReportBrandingForExport: async () => { state.brandingCalls++; if (state.brandingError) throw new Error("Configured report logo missing"); return { titleOverride: "Firm report", subtitleOverride: "Verified review", footerOverride: "Private", logoDataUrl: null }; } }));
vi.mock("../src/sentry.js", () => ({ captureException: () => {} }));
vi.mock("puppeteer", () => ({ default: { launch: async () => ({ connected: true, close: async () => {}, newPage: async () => ({
  setContent: async (html: string) => { state.html.push(html); }, evaluate: async () => state.imagesReady,
  pdf: async (options: Record<string, unknown>) => { state.printOptions.push(options); state.pdfCalls++; state.events.push("pdf"); return state.pdf; }, close: async () => {},
}) }) } }));
import { renderReportChunks, PAGES_PER_CHUNK } from "../src/exports/htmlReport.js";
import { applyOptionDefaults } from "../src/exports/options.js";
import { processPdfExportJob } from "../src/exports/pdfWorker.js";
const log = { info() {}, warn() {}, error() {} } as unknown as FastifyBaseLogger;
const pid = "33333333-3333-4333-8333-333333333333";
const id = (i: number) => `44444444-4444-4444-8444-${String(i).padStart(12, "0")}`;
const options = () => applyOptionDefaults({ perPage: 1, includeCoverPage: false, includeMetadataTable: false, includeFloorPlanPages: false });
function fixture(count: number) {
  const project = ProjectSchema.parse({ id: pid, name: "Synthetic report", createdAt: "2026-08-30T00:00:00Z", stopped: false, photos: Array.from({ length: count }, (_, i) => PhotoSchema.parse({
    id: id(i), sequenceNumber: i + 1, timestamp: "2026-08-30T00:00:00Z", imageFilename: `${i}.png`, positionSource: "none", isPrimary: true, cameraZoom: 1, flashMode: "auto", tags: [], pendingSuggestions: [], isFavorite: false, previewRotation: 0,
  })), trashedPhotos: [], floorPlans: [], buckets: [], manifestSchemaVersion: 4 });
  state.files = project.photos.map(photo => ({ photo_id: photo.id, kind: "photo", object_key: photo.imageFilename, source_filename: photo.imageFilename, size_bytes: state.image.length }));
  state.project = project;
  return project;
}
beforeAll(async () => {
  state.image = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==", "base64");
  const pdf = await PDFDocument.create(); pdf.addPage([100, 100]); state.pdf = await pdf.save();
});
beforeEach(() => {
  state.files = []; state.reads = []; state.events = []; state.active = 0; state.maxActive = 0;
  state.badKey = ""; state.malformedKey = ""; state.registryError = false; state.imagesReady = true;
  state.updates = []; state.uploads = 0; state.pdfCalls = 0; state.brandingCalls = 0; state.brandingError = false; state.customBytes.clear(); state.html = []; state.printOptions = [];
});

describe("bounded report production with consumer backpressure", () => {
  it("fetches only one bounded batch before the consumer requests another", async () => {
    const project = fixture(35);
    const iterator = renderReportChunks(project, pid, log, options());
    expect(state.reads).toHaveLength(0);
    const first = await iterator.next();
    expect(first.done).toBe(false);
    expect(state.reads).toHaveLength(PAGES_PER_CHUNK);
    expect(state.maxActive).toBeLessThanOrEqual(6);
    expect(first.value!.match(/class="page contact-sheet"/g)).toHaveLength(PAGES_PER_CHUNK);
    await new Promise(resolve => setTimeout(resolve, 5));
    expect(state.reads).toHaveLength(PAGES_PER_CHUNK);
    await iterator.return(undefined);
    expect(state.reads).toHaveLength(PAGES_PER_CHUNK);
  });
  it("groups globally, preserving photo order and exactly one divider across chunk boundaries", async () => {
    const project = fixture(27);
    const firstBucket = "55555555-5555-4555-8555-555555555555";
    const secondBucket = "66666666-6666-4666-8666-666666666666";
    project.buckets = [{ id: secondBucket, name: "Second", sortOrder: 2, colorHex: "#112233", libraryCategoryID: null }, { id: firstBucket, name: "First", sortOrder: 1, colorHex: "#112233", libraryCategoryID: null }];
    project.photos.forEach((photo, i) => { photo.bucketID = i === 26 ? null : i % 2 ? firstBucket : secondBucket; });
    const chunks: string[] = [];
    for await (const html of renderReportChunks(project, pid, log, { ...options(), groupByBucket: true })) chunks.push(html);
    expect(chunks.length).toBe(3);
    const html = chunks.join("");
    expect(html.match(/class="page bucket-divider"/g)).toHaveLength(3);
    expect(html.match(/class="page contact-sheet"/g)).toHaveLength(27);
    expect(html.indexOf('bucket-name">First')).toBeLessThan(html.indexOf('bucket-name">Second'));
    const actual = [...html.matchAll(/class="seq">#(\d+)/g)].map(match => Number(match[1]));
    expect(actual).toEqual([...Array.from({ length: 13 }, (_, i) => i * 2 + 2), ...Array.from({ length: 13 }, (_, i) => i * 2 + 1), 27]);
    expect(html.match(/bucket-count">13 photos/g)).toHaveLength(2);
  });
  it("loads plans one at a time and skips empty distress pages in separate mode", async () => {
    const project = fixture(0);
    project.floorPlans = Array.from({ length: 25 }, (_, i) => ({ id: id(i), label: `Plan ${i}`, imageFilename: `${i}.png`, pixelsPerFoot: 1, calibrationDistanceFeet: 1, anchorPixelX: 0, anchorPixelY: 0, anchorLocalXFeet: 0, anchorLocalYFeet: 0, northDeg: 0, distress: [] }));
    state.files = project.floorPlans.map(plan => ({ photo_id: plan.id, kind: "plan", object_key: plan.imageFilename, source_filename: plan.imageFilename, size_bytes: state.image.length }));
    const iterator = renderReportChunks(project, pid, log, { ...options(), includeFloorPlanPages: true, planMode: "photoAndDistressSeparate" });
    const first = await iterator.next();
    expect(state.reads).toHaveLength(1);
    expect(first.value!.match(/class="page plan"/g)).toHaveLength(1);
    await iterator.return(undefined);
  });
  it("fails on absent registration, storage errors, unsupported bytes, and registry errors", async () => {
    const project = fixture(1);
    state.files = [];
    await expect(renderReportChunks(project, pid, log, options()).next()).rejects.toThrow(/not uploaded/);
    fixture(1); state.badKey = "0.png";
    await expect(renderReportChunks(project, pid, log, options()).next()).rejects.toThrow(/missing/);
    state.badKey = ""; state.malformedKey = "0.png";
    await expect(renderReportChunks(project, pid, log, options()).next()).rejects.toThrow(/JPEG or PNG/);
    state.malformedKey = ""; state.registryError = true;
    await expect(renderReportChunks(project, pid, log, options()).next()).rejects.toThrow(/registry/);
  });
  it("requires originals rather than exporting low-resolution navigation thumbnails", async () => {
    const project = fixture(1);
    state.files[0]!.kind = "thumb";
    await expect(renderReportChunks(project, pid, log, options()).next()).rejects.toThrow(/not uploaded/);
    expect(state.reads).toHaveLength(0);
  });
  it("permits a normal six-photo page of 12-megapixel originals", async () => {
    const project = fixture(6);
    const original = state.image;
    state.image = Buffer.from(original);
    state.image.writeUInt32BE(4000, 16); state.image.writeUInt32BE(3000, 20);
    try {
      const iterator = renderReportChunks(project, pid, log, { ...options(), perPage: 6 });
      expect((await iterator.next()).done).toBe(false);
      await iterator.return(undefined);
    } finally { state.image = original; }
  });
  it("permits six clean/marked cells from three 12-megapixel originals and overlays", async () => {
    const project = fixture(3);
    for (const photo of project.photos) {
      photo.markupOverlayFilename = `markup-${photo.id}.png`;
      state.files.push({ photo_id: photo.id, kind: "markup_png", object_key: photo.markupOverlayFilename, source_filename: photo.markupOverlayFilename, size_bytes: state.image.length });
    }
    const original = state.image;
    state.image = Buffer.from(original); state.image.writeUInt32BE(4000, 16); state.image.writeUInt32BE(3000, 20);
    try {
      const iterator = renderReportChunks(project, pid, log, { ...options(), perPage: 6 });
      const result = await iterator.next();
      expect(result.value!.match(/class="page contact-sheet"/g)).toHaveLength(1);
      expect(result.value!.match(/class="markup-overlay"/g)).toHaveLength(3);
      await iterator.return(undefined);
    } finally { state.image = original; }
  });
  it("fails oversized decoded pages with an actionable page-count instruction", async () => {
    const project = fixture(7);
    const original = state.image;
    state.image = Buffer.from(original);
    state.image.writeUInt32BE(4000, 16); state.image.writeUInt32BE(3000, 20);
    try {
      await expect(renderReportChunks(project, pid, log, { ...options(), perPage: 7 }).next()).rejects.toThrow(/fewer photos per page/);
    } finally { state.image = original; }
  });
  it("expands marked photos into adjacent clean/marked cells across page boundaries", async () => {
    const project = fixture(6);
    project.photos[4]!.markupOverlayFilename = "markup.png";
    state.files.push({ photo_id: project.photos[4]!.id, kind: "markup_png", object_key: "markup.png", source_filename: "markup.png", size_bytes: state.image.length });
    const html: string[] = [];
    for await (const part of renderReportChunks(project, pid, log, { ...options(), perPage: 5 })) html.push(part);
    const combined = html.join("");
    expect([...combined.matchAll(/class="seq">#(\d+)/g)].map(match => Number(match[1]))).toEqual([1, 2, 3, 4, 5, 5, 6]);
    expect(combined.match(/class="page contact-sheet"/g)).toHaveLength(2);
    expect(combined.match(/class="markup-overlay"/g)).toHaveLength(1);
    expect(combined).toContain("Marked copy");
    expect(state.reads.filter(key => key === "markup.png")).toHaveLength(1);
    expect(state.reads.filter(key => key === "4.png")).toHaveLength(1);
  });
  it("requires PNG markup and refuses absent or unavailable marked evidence", async () => {
    const project = fixture(1); project.photos[0]!.markupOverlayFilename = "markup.png";
    await expect(renderReportChunks(project, pid, log, options()).next()).rejects.toThrow(/markup.*not uploaded/);
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0, 0xff, 0xd9]);
    state.files.push({ photo_id: project.photos[0]!.id, kind: "markup_png", object_key: "markup.png", source_filename: "markup.png", size_bytes: jpeg.length });
    state.customBytes.set("markup.png", jpeg);
    await expect(renderReportChunks(project, pid, log, options()).next()).rejects.toThrow(/markup must be a PNG/);
    state.badKey = "markup.png";
    await expect(renderReportChunks(project, pid, log, options()).next()).rejects.toThrow(/missing/);
  });
  it("filters plans before fetching and keeps excluded-floor photos in trailing Unlocated section", async () => {
    const project = fixture(2);
    project.floorPlans = ["Included", "Excluded missing"].map((label, i) => ({ id: id(50 + i), label, imageFilename: `plan${i}.png`, pixelsPerFoot: 1, calibrationDistanceFeet: 1, anchorPixelX: 0, anchorPixelY: 0, anchorLocalXFeet: 0, anchorLocalYFeet: 0, northDeg: 0, distress: [] }));
    project.photos[0]!.floorPlanID = id(51); project.photos[1]!.floorPlanID = id(50);
    state.files.push({ photo_id: id(50), kind: "plan", object_key: "plan0.png", source_filename: "plan0.png", size_bytes: state.image.length });
    const html: string[] = [];
    for await (const part of renderReportChunks(project, pid, log, { ...options(), includeFloorPlanPages: true, selectedFloorIds: [id(50)] })) html.push(part);
    const combined = html.join("");
    expect(state.reads).toContain("plan0.png"); expect(state.reads).not.toContain("plan1.png");
    expect(combined).not.toContain("Excluded missing"); expect(combined).toContain("Unlocated photos");
    expect([...combined.matchAll(/class="seq">#(\d+)/g)].map(match => Number(match[1]))).toEqual([2, 1]);
    expect(combined).toContain('class="plan">Unlocated');
  });
  it("renders no plan for an empty selection or an empty distress-only plan", async () => {
    const project = fixture(0);
    project.floorPlans = [{ id: id(50), label: "Not rendered", imageFilename: "missing.png", pixelsPerFoot: 1, calibrationDistanceFeet: 1, anchorPixelX: 0, anchorPixelY: 0, anchorLocalXFeet: 0, anchorLocalYFeet: 0, northDeg: 0, distress: [] }];
    expect((await renderReportChunks(project, pid, log, { ...options(), includeFloorPlanPages: true, selectedFloorIds: [] }).next()).done).toBe(true);
    expect((await renderReportChunks(project, pid, log, { ...options(), includeFloorPlanPages: true, planMode: "distressOnly" }).next()).done).toBe(true);
    expect(state.reads).toEqual([]);
  });
  it("fails on snapshot/registry filename mismatch before reading bytes", async () => {
    const project = fixture(1); state.files[0]!.source_filename = "replacement.png";
    await expect(renderReportChunks(project, pid, log, options()).next()).rejects.toThrow(/filename changed/);
    expect(state.reads).toEqual([]);
  });
  it("escapes branding title, subtitle, footer and places the configured logo on cover", async () => {
    const project = fixture(0);
    const iterator = renderReportChunks(project, pid, log, { ...options(), includeCoverPage: true }, { titleOverride: "Firm <name>", subtitleOverride: "A & B", footerOverride: "<private>", logoDataUrl: `data:image/png;base64,${state.image.toString("base64")}` });
    const { value } = await iterator.next();
    expect(value).toContain("Firm &lt;name&gt;"); expect(value).toContain("A &amp; B"); expect(value).toContain("&lt;private&gt;"); expect(value).toContain('class="report-logo"');
    await iterator.return(undefined);
  });

  it("bounds batch bytes independently of the page count", async () => {
    const project = fixture(2);
    state.files[0]!.size_bytes = 20 * 1024 * 1024;
    state.files[1]!.size_bytes = 20 * 1024 * 1024;
    await expect(renderReportChunks(project, pid, log, { ...options(), perPage: 2 }).next()).rejects.toThrow(/32 MiB/);
    expect(state.reads).toHaveLength(0);
  });
});

describe("actual PDF worker consumes stream and fails closed", () => {
  it("renders the first batch before fetching the second, then marks complete", async () => {
    fixture(12);
    await processPdfExportJob({ id: "job-1", project_id: pid, status: "running", options: options() }, log);
    expect(state.events.indexOf("pdf")).toBeLessThan(state.events.indexOf("read:10.png"));
    expect(state.pdfCalls).toBe(2);
    expect(state.brandingCalls).toBe(1);
    expect(state.printOptions.every(options => options.displayHeaderFooter === true && String(options.footerTemplate).includes("Private"))).toBe(true);
    expect(state.html.every(html => html.includes('class="report-footer">Private'))).toBe(true);
    expect(state.uploads).toBe(1);
    expect(state.updates.at(-1)).toMatchObject({ status: "done", progress_total_chunks: 2, progress_done_chunks: 2 });
  });
  it("a late missing asset marks Failed without uploading a partial PDF", async () => {
    fixture(12); state.badKey = "11.png";
    await processPdfExportJob({ id: "job-2", project_id: pid, status: "running", options: options() }, log);
    expect(state.pdfCalls).toBe(1);
    expect(state.uploads).toBe(0);
    expect(state.updates.at(-1)).toMatchObject({ status: "failed" });
    expect(state.updates.some(update => update.status === "done")).toBe(false);
  });
  it("fails without publishing if the configured report logo is missing", async () => {
    fixture(1); state.brandingError = true;
    await processPdfExportJob({ id: "job-logo", project_id: pid, status: "running", options: options() }, log);
    expect(state.uploads).toBe(0); expect(state.pdfCalls).toBe(0);
    expect(state.updates.at(-1)).toMatchObject({ status: "failed", error_message: expect.stringMatching(/logo missing/) });
  });

  it("a browser decode failure is Failed even when the file header probes successfully", async () => {
    fixture(1); state.imagesReady = false;
    await processPdfExportJob({ id: "job-3", project_id: pid, status: "running", options: options() }, log);
    expect(state.pdfCalls).toBe(0);
    expect(state.uploads).toBe(0);
    expect(state.updates.at(-1)).toMatchObject({ status: "failed", error_message: expect.stringMatching(/decoded/) });
  });
});
