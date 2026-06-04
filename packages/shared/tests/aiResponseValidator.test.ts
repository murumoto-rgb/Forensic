/**
 * Snapshot parity tests for `validateAIResponse` +
 * `resolveValidationVocabulary`. Mirror iOS's
 * `AIResponseValidator.validate(...)` checks so the same response
 * surfaces the same warnings on both platforms.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  resolveValidationVocabulary,
  validateAIResponse,
  isValidPrimary,
  isValidSecondary,
  repairUserPromptText,
  type ValidationVocabulary,
} from "../src/aiResponseValidator.js";
import type { AIPhotoAnalysis } from "../src/manifest.js";
import type { TagLibrary } from "../src/appConfig.js";

// ---------------------------------------------------------------------------
// Fixture vocabulary — small enough to read.
// ---------------------------------------------------------------------------

const ctxId = "11111111-1111-1111-1111-111111111111";
const primId = "33333333-3333-3333-3333-333333333333";
const secOkId = "66666666-6666-6666-6666-666666666666";
const secFlatId = "77777777-7777-7777-7777-777777777777";

const fixtureLibrary: TagLibrary = {
  seedVersion: 3,
  contexts: [
    {
      id: ctxId,
      name: "Foundation Performance Evaluation",
      primaries: [
        {
          id: primId,
          name: "Drainage / Grading",
          secondaries: [
            { id: secOkId, name: "Drainage visually away from foundation" },
            { id: secFlatId, name: "Marginal or flat drainage adjacent to foundation" },
          ],
        },
      ],
    },
  ],
};

const fixtureVocab: ValidationVocabulary = resolveValidationVocabulary({
  library: fixtureLibrary,
  selection: {
    contextIDs: [ctxId],
    primariesByContext: { [ctxId]: [primId] },
    deselectedSecondariesByPrimary: {},
  },
});

function base(overrides: Partial<AIPhotoAnalysis>): AIPhotoAnalysis {
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

describe("resolveValidationVocabulary", () => {
  it("builds the vocabulary from library + selection (lowercased)", () => {
    assert.ok(isValidPrimary(fixtureVocab, "Drainage / Grading"));
    assert.ok(isValidPrimary(fixtureVocab, "drainage / grading"));
    assert.ok(
      isValidSecondary(
        fixtureVocab,
        "Drainage visually away from foundation",
        "Drainage / Grading"
      )
    );
    assert.ok(isValidSecondary(fixtureVocab, "None", "Drainage / Grading"));
    assert.ok(!isValidPrimary(fixtureVocab, "Bogus Primary"));
  });

  it("respects deselected secondaries", () => {
    const vocab = resolveValidationVocabulary({
      library: fixtureLibrary,
      selection: {
        contextIDs: [ctxId],
        primariesByContext: { [ctxId]: [primId] },
        deselectedSecondariesByPrimary: { [primId]: [secOkId] },
      },
    });
    assert.ok(
      !isValidSecondary(
        vocab,
        "Drainage visually away from foundation",
        "Drainage / Grading"
      )
    );
    assert.ok(
      isValidSecondary(
        vocab,
        "Marginal or flat drainage adjacent to foundation",
        "Drainage / Grading"
      )
    );
  });

  it("merges extras into the same primary's secondaries", () => {
    const vocab = resolveValidationVocabulary({
      library: fixtureLibrary,
      selection: {
        contextIDs: [ctxId],
        primariesByContext: { [ctxId]: [primId] },
        deselectedSecondariesByPrimary: {},
      },
      extras: {
        primaries: [
          {
            name: "Drainage / Grading",
            secondaries: [{ name: "Custom extra observation" }],
          },
        ] as unknown as Array<Record<string, unknown>>,
      },
    });
    assert.ok(
      isValidSecondary(vocab, "Custom extra observation", "Drainage / Grading")
    );
  });
});

describe("validateAIResponse — vocabulary checks", () => {
  it("clean response: no errors", () => {
    const errors = validateAIResponse({
      analysis: base({
        primaryTags: ["Drainage / Grading"],
        secondaryTagsByPrimary: {
          "Drainage / Grading": ["Drainage visually away from foundation"],
        },
        tagConfidences: { "drainage visually away from foundation": 0.82 },
      }),
      vocabulary: fixtureVocab,
    });
    assert.deepEqual(errors, []);
  });

  it("flags > 2 primaries", () => {
    const errors = validateAIResponse({
      analysis: base({ primaryTags: ["A", "B", "C"] }),
      vocabulary: fixtureVocab,
    });
    assert.ok(errors.some((e) => e.includes("max 2")));
  });

  it("flags unknown primaries", () => {
    const errors = validateAIResponse({
      analysis: base({ primaryTags: ["Bogus Primary"] }),
      vocabulary: fixtureVocab,
    });
    assert.ok(errors.some((e) => e.includes('Unknown primary tag: "Bogus Primary"')));
  });

  it("flags missing secondary_tags_by_primary entry", () => {
    const errors = validateAIResponse({
      analysis: base({
        primaryTags: ["Drainage / Grading"],
        secondaryTagsByPrimary: {},
      }),
      vocabulary: fixtureVocab,
    });
    assert.ok(errors.some((e) => e.includes("Missing secondary_tags_by_primary entry")));
  });

  it("flags empty secondaries array (must use ['None'])", () => {
    const errors = validateAIResponse({
      analysis: base({
        primaryTags: ["Drainage / Grading"],
        secondaryTagsByPrimary: { "Drainage / Grading": [] },
      }),
      vocabulary: fixtureVocab,
    });
    assert.ok(errors.some((e) => e.includes("is empty (use [")));
  });

  it("flags secondary not under the chosen primary", () => {
    const errors = validateAIResponse({
      analysis: base({
        primaryTags: ["Drainage / Grading"],
        secondaryTagsByPrimary: {
          "Drainage / Grading": ["Off-vocabulary phrase"],
        },
      }),
      vocabulary: fixtureVocab,
    });
    assert.ok(
      errors.some(
        (e) =>
          e ===
          'Secondary "Off-vocabulary phrase" is not listed under primary "Drainage / Grading".'
      )
    );
  });

  it("accepts the universal 'None' sentinel under any primary", () => {
    const errors = validateAIResponse({
      analysis: base({
        primaryTags: ["Drainage / Grading"],
        secondaryTagsByPrimary: { "Drainage / Grading": ["None"] },
      }),
      vocabulary: fixtureVocab,
    });
    assert.deepEqual(errors, []);
  });
});

describe("validateAIResponse — constrained enums", () => {
  it("accepts a known scalePresent value (case-insensitive + legacy 'partial')", () => {
    for (const v of ["Yes", "yes", "Relative", "partial", "No"]) {
      const errors = validateAIResponse({
        analysis: base({ scalePresent: v }),
        vocabulary: fixtureVocab,
      });
      assert.ok(
        !errors.some((e) => e.includes("scale_present")),
        `Expected ${v} to validate`
      );
    }
  });

  it("flags an unknown scalePresent value", () => {
    const errors = validateAIResponse({
      analysis: base({ scalePresent: "Maybe" }),
      vocabulary: fixtureVocab,
    });
    assert.ok(errors.some((e) => e.includes("scale_present has unknown value")));
  });

  it("accepts known recommendedUse values + spelling variants", () => {
    for (const v of [
      "Body figure",
      "Appendix only",
      "Context/locator",
      "Context / locator",
      "Re-shoot recommended",
      "Reshoot recommended",
    ]) {
      const errors = validateAIResponse({
        analysis: base({ recommendedUse: v }),
        vocabulary: fixtureVocab,
      });
      assert.ok(
        !errors.some((e) => e.includes("recommended_use")),
        `Expected ${v} to validate`
      );
    }
  });

  it("flags an unknown recommendedUse value", () => {
    const errors = validateAIResponse({
      analysis: base({ recommendedUse: "Optional Bonus Figure" }),
      vocabulary: fixtureVocab,
    });
    assert.ok(errors.some((e) => e.includes("recommended_use has unknown value")));
  });
});

describe("validateAIResponse — observation phrasing", () => {
  it("flags causation phrases", () => {
    for (const phrase of ["caused by", "due to", "because of"]) {
      const errors = validateAIResponse({
        analysis: base({
          summaryObservation: `Cracks are ${phrase} settlement.`,
        }),
        vocabulary: fixtureVocab,
      });
      assert.ok(
        errors.some((e) => e.includes(phrase)),
        `Expected to flag "${phrase}"`
      );
    }
  });

  it("doesn't flag observation when phrasing is cautious", () => {
    const errors = validateAIResponse({
      analysis: base({
        summaryObservation: "Cracks visible along the base.",
      }),
      vocabulary: fixtureVocab,
    });
    assert.equal(errors.length, 0);
  });
});

describe("validateAIResponse — tag confidences", () => {
  it("flags out-of-range confidence values", () => {
    const errors = validateAIResponse({
      analysis: base({
        primaryTags: ["Drainage / Grading"],
        secondaryTagsByPrimary: {
          "Drainage / Grading": ["Drainage visually away from foundation"],
        },
        tagConfidences: { "drainage visually away from foundation": 1.5 },
      }),
      vocabulary: fixtureVocab,
    });
    assert.ok(errors.some((e) => e.includes("out of range")));
  });

  it("flags missing confidence for a non-None secondary", () => {
    const errors = validateAIResponse({
      analysis: base({
        primaryTags: ["Drainage / Grading"],
        secondaryTagsByPrimary: {
          "Drainage / Grading": ["Drainage visually away from foundation"],
        },
        tagConfidences: {},
      }),
      vocabulary: fixtureVocab,
    });
    assert.ok(
      errors.some((e) =>
        e.includes(
          'tag_confidences missing entry for secondary "Drainage visually away from foundation"'
        )
      )
    );
  });

  it("doesn't require a confidence for the 'None' sentinel", () => {
    const errors = validateAIResponse({
      analysis: base({
        primaryTags: ["Drainage / Grading"],
        secondaryTagsByPrimary: { "Drainage / Grading": ["None"] },
      }),
      vocabulary: fixtureVocab,
    });
    assert.deepEqual(errors, []);
  });
});

describe("repairUserPromptText", () => {
  it("bullets the errors and includes the corrective instruction", () => {
    const text = repairUserPromptText([
      'Secondary "X" is not listed under primary "Y".',
      "Another issue.",
    ]);
    assert.ok(text.includes('- Secondary "X" is not listed under primary "Y".'));
    assert.ok(text.includes("- Another issue."));
    assert.ok(text.includes("Re-emit the JSON object for this photo"));
    assert.ok(text.includes("Return ONLY the corrected JSON object"));
  });
});
