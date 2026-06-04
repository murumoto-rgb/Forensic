/**
 * Convert an `AIPhotoAnalysis` into the `TagSuggestion[]` list that
 * iOS's suggest/accept/reject UI expects (and that web's matching
 * "Pending suggestions" UI uses as of Build #5.41.1).
 *
 * MUST stay byte-equivalent to iOS's
 * `ClaudeTaggingService.suggestions(from:)`. Both platforms write
 * suggestions through the same pendingSuggestions array in the
 * manifest; if the shapes diverge, photos tagged on one platform
 * would render differently in the other's review UI.
 *
 * Behaviour mirrored from iOS:
 *  - Primary tags get a 0.99 sentinel confidence (high enough to
 *    pass any sane threshold; explicitly < 1.0 so the
 *    "user-typed = 1.0, AI-emitted < 1.0" discipline elsewhere in
 *    the codebase still treats them as removable).
 *  - Secondary tags pick up their per-tag confidence from
 *    `tagConfidences` (case-insensitive lookup, trimmed); missing
 *    entries fall back to 0.7 (above the 50% default threshold so
 *    orphans still render).
 *  - The legacy "none" sentinel in `secondary_tags_by_primary` is
 *    filtered out (case-insensitive, trimmed) — same v2-era
 *    compatibility guard the prompt compiler uses.
 *  - A leading "N. " number prefix on primary names is stripped
 *    (`stripLeadingNumber`) to defend against the model echoing
 *    a numbered context heading back into `primary_tags`.
 *  - When the model transcribed a measurement reading
 *    (`measurementVisible` non-empty), a synthetic
 *    "Measurement reading" suggestion is appended with the same
 *    0.99 confidence + nil parentTag (so it acts like a primary).
 *    The synthetic tag is NOT part of the controlled vocabulary —
 *    the validator ignores it.
 *
 * Pure function — no I/O, no side effects.
 */

import type { AIPhotoAnalysis, TagSuggestion } from "./manifest.js";

/** Sentinel confidence for AI-emitted primary tags. Same as iOS. */
const PRIMARY_CONFIDENCE = 0.99;
/** Fallback confidence for secondaries with no tag_confidences entry. */
const FALLBACK_SECONDARY_CONFIDENCE = 0.7;
/**
 * Stable label for the synthetic "this photo shows a measurement"
 * tag. Centralised so a future filter chip can check against the
 * same string web-side too.
 */
export const MEASUREMENT_TAG_LABEL = "Measurement reading";

export function aiAnalysisToSuggestions(
  analysis: AIPhotoAnalysis
): TagSuggestion[] {
  const out: TagSuggestion[] = [];

  // Lowercase-keyed confidence lookup so secondaries find their
  // entry regardless of casing mismatches between the
  // `secondary_tags_by_primary` map and the `tag_confidences` map.
  const confByLower = new Map<string, number>();
  for (const [k, v] of Object.entries(analysis.tagConfidences)) {
    confByLower.set(k.trim().toLowerCase(), v);
  }

  function secondaryConfidence(label: string): number {
    const key = stripLeadingNumber(label).trim().toLowerCase();
    const raw = confByLower.get(key);
    if (raw == null) return FALLBACK_SECONDARY_CONFIDENCE;
    return Math.max(0, Math.min(1, raw));
  }

  for (const primary of analysis.primaryTags) {
    const pTrim = stripLeadingNumber(primary.trim());
    if (pTrim.length === 0) continue;
    out.push({
      label: pTrim,
      confidence: PRIMARY_CONFIDENCE,
      source: "claude",
      parentTag: null,
    });
    // Match the secondary lookup against both the original key the
    // model returned AND the normalised primary (in case the model
    // emitted "1. Drainage / Grading" as the map key but the
    // primary list already has it stripped).
    const matchKey = Object.keys(analysis.secondaryTagsByPrimary).find((k) => {
      const normalised = stripLeadingNumber(k).trim().toLowerCase();
      const target = pTrim.toLowerCase();
      return k.toLowerCase() === target || normalised === target;
    });
    const secs = (matchKey && analysis.secondaryTagsByPrimary[matchKey]) || [];
    for (const sec of secs) {
      const sTrim = sec.trim();
      if (sTrim.length === 0 || sTrim.toLowerCase() === "none") continue;
      out.push({
        label: sTrim,
        confidence: secondaryConfidence(sTrim),
        source: "claude",
        parentTag: pTrim,
      });
    }
  }

  // Synthetic "Measurement reading" tag when the model transcribed
  // a reading. Outside the controlled vocabulary; validator ignores
  // it.
  const m = analysis.measurementVisible?.trim() ?? "";
  if (m.length > 0) {
    out.push({
      label: MEASUREMENT_TAG_LABEL,
      confidence: 0.99,
      source: "claude",
      parentTag: null,
    });
  }

  return out;
}

/**
 * Strip a leading "N. " (one or more digits + period + optional
 * whitespace) from a tag name. Same regex iOS uses
 * (`#"^\d+\.\s*"#`) — defensive against a model variant that
 * echoes context numbers back into `primary_tags`.
 */
function stripLeadingNumber(s: string): string {
  return s.replace(/^\d+\.\s*/, "");
}
