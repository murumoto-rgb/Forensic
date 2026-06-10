/**
 * Defaults + canonical shape for PdfExportOptions (Build #5.64.1,
 * extended to iOS parity in #5.67.1).
 *
 * The POST endpoint accepts `Partial<PdfExportOptions>` so old
 * clients that send `{}` still work; this helper fills in the rest.
 * The new iOS-parity fields default to the same values iOS uses
 * (`AnnotationOptions.defaults`, `perPage: 6`,
 * `planMode: photoOnly`, etc.). The legacy web-specific fields keep
 * their #5.64.1 defaults.
 *
 * Backwards compatibility: the renderer (across #5.68.1 — #5.71.1)
 * reads each new field with a fallback to its legacy counterpart
 * (`perPage` ← `photosPerPage`, `selectedFloorIds` ← `floorPlanId`,
 * etc.). The defaults block here doesn't synthesize legacy values
 * from new fields — the new fields are the canonical truth as of
 * the parity rollout.
 */

import type {
  PdfAnnotationOptions,
  PdfExportOptions,
} from "@forensic/shared";

/** Matches iOS `PDFExportOptions.AnnotationOptions.defaults`. */
export const DEFAULT_PDF_ANNOTATIONS: PdfAnnotationOptions = {
  includeTags: true,
  includeCaption: false,
  includeObservation: false,
  includeMeasurement: false,
  includeReviewerFlag: false,
};

export const DEFAULT_PDF_EXPORT_OPTIONS: PdfExportOptions = {
  // iOS-parity defaults (mirror PDFExportOptions.defaults exactly).
  perPage: 6,
  groupByBucket: false,
  includeMetadataTable: false,
  annotations: DEFAULT_PDF_ANNOTATIONS,
  sectionOrder: ["plan", "contactSheets", "metadataTable"],
  selectedFloorIds: null,
  planMode: "photoOnly",

  // Web-specific carryover.
  pageSize: "letter",
  includeTrashed: false,
  includeCoverPage: true,
  pinScale: 1,
};

/** Clamp the iOS-parity `perPage` Int to the renderer's supported
 *  range. iOS clamps via UI; on the server we clamp defensively. */
const MIN_PER_PAGE = 1;
const MAX_PER_PAGE = 12;
function clampPerPage(value: number | undefined): number {
  if (value == null || !Number.isFinite(value)) {
    return DEFAULT_PDF_EXPORT_OPTIONS.perPage;
  }
  const rounded = Math.round(value);
  if (rounded < MIN_PER_PAGE) return MIN_PER_PAGE;
  if (rounded > MAX_PER_PAGE) return MAX_PER_PAGE;
  return rounded;
}

/** Clamp the plan-page pin scale (Build #6.20.1). Matches the
 *  shared `UserPrefs.planBubbleScale` zod range. */
const MIN_PIN_SCALE = 0.5;
const MAX_PIN_SCALE = 4;
function clampPinScale(value: number | undefined): number {
  if (value == null || !Number.isFinite(value)) {
    return DEFAULT_PDF_EXPORT_OPTIONS.pinScale;
  }
  if (value < MIN_PIN_SCALE) return MIN_PIN_SCALE;
  if (value > MAX_PIN_SCALE) return MAX_PIN_SCALE;
  return value;
}

function mergeAnnotations(
  partial: Partial<PdfAnnotationOptions> | undefined
): PdfAnnotationOptions {
  if (!partial) return DEFAULT_PDF_ANNOTATIONS;
  return {
    includeTags: partial.includeTags ?? DEFAULT_PDF_ANNOTATIONS.includeTags,
    includeCaption:
      partial.includeCaption ?? DEFAULT_PDF_ANNOTATIONS.includeCaption,
    includeObservation:
      partial.includeObservation ?? DEFAULT_PDF_ANNOTATIONS.includeObservation,
    includeMeasurement:
      partial.includeMeasurement ?? DEFAULT_PDF_ANNOTATIONS.includeMeasurement,
    includeReviewerFlag:
      partial.includeReviewerFlag ??
      DEFAULT_PDF_ANNOTATIONS.includeReviewerFlag,
  };
}

/** Resolve the `sectionOrder` array. Ensures every section appears
 *  exactly once — mirrors iOS's decoder logic where a newly-added
 *  enum case gets appended to whatever the user had persisted. */
function resolveSectionOrder(
  partial: PdfExportOptions["sectionOrder"] | undefined
): PdfExportOptions["sectionOrder"] {
  const stored = partial ?? DEFAULT_PDF_EXPORT_OPTIONS.sectionOrder;
  const seen = new Set<string>();
  const resolved: PdfExportOptions["sectionOrder"] = [];
  for (const s of stored) {
    if (!seen.has(s)) {
      resolved.push(s);
      seen.add(s);
    }
  }
  for (const s of DEFAULT_PDF_EXPORT_OPTIONS.sectionOrder) {
    if (!seen.has(s)) {
      resolved.push(s);
      seen.add(s);
    }
  }
  return resolved;
}

export function applyOptionDefaults(
  partial: Partial<PdfExportOptions>
): PdfExportOptions {
  return {
    // iOS-parity fields.
    perPage: clampPerPage(partial.perPage),
    groupByBucket:
      partial.groupByBucket ?? DEFAULT_PDF_EXPORT_OPTIONS.groupByBucket,
    includeMetadataTable:
      partial.includeMetadataTable ??
      DEFAULT_PDF_EXPORT_OPTIONS.includeMetadataTable,
    annotations: mergeAnnotations(partial.annotations),
    sectionOrder: resolveSectionOrder(partial.sectionOrder),
    selectedFloorIds: partial.selectedFloorIds ?? null,
    planMode: partial.planMode ?? DEFAULT_PDF_EXPORT_OPTIONS.planMode,

    // Web-specific carryover.
    pageSize: partial.pageSize ?? DEFAULT_PDF_EXPORT_OPTIONS.pageSize,
    includeTrashed:
      partial.includeTrashed ?? DEFAULT_PDF_EXPORT_OPTIONS.includeTrashed,
    includeCoverPage:
      partial.includeCoverPage ?? DEFAULT_PDF_EXPORT_OPTIONS.includeCoverPage,
    pinScale: clampPinScale(partial.pinScale),

    // Legacy fields — preserved when sent. When the caller is a new
    // client that didn't include them, we synthesize the #5.64.1
    // defaults so the renderer (which still reads these directly
    // until PRs #5.68.1 — #5.71.1 land) keeps producing valid PDFs
    // during the rollout.
    photosPerPage: partial.photosPerPage,
    photoFilter: partial.photoFilter ?? "all",
    floorPlanId: partial.floorPlanId ?? null,
    includeFloorPlanPages: partial.includeFloorPlanPages ?? true,
  };
}
