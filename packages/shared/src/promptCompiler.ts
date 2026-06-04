/**
 * Composes Claude's system prompt for AI tagging from the app-wide
 * rules template + tag library and the project's chosen vocabulary
 * subset. Pure function — no I/O, no side effects.
 *
 * MUST stay byte-for-byte equivalent to the iOS Swift implementation
 * in `ios/SitePhoto/Models/PromptCompiler.swift`. Both platforms emit
 * the same system prompt for a given (rulesTemplate, tagLibrary,
 * project) triple so re-tagging produces consistent results
 * regardless of which platform initiated it. A snapshot-based parity
 * test (`tests/promptCompiler.parity.test.ts`) guards this — keep
 * the two implementations in lockstep when either changes.
 *
 * The web "Re-tag with AI" button uses this to assemble the system
 * prompt it sends to `POST /v1/ai/tag-photo`. The endpoint's
 * single-turn shape means the multi-block cache layout iOS uses is
 * collapsed here too: callers join `result.blocks.map(b => b.text)`
 * with `\n\n` before sending.
 */

import type {
  Project,
  ProjectExtraVocabulary,
  ProjectTagSelection,
} from "./manifest.js";
import type { TagLibrary } from "./appConfig.js";

/** Short framing prepended to the rules template. */
const SYSTEM_PREAMBLE = `You are an AI assistant tagging forensic site-investigation photographs. The rules below describe the JSON schema you must emit. The controlled vocabulary below the rules is scoped to this specific project — use ONLY the investigation contexts, primary tags, and secondary tags listed there.

Vocabulary format: each entry is a fully-qualified \`Context::Primary::Secondary\` triple on its own line. Read every triple as one atomic choice — the Primary and Context travel with the Secondary as a single unit and must never be detached from it. None of the listed tags themselves contain the \`::\` sequence, so \`::\` is always a triple separator.`;

/** Short reinforcement appended after everything else. */
const OUTPUT_CONTRACT = `OUTPUT FORMAT (reinforces the rules above; do not contradict them):

Emit ONLY the single JSON object described above. No prose before or after, no markdown code fences, no commentary, no explanation. Start your response with \`{\` and end it with \`}\`.`;

/**
 * The error PromptCompiler throws when the project has no usable
 * vocabulary. Code matches the iOS `CompileError.noContextsPicked`
 * case; UI should translate to "Pick at least one investigation
 * context in AI Tags first."
 */
export class PromptCompileError extends Error {
  readonly code: "noContextsPicked";
  constructor() {
    super(
      "Pick at least one investigation context in AI Tags first. The AI needs project-scoped vocabulary to know which tags to consider."
    );
    this.name = "PromptCompileError";
    this.code = "noContextsPicked";
  }
}

/**
 * A single text section of the compiled system prompt. `cacheable`
 * mirrors the iOS-side flag used to drive Anthropic's
 * `cache_control: ephemeral` markers; web doesn't currently leverage
 * the cache (the proxy is single-turn) but we carry the flag for
 * future use and parity-symmetry.
 */
export interface PromptBlock {
  text: string;
  cacheable: boolean;
}

export interface PromptCompileResult {
  blocks: PromptBlock[];
  /** Convenience: every block's text joined with a blank line. This
   *  is what the `/v1/ai/tag-photo` proxy expects as `systemPrompt`. */
  joinedSystemPrompt: string;
}

/**
 * Build the system prompt for `project` against the app-wide
 * `rulesTemplate` + `tagLibrary`.
 *
 * Throws `PromptCompileError` when the project has no `tagSelection`
 * or the selection refers entirely to stale IDs (every picked
 * context was deleted from the library after the selection was
 * saved) — same error the iOS path raises so the UI message is
 * portable.
 */
export function compilePrompt(args: {
  rulesTemplate: string;
  tagLibrary: TagLibrary;
  project: Project;
}): PromptCompileResult {
  const { rulesTemplate, tagLibrary, project } = args;
  const selection = project.tagSelection;
  if (!selection || isSelectionEmpty(selection)) {
    throw new PromptCompileError();
  }

  const vocabularyBlock = compileVocabularyBlock(tagLibrary, selection);
  // Empty vocabulary block means every picked context was empty /
  // stale. Same treatment as no contexts picked at all.
  if (vocabularyBlock.trim().length === 0) {
    throw new PromptCompileError();
  }

  const rules = rulesTemplate.trim();
  const extrasBlock = compileExtraVocabularyBlock(project.aiExtraVocabulary);
  const notesBlock = compileNotesBlock(project.aiInstructions);

  // Block layout — see iOS PromptCompiler docs for the cache-layout
  // rationale. The first block bundles preamble + rules so a small
  // change to either doesn't cost an extra cache slot.
  const blocks: PromptBlock[] = [
    { text: `${SYSTEM_PREAMBLE}\n\n${rules}`, cacheable: true },
    { text: vocabularyBlock, cacheable: true },
  ];
  if (extrasBlock !== null) blocks.push({ text: extrasBlock, cacheable: true });
  if (notesBlock !== null) blocks.push({ text: notesBlock, cacheable: true });
  blocks.push({ text: OUTPUT_CONTRACT, cacheable: false });

  return {
    blocks,
    joinedSystemPrompt: blocks.map((b) => b.text).join("\n\n"),
  };
}

/**
 * Per-photo user message accompanying the image content block. iOS
 * keeps this in its own `userPrompt` helper; we surface it here so
 * the web client doesn't have to duplicate the text.
 */
export function compileUserPrompt(photoID: string): string {
  const trimmed = photoID.trim();
  const idLine =
    trimmed.length === 0
      ? ""
      : `The photo_id for this image is "${trimmed}". Use that exact value in the JSON.\n\n`;
  return (
    idLine +
    "Analyse this site photo using the schema and rules in the system message above. Return only the JSON object — no prose, no code fences."
  );
}

// ---------------------------------------------------------------------------
// Internals — mirror the iOS Swift implementation exactly. Keep the
// branches in lockstep with the iOS source when either changes.
// ---------------------------------------------------------------------------

function isSelectionEmpty(selection: ProjectTagSelection): boolean {
  if (selection.contextIDs.length > 0) return false;
  if (Object.keys(selection.primariesByContext).length > 0) return false;
  if (Object.keys(selection.deselectedSecondariesByPrimary).length > 0)
    return false;
  return true;
}

function compileVocabularyBlock(
  library: TagLibrary,
  selection: ProjectTagSelection
): string {
  const lines: string[] = [
    "Controlled vocabulary for this project. Each line below is a complete Context::Primary::Secondary triple. Treat every triple as a single atomic choice — never detach a secondary from its primary or its context.",
  ];
  let emittedAtLeastOne = false;

  const contextById = new Map(library.contexts.map((c) => [c.id, c]));

  for (const contextID of selection.contextIDs) {
    const ctx = contextById.get(contextID);
    if (!ctx) continue;
    const pickedPrimaryIDs = new Set(
      selection.primariesByContext[contextID] ?? []
    );
    const pickedPrimaries = ctx.primaries.filter((p) =>
      pickedPrimaryIDs.has(p.id)
    );
    if (pickedPrimaries.length === 0) continue;

    for (const primary of pickedPrimaries) {
      const deselected = new Set(
        selection.deselectedSecondariesByPrimary[primary.id] ?? []
      );
      // Strip the legacy "none" sentinel here so v2-era libraries
      // that still carry it don't ship it to Claude. Case-insensitive
      // + trimmed to catch typo-renamed " none ".
      const activeSecondaries = primary.secondaries.filter((sec) => {
        if (deselected.has(sec.id)) return false;
        const n = sec.name.trim().toLowerCase();
        return n !== "none";
      });

      if (activeSecondaries.length === 0) {
        if (!emittedAtLeastOne) lines.push("");
        lines.push(`${ctx.name}::${primary.name}::(primary alone)`);
        emittedAtLeastOne = true;
      } else {
        if (!emittedAtLeastOne) lines.push("");
        for (const sec of activeSecondaries) {
          lines.push(`${ctx.name}::${primary.name}::${sec.name}`);
        }
        emittedAtLeastOne = true;
      }
    }
  }

  return emittedAtLeastOne ? lines.join("\n") : "";
}

function compileNotesBlock(notes: string | null): string | null {
  const trimmed = (notes ?? "").trim();
  if (trimmed.length === 0) return null;
  return `Additional notes for this project:\n${trimmed}`;
}

/**
 * Render the optional per-project extra vocabulary in the same
 * "INVESTIGATION CONTEXT … / Primary tag: … / Secondary tags: …"
 * shape iOS emits. Returns null when extras is missing or every
 * primary has been emptied — which would otherwise degrade to bare
 * headings the validator can't check against.
 */
function compileExtraVocabularyBlock(
  extras: ProjectExtraVocabulary | null
): string | null {
  if (!extras || extras.primaries.length === 0) return null;

  // ProjectExtraVocabulary is typed loosely in shared/manifest.ts
  // (`primaries: Array<Record<string, unknown>>`) because its
  // internal shape predates the parity-mirror story. Narrow at the
  // boundary here so the rest of this function can rely on the
  // shape.
  type ExtraPrimary = {
    name?: unknown;
    secondaries?: Array<{ name?: unknown }>;
  };
  const cleanPrimaries: { name: string; secondaries: { name: string }[] }[] = [];
  for (const raw of extras.primaries as unknown as ExtraPrimary[]) {
    const name = typeof raw.name === "string" ? raw.name.trim() : "";
    if (name.length === 0) continue;
    const secondaries: { name: string }[] = [];
    for (const s of raw.secondaries ?? []) {
      const sName = typeof s.name === "string" ? s.name.trim() : "";
      if (sName.length === 0) continue;
      if (sName.toLowerCase() === "none") continue;
      secondaries.push({ name: sName });
    }
    cleanPrimaries.push({ name, secondaries });
  }
  if (cleanPrimaries.length === 0) return null;

  const lines: string[] = [
    "Job-specific additions to the controlled vocabulary:",
    "",
    "INVESTIGATION CONTEXT: Job-Specific Additions",
  ];
  for (const primary of cleanPrimaries) {
    lines.push("");
    lines.push(`Primary tag: ${primary.name}`);
    if (primary.secondaries.length === 0) {
      lines.push(
        "Secondary tags: (no specific secondaries — tag the primary alone if visible)"
      );
    } else {
      lines.push(
        `Secondary tags: ${primary.secondaries.map((s) => s.name).join(", ")}`
      );
    }
  }
  return lines.join("\n");
}
