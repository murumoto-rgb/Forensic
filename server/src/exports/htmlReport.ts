/**
 * HTML report renderer for the server-side PDF export
 * (Build #5.63.1, PR #2 of 3 for plan item #3).
 *
 * Pulls original photos + plan images out of R2, base64-encodes
 * them inline, and assembles a multi-page report:
 *
 *   * Cover page — project name, address, GPS, photo + plan counts,
 *     generation timestamp.
 *   * One page per non-trashed photo — sequence number, timestamp,
 *     thumbnail, caption, observation, AI fields, tag list.
 *   * One page per floor plan — plan label, full image, SVG overlay
 *     showing pin positions + distress marks at their plan-pixel
 *     coordinates.
 *
 * The iOS PDF (`PDFExportService.swift`) remains the authoritative
 * client-facing artifact; this is the "office preview" the plan
 * called out — readable in a browser without an iPad.
 *
 * Image sizing: a floor plan's overlay needs to know the plan
 * image's intrinsic pixel dimensions so the SVG `viewBox` can match
 * (then `planPixelX/Y` coordinates land on the right pixel). A bounded
 * JPEG/PNG header probe reads dimensions; Chromium verifies the full decode.
 *
 * Image and page budgets are enforced per streamed chunk; the PDF worker
 * separately caps the final document. Required evidence never becomes a
 * successful placeholder-only export.
 */

import type { FastifyBaseLogger } from "fastify";
import type {
  Bucket,
  DistressKind,
  DistressMark,
  FloorPlan,
  PdfAnnotationOptions,
  PdfExportOptions,
  PdfPlanMode,
  Photo,
  Project,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { getObjectStream } from "../r2.js";
import { probeImageDimensions } from "./imageProbe.js";
import type { ReportBrandingForExport } from "../reportBranding.js";

/** Upper bounds apply to both materialized HTML and source image buffers. */
export const PAGES_PER_CHUNK = 10;
export const MAX_IMAGE_BYTES = 12 * 1024 * 1024;
export const MAX_CHUNK_IMAGE_BYTES = 32 * 1024 * 1024;
const MAX_CHUNK_HTML_BYTES = 48 * 1024 * 1024;
const MAX_CHUNK_PIXELS = 80_000_000;
const METADATA_ROWS_PER_CHUNK = 100;

interface AssetReference { key: string; sizeBytes: number; requirePng?: boolean }
interface ContactItem { photo: Photo; marked: boolean }
/** Color palette for distress marks. Mirrors the web canvas + iOS
 *  PDF for consistency across the three render surfaces. */
const DISTRESS_COLORS: Record<DistressKind, string> = {
  outOfPlumbDoor: "#ef4444",
  doorNotLatching: "#f97316",
  crackGradeBeam: "#a855f7",
  crackFloor: "#fb923c",
};

const DISTRESS_LABELS: Record<DistressKind, string> = {
  outOfPlumbDoor: "Out of plumb door",
  doorNotLatching: "Door not latching",
  crackGradeBeam: "Crack in grade beam",
  crackFloor: "Crack in floor",
};

/** Resolve registered keys instead of constructing deterministic paths.
 * Reports require full originals (kind=photo), never tiny navigation thumbs. */
async function resolveFileObjectKeysByPhotoId(
  projectId: string,
  ids: string[],
  kindPreference: string[],
  log: FastifyBaseLogger,
  filenames: Map<string, string>
): Promise<Map<string, AssetReference>> {
  const result = new Map<string, AssetReference>();
  if (ids.length === 0) return result;

  // UUID case-preservation map (Build #5.74.3 — same bug
  // `routes/photos.ts` fixed in #5.21.1). iOS manifests store photo
  // IDs in UPPERCASE (`A5F6E276-…`); Postgres `uuid` columns
  // normalize to lowercase (`a5f6e276-…`) when read back. The DB
  // comparison itself is case-insensitive — the IN clause finds the
  // rows fine. But if we keyed the result Map by `row.photo_id` (the
  // DB's lowercase value), every later `.get(photo.id)` lookup would
  // miss because `photo.id` is uppercase. So we resolve back to the
  // caller's original casing for every match.
  const requestedByLower = new Map<string, string>();
  for (const id of ids) requestedByLower.set(id.toLowerCase(), id);

  // Sub-batch the IN-clause same way routes/photos.ts does so we
  // don't blow PostgREST's URL length cap on large projects.
  const SUB_BATCH = 100;
  // priority: lower index in kindPreference wins.
  const kindPriority = new Map(kindPreference.map((k, i) => [k, i]));
  const chosenPriority = new Map<string, number>();

  for (let i = 0; i < ids.length; i += SUB_BATCH) {
    const chunk = ids.slice(i, i + SUB_BATCH);
    const { data, error } = await supabaseAdmin
      .from("current_project_files")
      .select("photo_id, kind, object_key, size_bytes, source_filename")
      .eq("project_id", projectId)
      .in("photo_id", chunk)
      .in("kind", kindPreference);
    if (error) {
      log.error(
        { err: error, projectId, chunkSize: chunk.length },
        "pdf renderer — files lookup failed"
      );
      throw new Error("Required PDF asset registry could not be read");
    }
    for (const row of (data ?? []) as Array<{
      photo_id: string;
      kind: string;
      object_key: string;
      size_bytes: number;
      source_filename: string;
    }>) {
      const rowPriority = kindPriority.get(row.kind);
      if (rowPriority == null) continue;
      // Resolve back to the caller's original-case id. Fall back to
      // the DB value if somehow not in the request set (shouldn't
      // happen since we only queried ids the caller passed).
      const photoId =
        requestedByLower.get(row.photo_id.toLowerCase()) ?? row.photo_id;
      if (row.source_filename !== filenames.get(photoId)) throw new Error("PDF asset filename changed after the project snapshot. Retry the export.");
      const existing = chosenPriority.get(photoId);
      if (existing == null || rowPriority < existing) {
        const sizeBytes = Number(row.size_bytes);
        if (!Number.isSafeInteger(sizeBytes) || sizeBytes < 1) throw new Error("PDF asset byte length is unverified");
        result.set(photoId, { key: row.object_key, sizeBytes, requirePng: row.kind === "markup_png" });
        chosenPriority.set(photoId, rowPriority);
      }
    }
  }
  return result;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Chromium prints this inside the page margin, including table overflow pages. */
export function reportFooterTemplate(text: string): string {
  return `<div style="font-size:8px;width:100%;text-align:center;color:#64748b;padding:0 36px">${escapeHtml(text)}</div>`;
}

interface ImageBlob {
  dataUrl: string;
  width: number;
  height: number;
}

/** Stream with an enforced byte limit; never buffer an arbitrary R2 object. */
async function fetchImage(asset: AssetReference, log: FastifyBaseLogger): Promise<ImageBlob> {
  if (asset.sizeBytes > MAX_IMAGE_BYTES) throw new Error("PDF image exceeds 12 MiB. Use a smaller original image before exporting.");
  const stream = await getObjectStream(asset.key);
  const timeout = setTimeout(() => stream.destroy(new Error("PDF image download timed out")), 30_000);
  try {
    const parts: Buffer[] = [];
    let size = 0;
    for await (const part of stream) {
      const bytes = Buffer.isBuffer(part) ? part : Buffer.from(part);
      size += bytes.length;
      if (size > MAX_IMAGE_BYTES || size > asset.sizeBytes) throw new Error("PDF image byte length exceeds its verified registration");
      parts.push(bytes);
    }
    if (size !== asset.sizeBytes) throw new Error("PDF image byte length does not match its registration");
    const bytes = Buffer.concat(parts, size);
    const dims = probeImageDimensions(bytes);
    if (asset.requirePng && dims.type !== "png") throw new Error("Required PDF markup must be a PNG image. Export aborted.");
    if (dims.width * dims.height > MAX_CHUNK_PIXELS) throw new Error("PDF image dimensions exceed the safe rendering limit");
    return { dataUrl: `data:image/${dims.type};base64,${bytes.toString("base64")}`, width: dims.width, height: dims.height };
  } catch (error) {
    log.warn({ err: error, objectKey: asset.key }, "Required PDF image unavailable; export aborted");
    throw error;
  } finally {
    clearTimeout(timeout);
    stream.destroy();
  }
}

async function fetchImagesParallel(assets: AssetReference[], log: FastifyBaseLogger): Promise<Map<string, ImageBlob>> {
  const results = new Map<string, ImageBlob>();
  let next = 0;
  let failure: unknown;
  await Promise.all(Array.from({ length: Math.min(6, assets.length) }, async () => {
    while (next < assets.length && failure === undefined) {
      const asset = assets[next++]!;
      try { results.set(asset.key, await fetchImage(asset, log)); }
      catch (error) { failure = error; }
    }
  }));
  // Wait for all already-running downloads before propagating a failure.
  if (failure !== undefined) throw failure;
  return results;
}

// ---------------------------------------------------------------------------
// Page renderers
// ---------------------------------------------------------------------------

function coverPage(project: Project, planCount: number, branding?: ReportBrandingForExport): string {
  const photoCount = project.photos.filter((p) => p.trashedAt == null).length;
  const generatedAt = new Date().toLocaleString("en-US", {
    dateStyle: "long",
    timeStyle: "short",
  });
  const gps = project.projectGPS;
  return `<section class="page cover">
    ${branding?.logoDataUrl ? `<img class="report-logo" src="${escapeHtml(branding.logoDataUrl)}" alt="Report logo">` : ""}
    <h1>${escapeHtml(branding?.titleOverride ?? project.name)}</h1>
    ${branding?.subtitleOverride ? `<div class="subtitle">${escapeHtml(branding.subtitleOverride)}</div>` : ""}
    ${
      project.projectAddress
        ? `<div class="addr">${escapeHtml(project.projectAddress)}</div>`
        : ""
    }
    ${
      gps
        ? `<div class="gps">
            ${gps.latitude.toFixed(5)}, ${gps.longitude.toFixed(5)}
            ${
              gps.accuracyFeet != null
                ? ` &middot; ±${gps.accuracyFeet.toFixed(0)} ft`
                : ""
            }
          </div>`
        : ""
    }
    <div class="stats">
      <div class="stat"><div class="n">${photoCount}</div>
        <div class="l">Photo${photoCount === 1 ? "" : "s"}</div></div>
      <div class="stat"><div class="n">${planCount}</div>
        <div class="l">Floor plan${planCount === 1 ? "" : "s"}</div></div>
    </div>
    <div class="gen">Generated ${escapeHtml(generatedAt)} &middot; office preview export</div>
  </section>`;
}

/**
 * iOS-parity contact-sheet primitives (Build #5.68.1).
 *
 * iOS's PDF export uses contact sheets as the primary photo-page
 * format — N photos arranged in a grid with the
 * `annotations` flags controlling what's rendered under each cell.
 * This block replaces the per-photo full-page layout from #5.63.1
 * and the rigid 1/2/4-up grid from #5.64.1.
 *
 * `perPage` is iOS-style flexible Int (1–12 supported); the grid
 * dimensions are computed below so any value in that range produces
 * a sensible layout. perPage=1 is still a single-tile "sheet" — the
 * same code path renders it at full page size, just with one cell.
 *
 * The per-cell `annotationsHtml()` row mirrors iOS's
 * `drawContactSheet` annotation order: caption, observation,
 * primary tags, measurement, reviewer flag. Each line renders only
 * when its flag is on AND the photo has a non-empty value for that
 * field. iOS-default (`includeTags: true`, others false) reproduces
 * the iOS engineer's at-a-glance contact sheet.
 */

/** Compute grid cols × rows for any perPage in the 1–12 range. */
function gridDimensions(perPage: number): { cols: number; rows: number } {
  if (perPage <= 1) return { cols: 1, rows: 1 };
  if (perPage <= 3) return { cols: 1, rows: perPage };
  if (perPage === 4) return { cols: 2, rows: 2 };
  if (perPage <= 6) return { cols: 2, rows: Math.ceil(perPage / 2) };
  if (perPage <= 9) return { cols: 3, rows: Math.ceil(perPage / 3) };
  return { cols: 3, rows: Math.ceil(perPage / 3) }; // 10–12 → 3×4
}

/** The per-cell annotations row. Empty string when every requested
 *  field is empty on the photo (renderer hides the row entirely). */
function annotationsHtml(
  photo: Photo,
  annotations: PdfAnnotationOptions
): string {
  const lines: string[] = [];

  if (annotations.includeCaption) {
    const caption =
      photo.userCaption?.trim() ||
      photo.aiAnalysis?.captionDraft?.trim() ||
      "";
    if (caption) {
      lines.push(`<div class="ann-line ann-caption">${escapeHtml(caption)}</div>`);
    }
  }

  if (annotations.includeObservation) {
    const observation =
      photo.userObservation?.trim() ||
      photo.aiAnalysis?.summaryObservation?.trim() ||
      "";
    if (observation) {
      lines.push(`<div class="ann-line ann-observation">${escapeHtml(observation)}</div>`);
    }
  }

  if (annotations.includeTags) {
    const tagLabels = photo.tags
      .filter((t) => t.parentTag == null)
      .map((t) => t.label);
    if (tagLabels.length > 0) {
      lines.push(
        `<div class="ann-line ann-tags">${tagLabels
          .map((t) => `<span class="tag">${escapeHtml(t)}</span>`)
          .join("")}</div>`
      );
    }
  }

  if (annotations.includeMeasurement) {
    const measurement = photo.aiAnalysis?.measurementVisible?.trim();
    if (measurement) {
      lines.push(
        `<div class="ann-line ann-measurement"><span class="ann-lbl">Measurement</span> ${escapeHtml(measurement)}</div>`
      );
    }
  }

  if (annotations.includeReviewerFlag) {
    const flag = photo.aiAnalysis?.reviewerFlag?.trim();
    if (flag) {
      lines.push(
        `<div class="ann-line ann-flag"><span class="ann-lbl">Flag</span> ${escapeHtml(flag)}</div>`
      );
    }
  }

  if (lines.length === 0) return "";
  return `<div class="annotations">${lines.join("")}</div>`;
}

/** Single tile in the contact sheet: header → image → annotations. */
function contactSheetTile(
  photo: Photo,
  thumb: ImageBlob,
  planLabel: string | null,
  annotations: PdfAnnotationOptions,
  overlay?: ImageBlob
): string {
  const seq = `#${photo.sequenceNumber}`;
  return `<div class="tile">
    <div class="tile-header">
      <span class="seq">${escapeHtml(seq)}</span>${overlay ? `<span class="marked-label">Marked copy</span>` : ""}
      ${planLabel ? `<span class="plan">${escapeHtml(planLabel)}</span>` : ""}
    </div>
    <div class="tile-image">
      <img class="original-image" src="${thumb.dataUrl}" alt="${escapeHtml(seq)}">
      ${overlay ? `<img class="markup-overlay" src="${overlay.dataUrl}" alt="Markup for ${escapeHtml(seq)}">` : ""}
    </div>
    ${annotationsHtml(photo, annotations)}
  </div>`;
}

/** One printed page containing up to `perPage` photo tiles. */
function contactSheetPage(
  items: ContactItem[],
  photoBlobsByPhotoId: Map<string, ImageBlob>,
  markupBlobsByPhotoId: Map<string, ImageBlob>,
  planLabelById: Map<string, string>,
  options: PdfExportOptions
): string {
  const { cols, rows } = gridDimensions(options.perPage);
  const tilesHtml = items
    .map(({ photo: p, marked }) => {
      const blob = photoBlobsByPhotoId.get(p.id);
      if (!blob) throw new Error(`Required PDF photo ${p.id} was not loaded`);
      const planLabel = p.floorPlanID
        ? planLabelById.get(p.floorPlanID.toLowerCase()) ?? "Unlocated"
        : "Unlocated";
      const overlay = marked ? markupBlobsByPhotoId.get(p.id) : undefined;
      if (marked && !overlay) throw new Error(`Required PDF markup for ${p.id} was not loaded`);
      return contactSheetTile(p, blob, planLabel, options.annotations, overlay);
    })
    .join("\n");
  // Inline grid template so the same CSS handles any cols/rows
  // combination computed by gridDimensions.
  const style =
    `grid-template-columns: repeat(${cols}, 1fr); ` +
    `grid-template-rows: repeat(${rows}, 1fr);`;
  return `<section class="page contact-sheet" style="${style}">${tilesHtml}</section>`;
}

/** A distress mark's `points` array is `[CGPoint]` from iOS, which
 *  Apple's default Codable encodes as a `[x, y]` two-element array.
 *  We unpack just enough to render — defensively, since the wire
 *  format is `unknown[]`. */
function pointToXy(p: unknown): { x: number; y: number } | null {
  if (Array.isArray(p) && p.length >= 2) {
    const x = typeof p[0] === "number" ? p[0] : null;
    const y = typeof p[1] === "number" ? p[1] : null;
    if (x != null && y != null) return { x, y };
  }
  if (p && typeof p === "object") {
    const obj = p as { x?: unknown; y?: unknown };
    if (typeof obj.x === "number" && typeof obj.y === "number") {
      return { x: obj.x, y: obj.y };
    }
  }
  return null;
}

function distressOverlay(mark: DistressMark, pinScale: number): string {
  const color = DISTRESS_COLORS[mark.kind] ?? "#ef4444";
  const pts = mark.points.map(pointToXy).filter((p): p is { x: number; y: number } => p != null);
  if (pts.length === 0) return "";
  if (mark.kind === "crackFloor") {
    // Polyline stroke. Stroke width set to a fraction of the
    // image's smaller dimension so it scales with zoom.
    // Build #6.20.1: scaled by the user's pin-size setting so the
    // PDF matches the on-screen plan (and the iOS exporter, which
    // applies its bubbleScale the same way).
    const d = pts.map((p, i) => `${i === 0 ? "M" : "L"}${p.x},${p.y}`).join(" ");
    return `<path d="${d}" stroke="${color}" stroke-width="${6 * pinScale}" fill="none" stroke-linecap="round" stroke-linejoin="round" opacity="0.85"/>`;
  }
  // Point distress — circle marker at the first point.
  const p = pts[0]!;
  return `<g><circle cx="${p.x}" cy="${p.y}" r="${12 * pinScale}" fill="${color}" opacity="0.85"/></g>`;
}

/**
 * Plan-page render helpers (Build #5.69.1 — iOS plan modes).
 *
 * iOS's `PdfPlanMode` enum drives which overlays are drawn:
 *
 *   - `photoOnly`                → numbered photo pins only (1 page)
 *   - `distressOnly`             → distress markers only (1 page)
 *   - `photoAndDistressSeparate` → 2 pages per plan (pins page, then distress page)
 *   - `merged`                   → pins + distress on one page
 *
 * Mirrors iOS `PDFExportOptions.PlanRenderMode.{rendersPhotos,
 * rendersDistress, collapsesOntoOnePage}`. The renderer (in
 * `renderReportHtml`) calls `planSection` once or twice per plan
 * depending on `collapsesOntoOnePage` — wrapping the per-plan
 * decision in one place keeps the iOS / web logic in lockstep.
 */

/** Whether photo pins should be drawn for a given mode. Mirrors
 *  iOS `PlanRenderMode.rendersPhotos`. */
function modeRendersPhotos(mode: PdfPlanMode): boolean {
  return (
    mode === "photoOnly" ||
    mode === "photoAndDistressSeparate" ||
    mode === "merged"
  );
}

/** Whether distress markers should be drawn for a given mode.
 *  Mirrors iOS `PlanRenderMode.rendersDistress`. */
function modeRendersDistress(mode: PdfPlanMode): boolean {
  return (
    mode === "distressOnly" ||
    mode === "photoAndDistressSeparate" ||
    mode === "merged"
  );
}

interface PlanSectionOptions {
  includePhotos: boolean;
  includeDistress: boolean;
  /** Optional subtitle suffix (e.g. "Photos" / "Distress") for the
   *  `photoAndDistressSeparate` mode's two pages. */
  subtitle?: string;
  /** Pin/distress size multiplier (Build #6.20.1). Already clamped
   *  to 0.5–4 by `applyOptionDefaults`. */
  pinScale: number;
}

function planSection(
  plan: FloorPlan,
  planImage: ImageBlob,
  planPhotos: Photo[],
  sectionOptions: PlanSectionOptions
): string {
  const title = sectionOptions.subtitle
    ? `${escapeHtml(plan.label)} <span class="subtitle">— ${escapeHtml(sectionOptions.subtitle)}</span>`
    : escapeHtml(plan.label);
  if (!planImage) throw new Error(`Required PDF plan ${plan.id} was not loaded`);
  const W = planImage.width;
  const H = planImage.height;
  // Build #6.20.1: pins scale with the user's pin-size preference —
  // the web exporter previously hardcoded r=14 while iOS's exporter
  // honored its bubbleScale, so the same project printed differently
  // depending on which device exported it.
  const s = sectionOptions.pinScale;
  const pinSvg = sectionOptions.includePhotos
    ? planPhotos
        .filter(
          (p) =>
            p.planPixelX != null &&
            p.planPixelY != null &&
            (p.isPrimary || p.groupID == null)
        )
        .map((p) => {
          const x = p.planPixelX!;
          const y = p.planPixelY!;
          return `<g>
            <circle cx="${x}" cy="${y}" r="${14 * s}" fill="#2563eb" stroke="#fff" stroke-width="${2 * s}"/>
            <text x="${x}" y="${y + 5 * s}" text-anchor="middle" font-size="${14 * s}" fill="#fff" font-weight="600">${p.sequenceNumber}</text>
          </g>`;
        })
        .join("")
    : "";
  const distressSvg = sectionOptions.includeDistress
    ? plan.distress.map((m) => distressOverlay(m, s)).join("")
    : "";
  // Legend only shows when distress is actually being rendered.
  const legend =
    sectionOptions.includeDistress && plan.distress.length > 0
      ? `<div class="legend">
        ${Array.from(new Set(plan.distress.map((m) => m.kind)))
          .map(
            (k) => `<span class="li">
              <span class="dot" style="background:${DISTRESS_COLORS[k] ?? "#ef4444"}"></span>
              ${escapeHtml(DISTRESS_LABELS[k] ?? k)}
            </span>`
          )
          .join("")}
      </div>`
      : "";
  return `<section class="page plan">
    <h2>${title}</h2>
    <div class="planwrap">
      <img class="planimg" src="${planImage.dataUrl}" alt="${escapeHtml(plan.label)}">
      <svg class="planoverlay" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet">
        ${distressSvg}
        ${pinSvg}
      </svg>
    </div>
    ${legend}
  </section>`;
}

/** Render one OR two `<section class="page plan">` blocks for a
 *  given floor plan, depending on `mode`. Returns the concatenated
 *  HTML. */
function planPages(
  plan: FloorPlan,
  planImage: ImageBlob,
  planPhotos: Photo[],
  mode: PdfPlanMode,
  pinScale: number
): string {
  if (mode === "photoAndDistressSeparate") {
    const photoPage = planSection(plan, planImage, planPhotos, {
      includePhotos: true,
      includeDistress: false,
      subtitle: "Photos",
      pinScale,
    });
    if (plan.distress.length === 0) return photoPage;
    const distressPage = planSection(plan, planImage, planPhotos, {
      includePhotos: false,
      includeDistress: true,
      subtitle: "Distress",
      pinScale,
    });
    return `${photoPage}\n${distressPage}`;
  }
  if (mode === "distressOnly" && plan.distress.length === 0) return "";
  return planSection(plan, planImage, planPhotos, {
    includePhotos: modeRendersPhotos(mode),
    includeDistress: modeRendersDistress(mode),
    pinScale,
  });
}

/**
 * Bucket-grouped + flat contact-sheet renderers (Build #5.71.1 —
 * iOS parity). The flat path is what every job before this PR did:
 * one stream of contact sheets, chunked by `perPage`. The grouped
 * path partitions the selected photo set by bucket, sorts groups by
 * iOS `Bucket.sortOrder`, emits a divider page with the bucket
 * name + colour bar for each group, then the bucket's contact
 * sheets.
 *
 * "Unbucketed" group: photos with `bucketID === null` (or pointing
 * at a bucket that's been deleted from the manifest) land in a
 * trailing group with the bucket name "Unbucketed" — same way iOS
 * handles the unlocated case for plans. Nothing gets dropped.
 */
/** One full page introducing a bucket group — big colour bar + name
 *  + photo count. Same shape for the synthetic "Unbucketed" group
 *  (no colour bar, neutral name). */
function bucketDividerHtml(
  bucket: Bucket | null,
  photoCount: number
): string {
  const name = bucket ? bucket.name : "Unbucketed";
  const colour = bucket?.colorHex ?? "#94a3b8";
  return `<section class="page bucket-divider">
    <div class="bucket-block">
      <div class="bucket-bar" style="background:${escapeHtml(colour)}"></div>
      <div class="bucket-text">
        <div class="bucket-name">${escapeHtml(name)}</div>
        <div class="bucket-count">${photoCount} photo${photoCount === 1 ? "" : "s"}</div>
      </div>
    </div>
  </section>`;
}

/**
 * Metadata-table section (Build #5.70.1 — iOS parity).
 *
 * Mirrors iOS's `PDFExportOptions.includeMetadataTable` /
 * `PDFExportService.drawMetadataTable`: one tabular page (or many
 * if the photo set is long enough to overflow) listing every
 * exported photo with key fields. Useful for the office reviewer
 * who wants a one-glance index of what's in the report — sort by
 * #, see the date range, scan tags without flipping through
 * contact sheets.
 *
 * Render strategy: a single `<table>` with a sticky `<thead>` that
 * Chromium repeats on every printed page via
 * `display: table-header-group`. `page-break-inside: avoid` on
 * each row keeps a row from being split mid-line at a page
 * boundary.
 *
 * Columns mirror what iOS shows in `drawMetadataTable`:
 *   - # (sequence number)
 *   - Date (timestamp)
 *   - Plan (label or "—" when un-located)
 *   - Tags (comma-separated primary-tag labels)
 *   - Caption (user caption, falling back to AI caption draft)
 *   - Observation (user observation, falling back to AI summary)
 */
function metadataTableHtml(
  photos: Photo[],
  planLabelById: Map<string, string>
): string {
  if (photos.length === 0) return "";

  const rows = photos
    .map((p) => {
      const seq = `${p.sequenceNumber}`;
      const date = new Date(p.timestamp).toLocaleString("en-US", {
        dateStyle: "short",
        timeStyle: "short",
      });
      const planLabel = p.floorPlanID
        ? planLabelById.get(p.floorPlanID.toLowerCase()) ?? "Unlocated"
        : "—";
      const tagLabels = p.tags
        .filter((t) => t.parentTag == null)
        .map((t) => t.label)
        .join(", ");
      const caption =
        p.userCaption?.trim() ||
        p.aiAnalysis?.captionDraft?.trim() ||
        "";
      const observation =
        p.userObservation?.trim() ||
        p.aiAnalysis?.summaryObservation?.trim() ||
        "";
      return `<tr>
        <td class="col-seq">${escapeHtml(seq)}</td>
        <td class="col-date">${escapeHtml(date)}</td>
        <td class="col-plan">${escapeHtml(planLabel)}</td>
        <td class="col-tags">${escapeHtml(tagLabels)}</td>
        <td class="col-caption">${escapeHtml(caption)}</td>
        <td class="col-observation">${escapeHtml(observation)}</td>
      </tr>`;
    })
    .join("");

  return `<section class="page metadata-table">
    <h2>Photo metadata</h2>
    <table>
      <thead>
        <tr>
          <th class="col-seq">#</th>
          <th class="col-date">Date</th>
          <th class="col-plan">Plan</th>
          <th class="col-tags">Tags</th>
          <th class="col-caption">Caption</th>
          <th class="col-observation">Observation</th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>
  </section>`;
}

// ---------------------------------------------------------------------------
// Top-level render
// ---------------------------------------------------------------------------

/** Apply the user's photo filter on top of the always-applied
 *  "exclude trashed unless `includeTrashed`" rule. */
function selectPhotos(project: Project, options: PdfExportOptions): Photo[] {
  let pool = options.includeTrashed ? [...project.photos, ...project.trashedPhotos] : project.photos;
  if (!options.includeTrashed) {
    pool = pool.filter((p) => p.trashedAt == null);
  }
  if (options.photoFilter === "favorites") {
    pool = pool.filter((p) => p.isFavorite);
  } else if (options.photoFilter === "byFloorPlan" && options.floorPlanId) {
    pool = pool.filter((p) => p.floorPlanID === options.floorPlanId);
  }
  return pool;
}

/** Chunk an array into groups of `size`. The last group may be
 *  shorter. */
function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) {
    out.push(arr.slice(i, i + size));
  }
  return out;
}

/** Wrap a body HTML fragment in the full document scaffold + shared
 *  styles. Every chunk produced by `renderReportChunks` goes through
 *  this so Chromium gets the same `@page` size + style block on each
 *  setContent call. */
function wrapHtml(
  bodyHtml: string,
  styles: string,
  project: Project,
  branding?: ReportBrandingForExport
): string {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>${escapeHtml(project.name)}</title>
<style>${styles}</style></head>
<body${branding?.footerOverride ? ' class="has-footer"' : ""}>${branding?.footerOverride ? `<footer class="report-footer">${escapeHtml(branding.footerOverride)}</footer>` : ""}${bodyHtml}</body></html>`;
}

/** The full inline `<style>` block. Pulled out of `renderReportChunks`
 *  so every chunk reuses it without duplicating string literals. */
function sharedStyles(options: PdfExportOptions): string {
  const pageSizeCss = options.pageSize === "a4" ? "A4" : "Letter";
  return `
  @page { size: ${pageSizeCss}; margin: 0.5in; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, system-ui, "Segoe UI", Roboto, sans-serif;
         color: #0f172a; margin: 0; font-size: 11pt; }
  .page { page-break-after: always; min-height: 10in; padding: 0; }
  .page:last-child { page-break-after: auto; }

  /* Cover */
  .cover { display: flex; flex-direction: column; min-height: 10in; }
  .report-logo { max-width: 2.5in; max-height: 1in; object-fit: contain; align-self: flex-start; margin-bottom: 0.25in; }
  @media screen { .has-footer .page { padding-bottom: 0.25in; } }
  @media print { .report-footer { display: none; } }
  .report-footer { position: fixed; bottom: 0; left: 0; right: 0; font-size: 8pt; color: #64748b; text-align: center; }
  .cover h1 { font-size: 32pt; margin: 0 0 0.25in; }
  .cover .addr { font-size: 12pt; color: #475569; margin-bottom: 0.1in; }
  .cover .gps { font-size: 10pt; color: #64748b; font-family: ui-monospace, monospace; }
  .cover .stats { display: flex; gap: 1in; margin-top: auto;
                  padding-top: 0.5in; border-top: 1px solid #cbd5e1; }
  .cover .stat .n { font-size: 28pt; font-weight: 600; }
  .cover .stat .l { font-size: 10pt; color: #64748b; text-transform: uppercase; }
  .cover .gen { font-size: 9pt; color: #94a3b8; margin-top: 0.5in; }

  /* Contact sheet pages (Build #5.68.1 — iOS-parity layout).
     Grid dimensions are inline-styled per-page from gridDimensions()
     so any perPage 1-12 produces a sensible layout. */
  .contact-sheet { display: grid; gap: 0.2in; min-height: 10in; }
  .tile { display: flex; flex-direction: column; min-height: 0;
          page-break-inside: avoid; }
  .tile-header { display: flex; gap: 0.15in; align-items: baseline;
                 font-size: 10pt; padding-bottom: 0.05in;
                 border-bottom: 1px solid #e2e8f0; margin-bottom: 0.05in; }
  .tile-header .seq { font-weight: 700; color: #0f172a; }
  .tile-header .plan { margin-left: auto; color: #2563eb; font-size: 9pt; }
  .tile-image { position: relative; flex: 1 1 auto; display: flex; justify-content: center;
                align-items: center; background: #f1f5f9;
                border: 1px solid #e2e8f0; min-height: 0; }
  .tile-image img { position: absolute; inset: 0; height: 100%; width: 100%; object-fit: contain; }
  .tile-image .markup-overlay { z-index: 1; }
  .marked-label { font-size: 8pt; color: #64748b; }
  .tile-image .missing { color: #94a3b8; font-size: 9pt; }
  .annotations { display: flex; flex-direction: column; gap: 2px;
                 margin-top: 0.05in; font-size: 9pt; color: #334155; }
  .annotations .ann-line { display: block; line-height: 1.25; }
  .annotations .ann-caption { font-weight: 600; color: #0f172a; }
  .annotations .ann-observation { color: #475569; }
  .annotations .ann-tags { display: flex; flex-wrap: wrap; gap: 4px; }
  .annotations .ann-tags .tag { background: #e2e8f0; color: #0f172a;
                                 padding: 1px 6px; border-radius: 10px;
                                 font-size: 8pt; }
  .annotations .ann-lbl { font-size: 8pt; color: #64748b;
                          text-transform: uppercase; letter-spacing: 0.04em;
                          margin-right: 4px; }

  /* Plan pages */
  .plan h2 { font-size: 18pt; margin: 0 0 0.2in; }
  .plan h2 .subtitle { font-size: 11pt; color: #64748b; font-weight: 400; }
  .plan .planwrap { position: relative; width: 100%; }
  .plan .planimg { width: 100%; height: auto; display: block; border: 1px solid #cbd5e1; }
  .plan .planoverlay { position: absolute; inset: 0; width: 100%; height: 100%; }
  .plan .missing { color: #94a3b8; padding: 0.5in 0; }
  .plan .legend { display: flex; flex-wrap: wrap; gap: 16px; margin-top: 0.2in;
                  font-size: 10pt; color: #334155; }
  .plan .legend .li { display: inline-flex; gap: 6px; align-items: center; }
  .plan .legend .dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }

  /* Metadata table (Build #5.70.1 — iOS parity).
     thead with display:table-header-group tells Chromium to repeat
     the header row on every printed page when the body overflows;
     row-level page-break-inside:avoid keeps a row from being split
     across a page boundary. */
  .metadata-table h2 { font-size: 16pt; margin: 0 0 0.15in; }
  .metadata-table table { width: 100%; border-collapse: collapse;
                          font-size: 9pt; color: #1e293b; }
  .metadata-table thead { display: table-header-group; }
  .metadata-table th { text-align: left; padding: 4px 6px;
                       background: #f1f5f9; border-bottom: 1px solid #cbd5e1;
                       font-size: 8.5pt; text-transform: uppercase;
                       letter-spacing: 0.04em; color: #475569;
                       font-weight: 600; }
  .metadata-table td { padding: 4px 6px; vertical-align: top;
                       border-bottom: 1px solid #e2e8f0;
                       word-break: break-word; }
  .metadata-table tr { page-break-inside: avoid; }
  .metadata-table .col-seq { width: 0.35in; font-family: ui-monospace, monospace;
                              text-align: right; }
  .metadata-table .col-date { width: 1.2in; white-space: nowrap; color: #64748b; }
  .metadata-table .col-plan { width: 1.0in; color: #2563eb; }
  .metadata-table .col-tags { width: 1.4in; }
  .metadata-table .col-caption { font-weight: 600; }
  .metadata-table .col-observation { color: #475569; }

  /* Bucket dividers (Build #5.71.1 — iOS parity).
     Each grouped contact-sheet stream is preceded by one full page
     introducing the bucket: a coloured bar matching Bucket.colorHex
     and the bucket name + photo count. */
  .bucket-divider { display: flex; align-items: center;
                    justify-content: center; min-height: 10in; }
  .bucket-divider .bucket-block { display: flex; align-items: center;
                                  gap: 0.4in; }
  .bucket-divider .bucket-bar { width: 0.4in; height: 2.5in;
                                border-radius: 0.05in; }
  .bucket-divider .bucket-name { font-size: 36pt; font-weight: 600;
                                  color: #0f172a; line-height: 1.1; }
  .bucket-divider .bucket-count { font-size: 14pt; color: #64748b;
                                   margin-top: 0.15in; }
  `;
}

type PageDescription =
  | { kind: "cover" }
  | { kind: "divider"; bucket: Bucket | null; photoCount: number }
  | { kind: "photos"; items: ContactItem[] }
  | { kind: "section"; label: string }
  | { kind: "plan"; plan: FloorPlan }
  | { kind: "metadata"; photos: Photo[] };

/** Descriptions contain metadata references only; grouping happens globally once. */
function selectedPlans(project: Project, options: PdfExportOptions): FloorPlan[] {
  const selected = options.selectedFloorIds && new Set(options.selectedFloorIds.map(id => id.toLowerCase()));
  return project.floorPlans.filter(plan => selected === null || selected.has(plan.id.toLowerCase()));
}

function* describePages(project: Project, options: PdfExportOptions): Generator<PageDescription> {
  const photos = selectPhotos(project, options);
  if (options.includeCoverPage) yield { kind: "cover" };
  for (const section of options.sectionOrder) {
    if (section === "plan" && options.includeFloorPlanPages !== false) {
      for (const plan of selectedPlans(project, options)) {
        if (options.planMode !== "distressOnly" || plan.distress.length > 0) yield { kind: "plan", plan };
      }
    } else if (section === "metadataTable" && options.includeMetadataTable) {
      for (const batch of chunk(photos, METADATA_ROWS_PER_CHUNK)) yield { kind: "metadata", photos: batch };
    } else if (section === "contactSheets") {
      // Floor partitions match iOS: selected floors first, excluded/unplaced
      // photos retained in a trailing Unlocated section. Bucket ordering is
      // computed for each complete partition before any transport chunking.
      const plans = selectedPlans(project, options);
      const planIds = new Set(plans.map(plan => plan.id.toLowerCase()));
      const partitions = project.floorPlans.length ? [
        ...plans.map(plan => ({ label: plan.label, photos: photos.filter(photo => photo.floorPlanID?.toLowerCase() === plan.id.toLowerCase()) })),
        { label: "Unlocated photos", photos: photos.filter(photo => !photo.floorPlanID || !planIds.has(photo.floorPlanID.toLowerCase())) },
      ] : [{ label: null, photos }];
      for (const partition of partitions) {
        if (!partition.photos.length) continue;
        if (partition.label) yield { kind: "section", label: partition.label };
        const groups: Array<{ bucket: Bucket | null; photos: Photo[] }> = [];
        if (options.groupByBucket) {
          const known = new Set(project.buckets.map(b => b.id));
          for (const bucket of [...project.buckets].sort((a, b) => a.sortOrder - b.sortOrder)) {
            const members = partition.photos.filter(photo => photo.bucketID === bucket.id);
            if (members.length) groups.push({ bucket, photos: members });
          }
          const unbucketed = partition.photos.filter(photo => !photo.bucketID || !known.has(photo.bucketID));
          if (unbucketed.length) groups.push({ bucket: null, photos: unbucketed });
        } else groups.push({ bucket: null, photos: partition.photos });
        for (const group of groups) {
          if (options.groupByBucket) yield { kind: "divider", bucket: group.bucket, photoCount: group.photos.length };
          const items = group.photos.flatMap(photo => photo.markupOverlayFilename
            ? [{ photo, marked: false }, { photo, marked: true }] : [{ photo, marked: false }]);
          for (const page of chunk(items, options.perPage)) yield { kind: "photos", items: page };
        }
      }
    }
  }
}

function requiredAssets(page: PageDescription, photos: Map<string, AssetReference>, plans: Map<string, AssetReference>, markup: Map<string, AssetReference>): AssetReference[] {
  const require = (registry: Map<string, AssetReference>, id: string, kind: string) => {
    const asset = registry.get(id);
    if (!asset) throw new Error(`Required PDF ${kind} ${id} is not uploaded. Export aborted.`);
    return asset;
  };
  if (page.kind === "plan") return [require(plans, page.plan.id, "plan")];
  if (page.kind !== "photos") return [];
  return page.items.flatMap(({ photo, marked }) => marked
    ? [require(photos, photo.id, "photo"), require(markup, photo.id, "markup")]
    : [require(photos, photo.id, "photo")]);
}

/** Backpressure reaches R2: advancing the iterator is the only way to fetch
 * another bounded batch. Neither HTML nor base64 is retained for earlier chunks.
 * Plans are processed one at a time; there is no project-wide plan image cache. */
export async function* renderReportChunks(
  project: Project, projectId: string, log: FastifyBaseLogger, options: PdfExportOptions, branding?: ReportBrandingForExport
): AsyncGenerator<string> {
  const selected = selectPhotos(project, options);
  const plans = selectedPlans(project, options);
  const renderedPlans = options.includeFloorPlanPages === false || !options.sectionOrder.includes("plan") ? []
    : plans.filter(plan => options.planMode !== "distressOnly" || plan.distress.length > 0);
  const contactPhotos = options.sectionOrder.includes("contactSheets") ? selected : [];
  const marked = contactPhotos.filter(photo => photo.markupOverlayFilename);
  const [photoAssets, planAssets, markupAssets] = await Promise.all([
    resolveFileObjectKeysByPhotoId(projectId, contactPhotos.map(p => p.id), ["photo"], log, new Map(contactPhotos.map(p => [p.id, p.imageFilename]))),
    resolveFileObjectKeysByPhotoId(projectId, renderedPlans.map(p => p.id), ["plan"], log, new Map(renderedPlans.map(p => [p.id, p.imageFilename]))),
    resolveFileObjectKeysByPhotoId(projectId, marked.map(p => p.id), ["markup_png"], log, new Map(marked.map(p => [p.id, p.markupOverlayFilename!]))),
  ]);
  const styles = sharedStyles(options);
  const labels = new Map(plans.map(p => [p.id.toLowerCase(), p.label]));
  let pending: PageDescription[] = [];
  let pendingBytes = 0;

  async function* renderBatch(pages: PageDescription[]): AsyncGenerator<string> {
    const assets = new Map<string, AssetReference>();
    for (const page of pages) for (const asset of requiredAssets(page, photoAssets, planAssets, markupAssets)) assets.set(asset.key, asset);
    const blobs = await fetchImagesParallel([...assets.values()], log);
    let html: string[] = [];
    let pixels = 0;
    for (const page of pages) {
      // Repeated clean/marked cells share the same original data URL and
      // decoded bitmap; count each distinct image once per printed page.
      const pageImages = new Map(requiredAssets(page, photoAssets, planAssets, markupAssets).map(asset => [asset.key, asset]));
      const pagePixels = [...pageImages.values()].reduce((sum, a) => {
        const blob = blobs.get(a.key)!;
        return sum + blob.width * blob.height;
      }, 0);
      if (pagePixels > MAX_CHUNK_PIXELS) throw new Error("A PDF page contains too many image pixels. Choose fewer photos per page.");
      if (pixels + pagePixels > MAX_CHUNK_PIXELS && html.length) {
        yield wrapHtml(html.join("\n"), styles, project, branding);
        html = []; pixels = 0;
      }
      pixels += pagePixels;
      if (page.kind === "cover") html.push(coverPage(project, plans.length, branding));
      else if (page.kind === "section") html.push(`<section class="page floor-divider"><h2>${escapeHtml(page.label)}</h2></section>`);
      else if (page.kind === "divider") html.push(bucketDividerHtml(page.bucket, page.photoCount));
      else if (page.kind === "metadata") html.push(metadataTableHtml(page.photos, labels));
      else if (page.kind === "plan") {
        const asset = planAssets.get(page.plan.id)!;
        const pins = project.photos.filter(p => p.floorPlanID?.toLowerCase() === page.plan.id.toLowerCase() && p.trashedAt == null);
        html.push(planPages(page.plan, blobs.get(asset.key)!, pins, options.planMode, options.pinScale));
      } else {
        const byId = new Map(page.items.map(({ photo }) => [photo.id, blobs.get(photoAssets.get(photo.id)!.key)!]));
        const overlays = new Map(page.items.filter(item => item.marked).map(({ photo }) => [photo.id, blobs.get(markupAssets.get(photo.id)!.key)!]));
        html.push(contactSheetPage(page.items, byId, overlays, labels, options));
      }
      if (html.reduce((sum, part) => sum + Buffer.byteLength(part), 0) > MAX_CHUNK_HTML_BYTES) throw new Error("PDF chunk exceeds the safe HTML size limit. Reduce page content before exporting.");
    }
    if (html.length) yield wrapHtml(html.join("\n"), styles, project, branding);
  }

  for (const page of describePages(project, options)) {
    const assets = requiredAssets(page, photoAssets, planAssets, markupAssets);
    const bytes = assets.reduce((sum, asset) => sum + asset.sizeBytes, 0);
    if (bytes > MAX_CHUNK_IMAGE_BYTES) throw new Error("One PDF page exceeds 32 MiB of images. Choose fewer photos per page.");
    // Plans/metadata/cover own their chunk; contact pages preserve their global
    // pagination even when byte limits cause an earlier transport boundary.
    const standalone = page.kind === "plan" || page.kind === "metadata" || page.kind === "cover";
    if (pending.length && (standalone || pending.length >= PAGES_PER_CHUNK || pendingBytes + bytes > MAX_CHUNK_IMAGE_BYTES)) {
      yield* renderBatch(pending);
      pending = []; pendingBytes = 0;
    }
    pending.push(page); pendingBytes += bytes;
    if (standalone) { yield* renderBatch(pending); pending = []; pendingBytes = 0; }
  }
  if (pending.length) yield* renderBatch(pending);
}
