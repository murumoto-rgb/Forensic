/**
 * Parity test for `aiAnalysisToSuggestions` against iOS's
 * `ClaudeTaggingService.suggestions(from:)`. Both platforms write
 * suggestions through the same `pendingSuggestions` array in the
 * manifest, so if the shapes diverge a photo's review UI would
 * render different chips depending on which device tagged it.
 *
 * Same regeneration discipline as the prompt-compiler snapshot
 * test: if you change the iOS implementation, change this test in
 * the same PR.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  aiAnalysisToSuggestions,
  MEASUREMENT_TAG_LABEL,
} from "../src/aiSuggestions.js";
import type { AIPhotoAnalysis } from "../src/manifest.js";

describe("aiAnalysisToSuggestions — iOS parity", () => {
  it("emits primary + secondary suggestions with correct confidences", () => {
    const analysis: AIPhotoAnalysis = {
      photoID: "abc.jpg",
      primaryTags: ["Drainage / Grading", "Foundation / Grade Beam"],
      secondaryTagsByPrimary: {
        "Drainage / Grading": [
          "Drainage visually away from foundation",
          "Marginal or flat drainage adjacent to foundation",
        ],
        "Foundation / Grade Beam": ["Grade beam crack"],
      },
      tagConfidences: {
        "Drainage visually away from foundation": 0.82,
        "Marginal or flat drainage adjacent to foundation": 0.61,
        // Grade beam crack intentionally missing — exercises the
        // fallback confidence path.
      },
      locationInferred: "",
      scalePresent: "",
      measurementVisible: null,
      summaryObservation: "",
      captionDraft: "",
      recommendedUse: "",
      reviewerFlag: "",
      validationErrors: [],
      rawResponse: null,
      parseFailed: false,
    };

    const suggestions = aiAnalysisToSuggestions(analysis);

    assert.deepEqual(suggestions, [
      {
        label: "Drainage / Grading",
        confidence: 0.99,
        source: "claude",
        parentTag: null,
      },
      {
        label: "Drainage visually away from foundation",
        confidence: 0.82,
        source: "claude",
        parentTag: "Drainage / Grading",
      },
      {
        label: "Marginal or flat drainage adjacent to foundation",
        confidence: 0.61,
        source: "claude",
        parentTag: "Drainage / Grading",
      },
      {
        label: "Foundation / Grade Beam",
        confidence: 0.99,
        source: "claude",
        parentTag: null,
      },
      {
        label: "Grade beam crack",
        confidence: 0.7,
        source: "claude",
        parentTag: "Foundation / Grade Beam",
      },
    ]);
  });

  it("filters the legacy 'None' sentinel from secondaries", () => {
    const analysis: AIPhotoAnalysis = baseAnalysis({
      primaryTags: ["X"],
      secondaryTagsByPrimary: { X: ["Real one", "None", "  none  "] },
    });
    const suggestions = aiAnalysisToSuggestions(analysis);
    assert.equal(suggestions.length, 2);
    assert.equal(suggestions[0]?.label, "X");
    assert.equal(suggestions[1]?.label, "Real one");
  });

  it("strips a leading 'N. ' number prefix from primary names", () => {
    const analysis: AIPhotoAnalysis = baseAnalysis({
      primaryTags: ["1. Drainage / Grading"],
      secondaryTagsByPrimary: {
        "1. Drainage / Grading": ["Visually adequate"],
      },
    });
    const suggestions = aiAnalysisToSuggestions(analysis);
    // Primary stripped, secondary attached to the stripped primary.
    assert.equal(suggestions[0]?.label, "Drainage / Grading");
    assert.equal(suggestions[1]?.parentTag, "Drainage / Grading");
  });

  it("finds secondaries even when the map key is the un-numbered primary", () => {
    const analysis: AIPhotoAnalysis = baseAnalysis({
      primaryTags: ["1. Drainage / Grading"],
      // Model emitted the secondary map keyed by the stripped name.
      secondaryTagsByPrimary: { "Drainage / Grading": ["Visually adequate"] },
    });
    const suggestions = aiAnalysisToSuggestions(analysis);
    assert.equal(suggestions.length, 2);
    assert.equal(suggestions[1]?.label, "Visually adequate");
    assert.equal(suggestions[1]?.parentTag, "Drainage / Grading");
  });

  it("emits a Measurement Reading suggestion when measurementVisible is non-empty", () => {
    const analysis: AIPhotoAnalysis = baseAnalysis({
      primaryTags: ["X"],
      measurementVisible: "3.5°",
    });
    const suggestions = aiAnalysisToSuggestions(analysis);
    const last = suggestions[suggestions.length - 1];
    assert.equal(last?.label, MEASUREMENT_TAG_LABEL);
    assert.equal(last?.confidence, 0.99);
    assert.equal(last?.parentTag, null);
  });

  it("omits Measurement Reading when measurementVisible is null or whitespace", () => {
    const a1 = baseAnalysis({ primaryTags: ["X"], measurementVisible: null });
    assert.equal(
      aiAnalysisToSuggestions(a1).some(
        (s) => s.label === MEASUREMENT_TAG_LABEL
      ),
      false
    );
    const a2 = baseAnalysis({ primaryTags: ["X"], measurementVisible: "   " });
    assert.equal(
      aiAnalysisToSuggestions(a2).some(
        (s) => s.label === MEASUREMENT_TAG_LABEL
      ),
      false
    );
  });

  it("clamps a secondary confidence into [0, 1]", () => {
    const analysis: AIPhotoAnalysis = baseAnalysis({
      primaryTags: ["X"],
      secondaryTagsByPrimary: { X: ["A", "B"] },
      tagConfidences: { A: 1.5, B: -0.3 },
    });
    const suggestions = aiAnalysisToSuggestions(analysis);
    assert.equal(suggestions[1]?.confidence, 1);
    assert.equal(suggestions[2]?.confidence, 0);
  });

  it("returns an empty array when there are no primaries", () => {
    const analysis = baseAnalysis({ primaryTags: [] });
    assert.deepEqual(aiAnalysisToSuggestions(analysis), []);
  });
});

function baseAnalysis(overrides: Partial<AIPhotoAnalysis>): AIPhotoAnalysis {
  return {
    photoID: "abc.jpg",
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
    validationErrors: [],
    rawResponse: null,
    parseFailed: false,
    ...overrides,
  };
}
