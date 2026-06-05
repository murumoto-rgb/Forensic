/**
 * Validates a decoded `AIPhotoAnalysis` against the project's
 * controlled vocabulary and the prompt's content rules. Returns
 * human-readable error strings — never throws, never mutates.
 *
 * Mirrors iOS's `AIResponseValidator.validate(...)` in
 * `ios/SitePhoto/Services/AIResponseValidator.swift`. Both
 * platforms feed the same `validationErrors` array onto the
 * persisted `AIPhotoAnalysis`, so a photo flagged by one device
 * surfaces the same warnings everywhere. Keep the two
 * implementations in lockstep when either changes.
 *
 * Web uses the validator output to drive the optional one-shot
 * repair-retry loop in `useReTagWithAI` (Build #5.43.1) — same
 * loop iOS runs in `ClaudeTaggingService.tag(...)` on vocabulary
 * rejections.
 */

import type {
  AIPhotoAnalysis,
  ProjectExtraVocabulary,
  ProjectTagSelection,
} from "./manifest.js";
import type { TagLibrary } from "./appConfig.js";

// ---------------------------------------------------------------------------
// ValidationVocabulary
// ---------------------------------------------------------------------------

/**
 * Per-project vocabulary the validator checks AI responses against.
 * Built from a `TagLibrary` + a `ProjectTagSelection` so the
 * validator accepts tags the engineer has added to the library or
 * to the per-project `aiExtraVocabulary` — without that indirection
 * a custom tag would be flagged as "unknown."
 *
 * Lookups are case-folded; canonical capitalisation is preserved
 * for presenting tags back to the user but the comparisons are
 * case-insensitive (Claude occasionally lowercases primaries).
 */
export interface ValidationVocabulary {
  /** Lowercased primary names. */
  primariesLowercased: Set<string>;
  /** For each lowercased primary, the lowercased set of allowed
   *  secondary names. The sentinel `"none"` is always allowed
   *  under every primary because the prompt explicitly tells
   *  Claude to use `["None"]` for contextual photos. */
  secondariesByPrimary: Map<string, Set<string>>;
}

/**
 * Resolve a `ValidationVocabulary` from the app-wide `tagLibrary` +
 * the project's `tagSelection`, optionally merging the per-project
 * `aiExtraVocabulary`. Returns an empty vocabulary when nothing's
 * picked — the call site should have caught that case earlier via
 * `compilePrompt`, but the fallback keeps the validator safe.
 *
 * Same merge discipline iOS uses: extras are flattened into the
 * same primaries / secondaries sets the library + selection
 * produces, because Claude sees a single flat vocabulary on the
 * wire and the validator can't (and doesn't need to) distinguish.
 */
export function resolveValidationVocabulary(args: {
  library: TagLibrary;
  selection: ProjectTagSelection;
  extras?: ProjectExtraVocabulary | null;
}): ValidationVocabulary {
  const { library, selection, extras } = args;
  const primaries = new Set<string>();
  const secondariesByPrimary = new Map<string, Set<string>>();

  const contextById = new Map(library.contexts.map((c) => [c.id, c]));
  for (const contextID of selection.contextIDs) {
    const ctx = contextById.get(contextID);
    if (!ctx) continue;
    const pickedPrimaryIDs = new Set(
      selection.primariesByContext[contextID] ?? []
    );
    for (const primary of ctx.primaries) {
      if (!pickedPrimaryIDs.has(primary.id)) continue;
      const key = primary.name.toLowerCase();
      primaries.add(key);
      const deselected = new Set(
        selection.deselectedSecondariesByPrimary[primary.id] ?? []
      );
      const secs = new Set<string>(["none"]);
      for (const s of primary.secondaries) {
        if (deselected.has(s.id)) continue;
        secs.add(s.name.toLowerCase());
      }
      secondariesByPrimary.set(key, secs);
    }
  }

  // Merge per-project extras.
  if (extras && extras.primaries.length > 0) {
    type ExtraPrimary = {
      name?: unknown;
      secondaries?: Array<{ name?: unknown }>;
    };
    for (const raw of extras.primaries as unknown as ExtraPrimary[]) {
      const name = typeof raw.name === "string" ? raw.name.trim() : "";
      if (name.length === 0) continue;
      const key = name.toLowerCase();
      primaries.add(key);
      const secs = secondariesByPrimary.get(key) ?? new Set<string>(["none"]);
      for (const s of raw.secondaries ?? []) {
        const sName = typeof s.name === "string" ? s.name.trim() : "";
        if (sName.length === 0) continue;
        secs.add(sName.toLowerCase());
      }
      secondariesByPrimary.set(key, secs);
    }
  }

  return { primariesLowercased: primaries, secondariesByPrimary };
}

export function isValidPrimary(
  vocab: ValidationVocabulary,
  name: string
): boolean {
  return vocab.primariesLowercased.has(name.toLowerCase());
}

export function isValidSecondary(
  vocab: ValidationVocabulary,
  name: string,
  primary: string
): boolean {
  const trimmed = name.trim().toLowerCase();
  if (trimmed === "none") return true;
  return vocab.secondariesByPrimary.get(primary.toLowerCase())?.has(trimmed) ?? false;
}

// ---------------------------------------------------------------------------
// Validator
// ---------------------------------------------------------------------------

/** Disallowed phrasings in `summaryObservation`. */
const CAUSATION_PHRASES = ["caused by", "due to", "because of"];

/**
 * Known `scalePresent` wire values (iOS Codable accepts these
 * case-insensitively). Anything else is "unknown" and the
 * validator surfaces it.
 *
 * iOS also accepts the legacy spelling "partial" as a synonym for
 * "Relative" — included here so older manifests still validate
 * clean.
 */
const KNOWN_SCALE_PRESENT = new Set([
  "yes",
  "relative",
  "partial",
  "no",
]);

/**
 * Known `recommendedUse` wire values. iOS's Codable accepts both
 * "Context/locator" and "Context / locator", and both
 * "Re-shoot recommended" and "Reshoot recommended" — mirror that
 * here so legacy responses validate clean.
 */
const KNOWN_RECOMMENDED_USE = new Set([
  "body figure",
  "appendix only",
  "context/locator",
  "context / locator",
  "re-shoot recommended",
  "reshoot recommended",
]);

/**
 * Run every check from the schema-2 spec against `analysis`.
 * Returns a list of human-facing error strings — empty when the
 * response validates clean.
 */
export function validateAIResponse(args: {
  analysis: AIPhotoAnalysis;
  vocabulary: ValidationVocabulary;
}): string[] {
  const { analysis: a, vocabulary } = args;
  const errors: string[] = [];

  // 1. Primary tag count must be 0, 1, or 2.
  if (a.primaryTags.length > 2) {
    errors.push(
      `primary_tags has ${a.primaryTags.length} entries (max 2).`
    );
  }

  // 2. Each primary must be in the project's scoped vocabulary.
  for (const primary of a.primaryTags) {
    if (!isValidPrimary(vocabulary, primary)) {
      errors.push(`Unknown primary tag: "${primary}".`);
    }
  }

  // 3. Every primary must have an entry in secondary_tags_by_primary
  //    AND every secondary must be listed under that primary (or
  //    the universal "None").
  for (const primary of a.primaryTags) {
    const matchingKey = Object.keys(a.secondaryTagsByPrimary).find(
      (k) => k.toLowerCase() === primary.toLowerCase()
    );
    if (!matchingKey) {
      errors.push(
        `Missing secondary_tags_by_primary entry for primary "${primary}".`
      );
      continue;
    }
    const secondaries = a.secondaryTagsByPrimary[matchingKey] ?? [];
    if (secondaries.length === 0) {
      errors.push(
        `secondary_tags_by_primary["${primary}"] is empty (use ["None"] if no distress).`
      );
      continue;
    }
    for (const sec of secondaries) {
      if (!isValidSecondary(vocabulary, sec, primary)) {
        errors.push(`Secondary "${sec}" is not listed under primary "${primary}".`);
      }
    }
  }

  // 4. Constrained enums must have decoded to a known case.
  if (a.scalePresent.length > 0) {
    const normalised = a.scalePresent.trim().toLowerCase();
    if (!KNOWN_SCALE_PRESENT.has(normalised)) {
      errors.push(
        `scale_present has unknown value "${a.scalePresent}" (expected Yes / Relative / No).`
      );
    }
  }
  if (a.recommendedUse.length > 0) {
    const normalised = a.recommendedUse.trim().toLowerCase();
    if (!KNOWN_RECOMMENDED_USE.has(normalised)) {
      errors.push(
        `recommended_use has unknown value "${a.recommendedUse}" (expected Body figure / Appendix only / Context/locator / Re-shoot recommended).`
      );
    }
  }

  // 5. summary_observation must not contain disallowed causation
  //    phrases.
  const obsLC = a.summaryObservation.toLowerCase();
  for (const phrase of CAUSATION_PHRASES) {
    if (obsLC.includes(phrase)) {
      errors.push(
        `summary_observation contains disallowed phrase "${phrase}" — use cautious language instead.`
      );
    }
  }

  // 6. tag_confidences sanity. Values must be in [0, 1], every
  //    non-"None" secondary should have an entry.
  const confKeysLC = new Set(
    Object.keys(a.tagConfidences).map((k) =>
      k.trim().toLowerCase()
    )
  );
  for (const [key, value] of Object.entries(a.tagConfidences)) {
    if (value < 0 || value > 1) {
      errors.push(
        `tag_confidences["${key}"] = ${value} is out of range (expected 0…1).`
      );
    }
  }
  for (const secondaries of Object.values(a.secondaryTagsByPrimary)) {
    for (const sec of secondaries) {
      const trimmed = sec.trim();
      if (trimmed.length === 0 || trimmed.toLowerCase() === "none") {
        continue;
      }
      if (!confKeysLC.has(trimmed.toLowerCase())) {
        errors.push(`tag_confidences missing entry for secondary "${sec}".`);
      }
    }
  }

  return errors;
}

/**
 * Compose the follow-up user message for the repair retry. The
 * validator's error strings are descriptive enough on their own
 * (e.g. `Secondary "Incomplete backfill" is not listed under
 * primary "Drainage / Grading".`); we just bullet them and tell
 * the model how to fix. Mirrors iOS's `repairUserPrompt(errors:)`.
 */
export function repairUserPromptText(errors: string[]): string {
  const bullets = errors.map((e) => `- ${e}`).join("\n");
  return `The previous response had vocabulary issues the validator flagged:
${bullets}

Re-emit the JSON object for this photo. For each problem secondary, either move it under the primary it actually appears under in the controlled vocabulary (which may mean adding that primary to your \`primary_tags\`), or replace it with a secondary that is listed under your chosen primary. Use the exact tag spellings from the controlled vocabulary in the system message.

Return ONLY the corrected JSON object — no prose, no code fences. Start with \`{\` and end with \`}\`.`;
}
