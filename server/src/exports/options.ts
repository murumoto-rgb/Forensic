/**
 * Defaults + canonical shape for PdfExportOptions (Build #5.64.1).
 *
 * The POST endpoint accepts `Partial<PdfExportOptions>` so old
 * clients that send `{}` still work; this helper fills in the rest.
 * The defaults match the behaviour of #5.63.1's fixed layout
 * (all photos, 1 per page, Letter, cover + plans included) so any
 * existing client that POSTs an empty body keeps producing the same
 * output it did before this PR.
 */

import type { PdfExportOptions } from "@forensic/shared";

export const DEFAULT_PDF_EXPORT_OPTIONS: PdfExportOptions = {
  pageSize: "letter",
  photosPerPage: 1,
  photoFilter: "all",
  floorPlanId: null,
  includeTrashed: false,
  includeCoverPage: true,
  includeFloorPlanPages: true,
};

export function applyOptionDefaults(
  partial: Partial<PdfExportOptions>
): PdfExportOptions {
  return {
    pageSize: partial.pageSize ?? DEFAULT_PDF_EXPORT_OPTIONS.pageSize,
    photosPerPage:
      partial.photosPerPage ?? DEFAULT_PDF_EXPORT_OPTIONS.photosPerPage,
    photoFilter: partial.photoFilter ?? DEFAULT_PDF_EXPORT_OPTIONS.photoFilter,
    floorPlanId: partial.floorPlanId ?? null,
    includeTrashed:
      partial.includeTrashed ?? DEFAULT_PDF_EXPORT_OPTIONS.includeTrashed,
    includeCoverPage:
      partial.includeCoverPage ?? DEFAULT_PDF_EXPORT_OPTIONS.includeCoverPage,
    includeFloorPlanPages:
      partial.includeFloorPlanPages ??
      DEFAULT_PDF_EXPORT_OPTIONS.includeFloorPlanPages,
  };
}
