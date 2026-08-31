/**
 * Snapshot-based parity test for `compilePrompt` + `compileUserPrompt`.
 *
 * The TypeScript port of iOS's `PromptCompiler.swift` must produce
 * byte-identical output to the Swift original — both platforms send
 * the same system prompt to Anthropic for a given `(rulesTemplate,
 * tagLibrary, project)` triple so re-tagging produces consistent
 * results regardless of which platform invoked the call.
 *
 * The expected strings below are checked into the test inline so a
 * reviewer can read what the prompt looks like without leaving the
 * source. To regenerate after a deliberate prompt change:
 *
 *   1. Build the iOS app on a Mac with the matching change.
 *   2. Run iOS's `PromptCompiler.compile(...)` with the same fixture
 *      (see "Fixture" section below) in a Playground or unit test.
 *   3. Paste each block's `text` into the corresponding template
 *      literal below.
 *   4. CI's parity contract test runs alongside this one; if either
 *      compiler is the odd one out, this test catches it.
 *
 * The fixture is constructed to exercise every branch of
 * `compilePrompt`:
 *   - Two contexts, only one fully selected (the other has a
 *     primary picked).
 *   - A primary whose secondaries are all deselected → emits the
 *     `(primary alone)` placeholder.
 *   - A primary with a literal "None" secondary that must be
 *     filtered (legacy-seed compatibility).
 *   - `aiInstructions` (notes block).
 *   - `aiExtraVocabulary` with one primary that has secondaries and
 *     one with none → exercises both extras-block branches.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  compilePrompt,
  compileUserPrompt,
  PromptCompileError,
} from "../src/promptCompiler.js";
import type { Project } from "../src/manifest.js";
import type { TagLibrary } from "../src/appConfig.js";

// ---------------------------------------------------------------------------
// Fixture — deliberately small so the test author can hold the whole
// prompt in their head. Every UUID has a human-readable name so the
// expected output below is grep-able by ID.
// ---------------------------------------------------------------------------

const ctxFoundationId = "11111111-1111-1111-1111-111111111111";
const ctxRoofingId = "22222222-2222-2222-2222-222222222222";

const primDrainageId = "33333333-3333-3333-3333-333333333333";
const primGradeBeamId = "44444444-4444-4444-4444-444444444444";
const primGuttersId = "55555555-5555-5555-5555-555555555555";

const secDrainageOkId = "66666666-6666-6666-6666-666666666666";
const secDrainageFlatId = "77777777-7777-7777-7777-777777777777";
const secDrainageDeselectedId = "88888888-8888-8888-8888-888888888888";
const secGradeBeamCrackId = "99999999-9999-9999-9999-999999999999";
const secGradeBeamLegacyNoneId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";

const fixtureTagLibrary: TagLibrary = {
  seedVersion: 3,
  contexts: [
    {
      id: ctxFoundationId,
      name: "Foundation Performance Evaluation",
      primaries: [
        {
          id: primDrainageId,
          name: "Drainage / Grading",
          secondaries: [
            { id: secDrainageOkId, name: "Drainage visually away from foundation" },
            {
              id: secDrainageFlatId,
              name: "Marginal or flat drainage adjacent to foundation",
            },
            { id: secDrainageDeselectedId, name: "Standing water" },
          ],
        },
        {
          id: primGradeBeamId,
          name: "Foundation / Grade Beam",
          secondaries: [
            { id: secGradeBeamCrackId, name: "Grade beam crack" },
            // Legacy v2-era sentinel that must be filtered out.
            { id: secGradeBeamLegacyNoneId, name: "None" },
          ],
        },
      ],
    },
    {
      id: ctxRoofingId,
      name: "Roofing",
      primaries: [
        {
          id: primGuttersId,
          name: "Gutters",
          // No secondaries on this primary at all — exercises the
          // "(primary alone)" placeholder branch.
          secondaries: [],
        },
      ],
    },
  ],
};

const fixtureProject: Project = {
  id: "deadbeef-dead-beef-dead-beefdeadbeef",
  name: "Snapshot fixture",
  createdAt: "2026-01-01T00:00:00Z",
  startedAt: null,
  lastResumedAt: null,
  lastStoppedAt: null,
  stopped: false,
  isDeleted: false,
  isFrozen: false,
  projectGPS: null,
  projectAddress: null,
  photos: [],
  trashedPhotos: [],
  floorPlans: [],
  activeFloorPlanID: null,
  folderName: null,
  // Whitespace around the notes is intentional — the compiler trims
  // before emission; if it stops trimming, this test catches it.
  aiInstructions: "  Watch for slab cracks near the chimney.  ",
  buckets: [],
  tagSelection: {
    contextIDs: [ctxFoundationId, ctxRoofingId],
    primariesByContext: {
      [ctxFoundationId]: [primDrainageId, primGradeBeamId],
      [ctxRoofingId]: [primGuttersId],
    },
    // Deselect "Standing water" under Drainage to exercise the
    // selection.deselectedSecondariesByPrimary filter.
    deselectedSecondariesByPrimary: {
      [primDrainageId]: [secDrainageDeselectedId],
    },
  },
  aiExtraVocabulary: {
    primaries: [
      // First extras primary: has real secondaries.
      {
        name: "Project-specific addition A",
        secondaries: [{ name: "Detail 1" }, { name: "Detail 2" }],
      },
      // Second extras primary: every secondary is empty or "none"
      // sentinel → exercises the "(no specific secondaries — ...)"
      // fallback line.
      {
        name: "Project-specific addition B",
        secondaries: [{ name: "" }, { name: "None" }],
      },
    ] as unknown as NonNullable<Project["aiExtraVocabulary"]>["primaries"],
  },
  inspectionChecklist: [], inspectionSessions: [], reportLayout: null,
  manifestSchemaVersion: 2,
};

const fixtureRulesTemplate = `Rules go here. The schema requires a JSON object with photo_id, primary_tags, secondary_tags_by_primary, and so on.`;

// ---------------------------------------------------------------------------
// Expected output strings. Edit these (and the iOS source) together
// if you're changing the prompt format. The fixture above is held
// constant — only edit it when adding a new branch coverage case.
// ---------------------------------------------------------------------------

const EXPECTED_PREAMBLE_AND_RULES = `You are an AI assistant tagging forensic site-investigation photographs. The rules below describe the JSON schema you must emit. The controlled vocabulary below the rules is scoped to this specific project — use ONLY the investigation contexts, primary tags, and secondary tags listed there.

Vocabulary format: each entry is a fully-qualified \`Context::Primary::Secondary\` triple on its own line. Read every triple as one atomic choice — the Primary and Context travel with the Secondary as a single unit and must never be detached from it. None of the listed tags themselves contain the \`::\` sequence, so \`::\` is always a triple separator.

Rules go here. The schema requires a JSON object with photo_id, primary_tags, secondary_tags_by_primary, and so on.`;

const EXPECTED_VOCABULARY = `Controlled vocabulary for this project. Each line below is a complete Context::Primary::Secondary triple. Treat every triple as a single atomic choice — never detach a secondary from its primary or its context.

Foundation Performance Evaluation::Drainage / Grading::Drainage visually away from foundation
Foundation Performance Evaluation::Drainage / Grading::Marginal or flat drainage adjacent to foundation
Foundation Performance Evaluation::Foundation / Grade Beam::Grade beam crack
Roofing::Gutters::(primary alone)`;

const EXPECTED_EXTRAS = `Job-specific additions to the controlled vocabulary:

INVESTIGATION CONTEXT: Job-Specific Additions

Primary tag: Project-specific addition A
Secondary tags: Detail 1, Detail 2

Primary tag: Project-specific addition B
Secondary tags: (no specific secondaries — tag the primary alone if visible)`;

const EXPECTED_NOTES = `Additional notes for this project:
Watch for slab cracks near the chimney.`;

const EXPECTED_OUTPUT_CONTRACT = `OUTPUT FORMAT (reinforces the rules above; do not contradict them):

Emit ONLY the single JSON object described above. No prose before or after, no markdown code fences, no commentary, no explanation. Start your response with \`{\` and end it with \`}\`.`;

const EXPECTED_JOINED = [
  EXPECTED_PREAMBLE_AND_RULES,
  EXPECTED_VOCABULARY,
  EXPECTED_EXTRAS,
  EXPECTED_NOTES,
  EXPECTED_OUTPUT_CONTRACT,
].join("\n\n");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("compilePrompt — snapshot parity with iOS", () => {
  it("emits the expected five blocks in order with correct cacheable flags", () => {
    const result = compilePrompt({
      rulesTemplate: fixtureRulesTemplate,
      tagLibrary: fixtureTagLibrary,
      project: fixtureProject,
    });

    assert.equal(result.blocks.length, 5, "expected five blocks");
    assert.equal(result.blocks[0]?.text, EXPECTED_PREAMBLE_AND_RULES);
    assert.equal(result.blocks[0]?.cacheable, true);
    assert.equal(result.blocks[1]?.text, EXPECTED_VOCABULARY);
    assert.equal(result.blocks[1]?.cacheable, true);
    assert.equal(result.blocks[2]?.text, EXPECTED_EXTRAS);
    assert.equal(result.blocks[2]?.cacheable, true);
    assert.equal(result.blocks[3]?.text, EXPECTED_NOTES);
    assert.equal(result.blocks[3]?.cacheable, true);
    assert.equal(result.blocks[4]?.text, EXPECTED_OUTPUT_CONTRACT);
    assert.equal(result.blocks[4]?.cacheable, false);
  });

  it("joinedSystemPrompt concatenates blocks with one blank line", () => {
    const result = compilePrompt({
      rulesTemplate: fixtureRulesTemplate,
      tagLibrary: fixtureTagLibrary,
      project: fixtureProject,
    });
    assert.equal(result.joinedSystemPrompt, EXPECTED_JOINED);
  });

  it("throws PromptCompileError when the project has no tag selection", () => {
    const noSelectionProject: Project = {
      ...fixtureProject,
      tagSelection: null,
    };
    assert.throws(
      () =>
        compilePrompt({
          rulesTemplate: fixtureRulesTemplate,
          tagLibrary: fixtureTagLibrary,
          project: noSelectionProject,
        }),
      (err: unknown) =>
        err instanceof PromptCompileError && err.code === "noContextsPicked"
    );
  });

  it("throws PromptCompileError when every selected context is stale", () => {
    const staleProject: Project = {
      ...fixtureProject,
      tagSelection: {
        contextIDs: ["00000000-0000-0000-0000-000000000000"],
        primariesByContext: {},
        deselectedSecondariesByPrimary: {},
      },
    };
    assert.throws(
      () =>
        compilePrompt({
          rulesTemplate: fixtureRulesTemplate,
          tagLibrary: fixtureTagLibrary,
          project: staleProject,
        }),
      (err: unknown) =>
        err instanceof PromptCompileError && err.code === "noContextsPicked"
    );
  });

  it("omits the notes block when aiInstructions is missing or blank", () => {
    const noNotes: Project = { ...fixtureProject, aiInstructions: "   " };
    const result = compilePrompt({
      rulesTemplate: fixtureRulesTemplate,
      tagLibrary: fixtureTagLibrary,
      project: noNotes,
    });
    // Notes was the 4th block; with it absent, length drops to 4 and
    // the last block is the output contract.
    assert.equal(result.blocks.length, 4);
    assert.equal(result.blocks[result.blocks.length - 1]?.text, EXPECTED_OUTPUT_CONTRACT);
  });

  it("omits the extras block when aiExtraVocabulary is null", () => {
    const noExtras: Project = { ...fixtureProject, aiExtraVocabulary: null };
    const result = compilePrompt({
      rulesTemplate: fixtureRulesTemplate,
      tagLibrary: fixtureTagLibrary,
      project: noExtras,
    });
    // Extras was the 3rd block; with it absent, length drops to 4.
    assert.equal(result.blocks.length, 4);
    // Order is now [preamble+rules, vocab, notes, outputContract].
    assert.equal(result.blocks[2]?.text, EXPECTED_NOTES);
    assert.equal(result.blocks[3]?.text, EXPECTED_OUTPUT_CONTRACT);
  });
});

describe("compileUserPrompt", () => {
  it("includes the photo_id line when an ID is provided", () => {
    const expected =
      `The photo_id for this image is "abc.jpg". Use that exact value in the JSON.\n\n` +
      `Analyse this site photo using the schema and rules in the system message above. Return only the JSON object — no prose, no code fences.`;
    assert.equal(compileUserPrompt("abc.jpg"), expected);
  });

  it("omits the photo_id line when ID is empty or whitespace", () => {
    const expected =
      `Analyse this site photo using the schema and rules in the system message above. Return only the JSON object — no prose, no code fences.`;
    assert.equal(compileUserPrompt(""), expected);
    assert.equal(compileUserPrompt("   "), expected);
  });
});
