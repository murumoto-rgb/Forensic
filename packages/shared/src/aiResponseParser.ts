/**
 * Parse Claude's raw text response into an `AIPhotoAnalysis`. Used
 * by the web "Re-tag with AI" button to convert the `/v1/ai/tag-photo`
 * proxy's `rawText` into the same struct shape iOS produces.
 *
 * Mirrors the iOS-side `parseResult(fromText:)` in
 * `ios/SitePhoto/Services/ClaudeTaggingService.swift` byte-for-byte
 * so the same response from the model produces the same parsed
 * struct regardless of which platform invoked the call.
 *
 * Soft-failure semantics: on parse failure the function STILL
 * returns an `AIPhotoAnalysis` — with `parseFailed: true`,
 * `rawResponse` carrying the offending text, and `validationErrors`
 * recording the reason. The caller persists it so the user can
 * revisit later, rather than the whole call being lost.
 */

import type { AIPhotoAnalysis } from "./manifest.js";

export function parseAIPhotoAnalysis(args: {
  rawText: string;
  fallbackPhotoID: string;
}): AIPhotoAnalysis {
  const { rawText, fallbackPhotoID } = args;

  if (rawText.length === 0) {
    return softFailure({
      rawResponse: "(empty content)",
      photoID: fallbackPhotoID,
      reason: "Claude returned no text content.",
    });
  }

  // Strip code fences first, then take the slice between the first
  // `{` and last `}`. Tolerates models that wrap JSON in ```json …
  // fences or add a stray "Here's the analysis:" prefix.
  const stripped = stripCodeFences(rawText);
  const firstBrace = stripped.indexOf("{");
  const lastBrace = stripped.lastIndexOf("}");
  if (firstBrace < 0 || lastBrace < 0 || firstBrace > lastBrace) {
    return softFailure({
      rawResponse: rawText,
      photoID: fallbackPhotoID,
      reason: "No JSON object found in Claude's response.",
    });
  }
  const jsonSlice = stripped.substring(firstBrace, lastBrace + 1);

  let payload: ClaudePayload;
  try {
    payload = JSON.parse(jsonSlice) as ClaudePayload;
  } catch (err) {
    return softFailure({
      rawResponse: rawText,
      photoID: fallbackPhotoID,
      reason: `JSON decode failed: ${
        err instanceof Error ? err.message : String(err)
      }`,
    });
  }

  const resolvedPhotoID =
    typeof payload.photo_id === "string" && payload.photo_id.trim().length > 0
      ? payload.photo_id.trim()
      : fallbackPhotoID;

  return {
    photoID: resolvedPhotoID,
    primaryTags: payload.primary_tags ?? [],
    secondaryTagsByPrimary: payload.secondary_tags_by_primary ?? {},
    tagConfidences: payload.tag_confidences ?? {},
    locationInferred: (payload.location_inferred ?? "").trim(),
    scalePresent: payload.scale_present ?? "",
    measurementVisible: nonEmptyOrNull(payload.measurement_visible),
    summaryObservation: (payload.summary_observation ?? "").trim(),
    captionDraft: (payload.caption_draft ?? "").trim(),
    recommendedUse: payload.recommended_use ?? "",
    reviewerFlag: (payload.reviewer_flag ?? "").trim(),
    // Web doesn't run the iOS-side vocabulary validator yet — that
    // logic lives in iOS's AIResponseValidator and would need its
    // own TS port. For now we don't surface validation issues from
    // the web side; the engineer can spot bad output by eye.
    validationErrors: [],
    rawResponse: rawText,
    parseFailed: false,
  };
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

interface ClaudePayload {
  photo_id?: string;
  primary_tags?: string[];
  secondary_tags_by_primary?: Record<string, string[]>;
  tag_confidences?: Record<string, number>;
  location_inferred?: string;
  scale_present?: string;
  measurement_visible?: string;
  summary_observation?: string;
  caption_draft?: string;
  recommended_use?: string;
  reviewer_flag?: string;
}

function softFailure(args: {
  rawResponse: string;
  photoID: string;
  reason: string;
}): AIPhotoAnalysis {
  return {
    photoID: args.photoID,
    primaryTags: [],
    secondaryTagsByPrimary: {},
    tagConfidences: {},
    locationInferred: "",
    scalePresent: "",
    measurementVisible: null,
    summaryObservation: "",
    captionDraft: "",
    recommendedUse: "",
    reviewerFlag: "",
    validationErrors: [args.reason],
    rawResponse: args.rawResponse,
    parseFailed: true,
  };
}

function stripCodeFences(s: string): string {
  let t = s;
  const fenceJSON = t.indexOf("```json");
  if (fenceJSON >= 0) {
    t = t.substring(fenceJSON + "```json".length);
  } else {
    const fence = t.indexOf("```");
    if (fence >= 0) t = t.substring(fence + 3);
  }
  const lastFence = t.lastIndexOf("```");
  if (lastFence >= 0) {
    t = t.substring(0, lastFence);
  }
  return t;
}

function nonEmptyOrNull(v: string | undefined | null): string | null {
  if (v == null) return null;
  const trimmed = v.trim();
  return trimmed.length === 0 ? null : trimmed;
}
