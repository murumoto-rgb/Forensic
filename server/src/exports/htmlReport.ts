/**
 * HTML report renderer for the server-side PDF export
 * (Build #5.63.1, PR #2 of 3 for plan item #3).
 *
 * Pulls photo thumbnails + plan images out of R2, base64-encodes
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
 * (then `planPixelX/Y` coordinates land on the right pixel). The
 * `image-size` lib reads the dimensions off the raw bytes — cheap,
 * no decode required.
 *
 * Photo cap: at 200+ photos the base64'd HTML hits double-digit MBs
 * and Chromium starts to struggle on Render's 512 MB tier. The
 * worker surfaces a clear "too large" error rather than OOM. Future
 * options-sheet PR (#3) can let the user pick a subset.
 */

import type { FastifyBaseLogger } from "fastify";
import { imageSize } from "image-size";
import type {
  Bucket,
  DistressKind,
  DistressMark,
  FloorPlan,
  PdfAnnotationOptions,
  PdfExportOptions,
  PdfPlanMode,
  PdfSection,
  Photo,
  Project,
} from "@forensic/shared";
import { getObjectBytes } from "../r2.js";

/**
 * Maximum HTML pages per rendered chunk (Build #5.72.1 — chunked
 * rendering). The renderer now produces an array of HTML chunks;
 * each chunk goes through its own Puppeteer setContent → page.pdf
 * cycle, and the worker merges the per-chunk PDF buffers with
 * `pdf-lib`. This caps Chromium's working set to one chunk's
 * worth of HTML, dropping the previous `MAX_PHOTOS_PER_PDF = 1000`
 * limit entirely. Picked conservatively for Render's free-tier
 * 512 MB: at perPage=6 a chunk carries ~150 photos worth of
 * inline-base64 thumbs ≈ 4-5 MB HTML, well within memory budget.
 */
export const PAGES_PER_CHUNK = 25;

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

/** Object key conventions match `buildObjectKey` in r2.ts — the
 *  PDF worker reads from the same paths the iOS uploader writes
 *  to. */
function photoThumbKey(projectId: string, photoId: string): string {
  return `${projectId}/${photoId}/thumb`;
}
function photoImageKey(projectId: string, photoId: string): string {
  return `${projectId}/${photoId}/photo`;
}
function planImageKey(projectId: string, planId: string): string {
  return `${projectId}/${planId}/plan`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

interface ImageBlob {
  dataUrl: string;
  width: number;
  height: number;
}

/** Read bytes from R2 and produce a base64 `data:` URL plus the
 *  decoded intrinsic dimensions. Returns null if the object is
 *  missing — the caller renders a "(image pending)" placeholder. */
async function fetchImage(
  objectKey: string,
  log: FastifyBaseLogger
): Promise<ImageBlob | null> {
  try {
    const bytes = await getObjectBytes(objectKey);
    let dims: { width?: number; height?: number; type?: string };
    try {
      dims = imageSize(bytes);
    } catch {
      // image-size returns a typed shape on success; on unknown
      // format it throws. Be permissive — we still want to show
      // the image even if we can't probe it.
      dims = {};
    }
    const mime =
      dims.type === "png"
        ? "image/png"
        : dims.type === "heic"
          ? "image/heic"
          : "image/jpeg";
    const dataUrl = `data:${mime};base64,${bytes.toString("base64")}`;
    return {
      dataUrl,
      width: dims.width ?? 0,
      height: dims.height ?? 0,
    };
  } catch (err) {
    log.warn({ err, objectKey }, "pdf renderer — image fetch failed");
    return null;
  }
}

/** Parallel fetch with a small concurrency cap so we don't open a
 *  hundred sockets to R2 at once. Returns a map from object key to
 *  result so callers can look up by id. */
async function fetchImagesParallel(
  keys: string[],
  log: FastifyBaseLogger,
  concurrency = 6
): Promise<Map<string, ImageBlob | null>> {
  const results = new Map<string, ImageBlob | null>();
  let cursor = 0;
  async function worker() {
    while (cursor < keys.length) {
      const idx = cursor++;
      const key = keys[idx];
      if (!key) continue;
      const blob = await fetchImage(key, log);
      results.set(key, blob);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(concurrency, keys.length) }, worker)
  );
  return results;
}

// ---------------------------------------------------------------------------
// Page renderers
// ---------------------------------------------------------------------------

function coverPage(project: Project): string {
  const photoCount = project.photos.filter((p) => p.trashedAt == null).length;
  const planCount = project.floorPlans.length;
  const generatedAt = new Date().toLocaleString("en-US", {
    dateStyle: "long",
    timeStyle: "short",
  });
  const gps = project.projectGPS;
  return `<section class="page cover">
    <h1>${escapeHtml(project.name)}</h1>
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
  thumb: ImageBlob | null,
  planLabel: string | null,
  annotations: PdfAnnotationOptions
): string {
  const seq = `#${photo.sequenceNumber}`;
  return `<div class="tile">
    <div class="tile-header">
      <span class="seq">${escapeHtml(seq)}</span>
      ${planLabel ? `<span class="plan">${escapeHtml(planLabel)}</span>` : ""}
    </div>
    <div class="tile-image">
      ${
        thumb
          ? `<img src="${thumb.dataUrl}" alt="${escapeHtml(seq)}">`
          : `<div class="missing">pending sync</div>`
      }
    </div>
    ${annotationsHtml(photo, annotations)}
  </div>`;
}

/** One printed page containing up to `perPage` photo tiles. */
function contactSheetPage(
  photos: Photo[],
  blobs: Map<string, ImageBlob | null>,
  projectId: string,
  planLabelById: Map<string, string>,
  options: PdfExportOptions
): string {
  const { cols, rows } = gridDimensions(options.perPage);
  const tilesHtml = photos
    .map((p) => {
      const tileKey = p.thumbnailFilename
        ? photoThumbKey(projectId, p.id)
        : photoImageKey(projectId, p.id);
      const blob = blobs.get(tileKey) ?? null;
      const planLabel = p.floorPlanID
        ? planLabelById.get(p.floorPlanID) ?? null
        : null;
      return contactSheetTile(p, blob, planLabel, options.annotations);
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

function distressOverlay(mark: DistressMark): string {
  const color = DISTRESS_COLORS[mark.kind] ?? "#ef4444";
  const pts = mark.points.map(pointToXy).filter((p): p is { x: number; y: number } => p != null);
  if (pts.length === 0) return "";
  if (mark.kind === "crackFloor") {
    // Polyline stroke. Stroke width set to a fraction of the
    // image's smaller dimension so it scales with zoom.
    const d = pts.map((p, i) => `${i === 0 ? "M" : "L"}${p.x},${p.y}`).join(" ");
    return `<path d="${d}" stroke="${color}" stroke-width="6" fill="none" stroke-linecap="round" stroke-linejoin="round" opacity="0.85"/>`;
  }
  // Point distress — circle marker at the first point.
  const p = pts[0]!;
  return `<g><circle cx="${p.x}" cy="${p.y}" r="12" fill="${color}" opacity="0.85"/></g>`;
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
}

function planSection(
  plan: FloorPlan,
  planImage: ImageBlob | null,
  planPhotos: Photo[],
  sectionOptions: PlanSectionOptions
): string {
  const title = sectionOptions.subtitle
    ? `${escapeHtml(plan.label)} <span class="subtitle">— ${escapeHtml(sectionOptions.subtitle)}</span>`
    : escapeHtml(plan.label);
  if (!planImage) {
    return `<section class="page plan">
      <h2>${title}</h2>
      <div class="missing">(plan image pending sync)</div>
    </section>`;
  }
  const W = planImage.width || 1000;
  const H = planImage.height || 1000;
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
            <circle cx="${x}" cy="${y}" r="14" fill="#2563eb" stroke="#fff" stroke-width="2"/>
            <text x="${x}" y="${y + 5}" text-anchor="middle" font-size="14" fill="#fff" font-weight="600">${p.sequenceNumber}</text>
          </g>`;
        })
        .join("")
    : "";
  const distressSvg = sectionOptions.includeDistress
    ? plan.distress.map(distressOverlay).join("")
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
  planImage: ImageBlob | null,
  planPhotos: Photo[],
  mode: PdfPlanMode
): string {
  if (mode === "photoAndDistressSeparate") {
    const photoPage = planSection(plan, planImage, planPhotos, {
      includePhotos: true,
      includeDistress: false,
      subtitle: "Photos",
    });
    const distressPage = planSection(plan, planImage, planPhotos, {
      includePhotos: false,
      includeDistress: true,
      subtitle: "Distress",
    });
    return `${photoPage}\n${distressPage}`;
  }
  return planSection(plan, planImage, planPhotos, {
    includePhotos: modeRendersPhotos(mode),
    includeDistress: modeRendersDistress(mode),
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
function renderUngroupedContactSheets(
  selectedPhotos: Photo[],
  perPage: number,
  blobs: Map<string, ImageBlob | null>,
  projectId: string,
  planLabelById: Map<string, string>,
  options: PdfExportOptions
): string[] {
  return chunk(selectedPhotos, perPage).map((group) =>
    contactSheetPage(group, blobs, projectId, planLabelById, options)
  );
}

function renderBucketedContactSheets(
  selectedPhotos: Photo[],
  buckets: Bucket[],
  perPage: number,
  blobs: Map<string, ImageBlob | null>,
  projectId: string,
  planLabelById: Map<string, string>,
  options: PdfExportOptions
): string[] {
  // Build a stable order: buckets by `sortOrder`, then a trailing
  // sentinel for "Unbucketed". Photos missing or pointing at a
  // deleted bucket land in the sentinel group.
  const bucketById = new Map(buckets.map((b) => [b.id, b]));
  const orderedBuckets = [...buckets].sort(
    (a, b) => a.sortOrder - b.sortOrder
  );

  const groups: Array<{ bucket: Bucket | null; photos: Photo[] }> = [];
  for (const b of orderedBuckets) {
    const photos = selectedPhotos.filter((p) => p.bucketID === b.id);
    if (photos.length > 0) groups.push({ bucket: b, photos });
  }
  const unbucketed = selectedPhotos.filter(
    (p) => !p.bucketID || !bucketById.has(p.bucketID)
  );
  if (unbucketed.length > 0) groups.push({ bucket: null, photos: unbucketed });

  // Each bucket group contributes: [dividerPage, ...sheetPages].
  const pages: string[] = [];
  for (const { bucket, photos } of groups) {
    pages.push(bucketDividerHtml(bucket, photos.length));
    for (const sheet of chunk(photos, perPage)) {
      pages.push(
        contactSheetPage(sheet, blobs, projectId, planLabelById, options)
      );
    }
  }
  return pages;
}

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

/** Plan-pages section renderer extracted in #5.71.1 so the
 *  body-section iteration over `sectionOrder` can compose it from
 *  one call. Returns "" when there are no plans OR the
 *  caller-configured legacy `includeFloorPlanPages` flag is false. */
function renderPlanPages(
  floorPlans: FloorPlan[],
  allPhotos: Photo[],
  blobs: Map<string, ImageBlob | null>,
  projectId: string,
  options: PdfExportOptions
): string[] {
  if (floorPlans.length === 0) return [];
  // Honour the legacy includeFloorPlanPages flag when present (jobs
  // persisted before #5.67.1 wrote it). Once the modal in #5.73.1
  // drops it, sectionOrder is the only switch — but for the rollout
  // we keep both working.
  if (options.includeFloorPlanPages === false) return [];
  return floorPlans.map((plan) => {
    const key = planImageKey(projectId, plan.id);
    const blob = blobs.get(key) ?? null;
    // The plan still shows ALL its pins (not just the filtered
    // selection) — engineers want the unfiltered spatial picture
    // even when they exported a subset.
    const planPhotos = allPhotos.filter(
      (p) => p.floorPlanID === plan.id && p.trashedAt == null
    );
    return planPages(plan, blob, planPhotos, options.planMode);
  });
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
        ? planLabelById.get(p.floorPlanID) ?? "—"
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
  let pool = project.photos;
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
  project: Project
): string {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>${escapeHtml(project.name)}</title>
<style>${styles}</style></head>
<body>${bodyHtml}</body></html>`;
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
  .tile-image { flex: 1 1 auto; display: flex; justify-content: center;
                align-items: center; background: #f1f5f9;
                border: 1px solid #e2e8f0; min-height: 0; }
  .tile-image img { max-height: 100%; max-width: 100%; object-fit: contain; }
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

/**
 * Build the report as an array of HTML chunks (Build #5.72.1 —
 * chunked rendering). Each chunk is a complete `<html>` document
 * that the worker pipes through one Puppeteer setContent →
 * page.pdf cycle; the per-chunk PDFs are then merged with
 * `pdf-lib`. This caps Chromium's working set per chunk, which
 * lets us drop the previous 1000-photo hard cap entirely.
 *
 * Chunk strategy:
 *   - Cover page is its own chunk when `options.includeCoverPage`.
 *   - Plan-pages section is one chunk (rarely >10 plans).
 *   - Metadata-table section is one chunk.
 *   - Contact-sheets section is split into sub-chunks of
 *     `PAGES_PER_CHUNK` pages each (~150 photos at perPage=6).
 *     The body's overall `options.sectionOrder` is honoured —
 *     sections appear in the merged PDF in that order.
 *
 * Empty sections are dropped before chunking so an over-filtered
 * export doesn't produce orphan empty chunks.
 */
export async function renderReportChunks(
  project: Project,
  projectId: string,
  log: FastifyBaseLogger,
  options: PdfExportOptions
): Promise<string[]> {
  const selectedPhotos = selectPhotos(project, options);

  // Fetch all images (photos + plans) in one parallel pass so chunks
  // share a single read of R2 — moving fetch inside the per-chunk
  // loop would multiply round trips by chunk count.
  const planKeys = options.includeFloorPlanPages
    ? project.floorPlans.map((p) => planImageKey(projectId, p.id))
    : [];
  const photoKeys = selectedPhotos.map((p) =>
    p.thumbnailFilename
      ? photoThumbKey(projectId, p.id)
      : photoImageKey(projectId, p.id)
  );
  const allKeys = Array.from(new Set([...photoKeys, ...planKeys]));
  const blobs = await fetchImagesParallel(allKeys, log);

  const planLabelById = new Map(
    project.floorPlans.map((p) => [p.id, p.label] as const)
  );

  const perPageResolved = options.perPage ?? options.photosPerPage ?? 6;

  const contactSheetPages = options.groupByBucket
    ? renderBucketedContactSheets(
        selectedPhotos,
        project.buckets,
        perPageResolved,
        blobs,
        projectId,
        planLabelById,
        options
      )
    : renderUngroupedContactSheets(
        selectedPhotos,
        perPageResolved,
        blobs,
        projectId,
        planLabelById,
        options
      );

  const planPages = renderPlanPages(
    project.floorPlans,
    project.photos,
    blobs,
    projectId,
    options
  );

  const metadataPage = options.includeMetadataTable
    ? metadataTableHtml(selectedPhotos, planLabelById)
    : "";

  const styles = sharedStyles(options);
  const chunks: string[] = [];

  if (options.includeCoverPage) {
    chunks.push(wrapHtml(coverPage(project), styles, project));
  }

  // Each `PdfSection` slot maps to an array of HTML chunks (could be
  // empty when its underlying data is absent). The outer order
  // honours `options.sectionOrder`; inside `contactSheets`, sub-
  // chunks of `PAGES_PER_CHUNK` pages each cap per-chunk memory.
  const sectionChunksByKey: Record<PdfSection, string[]> = {
    plan:
      planPages.length === 0
        ? []
        : [wrapHtml(planPages.join("\n"), styles, project)],
    contactSheets: chunk(contactSheetPages, PAGES_PER_CHUNK).map((pages) =>
      wrapHtml(pages.join("\n"), styles, project)
    ),
    metadataTable:
      metadataPage.length === 0
        ? []
        : [wrapHtml(metadataPage, styles, project)],
  };

  for (const sectionKey of options.sectionOrder) {
    const sectionChunks = sectionChunksByKey[sectionKey];
    if (sectionChunks) chunks.push(...sectionChunks);
  }

  return chunks;
}
