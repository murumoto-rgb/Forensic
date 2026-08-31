import { existsSync } from "node:fs";
import { Readable } from "node:stream";
import { afterAll, beforeAll, expect, it, vi } from "vitest";
import puppeteer, { type Browser } from "puppeteer";
import { PDFDocument } from "pdf-lib";
import { PhotoSchema, ProjectSchema } from "@forensic/shared";
import type { FastifyBaseLogger } from "fastify";

const data = vi.hoisted(() => ({ bytes: Buffer.alloc(0), rows: [] as Array<Record<string, unknown>> }));
vi.mock("../src/r2.js", () => ({ getObjectStream: async () => Readable.from([data.bytes]) }));
vi.mock("../src/supabase.js", () => ({ supabaseAdmin: { from() {
  const filters: Array<[string, unknown[]]> = [];
  const query = { select() { return query; }, eq() { return query; }, in(key: string, values: unknown[]) { filters.push([key, values]); return query; }, then(resolve: never, reject: never) { return Promise.resolve({ data: data.rows.filter(row => filters.every(([key, values]) => values.includes(row[key]))), error: null }).then(resolve, reject); } };
  return query;
} } }));
import { renderReportChunks, reportFooterTemplate } from "../src/exports/htmlReport.js";
import { applyOptionDefaults } from "../src/exports/options.js";
// Optional integration regression: CI may not install a browser. Local evidence
// uses an isolated headless Chrome process, never the user's browser profile.
const executable = process.env.PUPPETEER_EXECUTABLE_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
let browser: Browser | undefined;
beforeAll(async () => { if (existsSync(executable)) browser = await puppeteer.launch({ executablePath: executable, headless: true, args: ["--no-sandbox"] }); }, 30_000);
afterAll(async () => { await browser?.close(); }, 30_000);
it.skipIf(!existsSync(executable))("prints a real two-page report with decoded aligned markup and escaped branding", async () => {
  const page = await browser!.newPage();
  try {
    const png = await page.evaluate(() => {
      const canvas = (globalThis as any).document.createElement("canvas"); canvas.width = 400; canvas.height = 300;
      const ctx = canvas.getContext("2d"); ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, 400, 300); ctx.fillStyle = "#c00"; ctx.fillRect(190, 140, 20, 20);
      return canvas.toDataURL("image/png") as string;
    });
    data.bytes = Buffer.from(png.split(",")[1]!, "base64");
    const photo = PhotoSchema.parse({ id: "22222222-2222-4222-8222-222222222222", sequenceNumber: 1, timestamp: "2026-08-30T00:00:00Z", imageFilename: "photo.png", markupOverlayFilename: "markup.png", positionSource: "none", isPrimary: true, cameraZoom: 1, flashMode: "auto", tags: [], pendingSuggestions: [], isFavorite: false, previewRotation: 0 });
    const project = ProjectSchema.parse({ id: "11111111-1111-4111-8111-111111111111", name: "Original title", createdAt: "2026-08-30T00:00:00Z", stopped: false, photos: [photo], trashedPhotos: [], floorPlans: [], buckets: [], manifestSchemaVersion: 4 });
    data.rows = ["photo", "markup_png"].map(kind => ({ photo_id: photo.id, kind, object_key: kind, source_filename: kind === "photo" ? "photo.png" : "markup.png", size_bytes: data.bytes.length }));
    const options = applyOptionDefaults({ perPage: 2, includeFloorPlanPages: false });
    const branding = { titleOverride: "Firm <evidence>", subtitleOverride: "A & B", footerOverride: "Private & confidential", logoDataUrl: png };
    let pages = 0; let chunks = 0;
    for await (const html of renderReportChunks(project, project.id, { info() {}, error() {}, warn() {} } as unknown as FastifyBaseLogger, options, branding)) {
      await page.setContent(html, { waitUntil: "load" });
      const layout = await page.evaluate(() => {
        const document = (globalThis as any).document;
        const overlay = document.querySelector(".markup-overlay");
        const rect = (node: any) => { const r = node.getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; };
        return { decoded: Array.from(document.images).every((image: any) => image.complete && image.naturalWidth > 0), overlay: overlay ? rect(overlay) : null, original: overlay ? rect(overlay.previousElementSibling) : null, title: document.querySelector("h1")?.textContent, footer: document.querySelector("footer")?.textContent };
      });
      expect(layout.decoded).toBe(true); expect(layout.footer).toBe("Private & confidential");
      if (chunks === 0) expect(layout.title).toBe("Firm <evidence>");
      if (layout.overlay) { expect(layout.overlay).toEqual(layout.original); expect(layout.overlay[2]).toBeGreaterThan(100); expect(layout.overlay[3]).toBeGreaterThan(100); }
      const pdf = await PDFDocument.load(await page.pdf({ format: "Letter", printBackground: true, displayHeaderFooter: true, headerTemplate: "<span></span>", footerTemplate: reportFooterTemplate(branding.footerOverride) }));
      pages += pdf.getPageCount(); chunks++;
    }
    expect(chunks).toBe(2); expect(pages).toBe(2);
  } finally { await page.close(); }
}, 30_000);
