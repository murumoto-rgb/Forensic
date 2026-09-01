#!/usr/bin/env tsx
/**
 * Regenerates `packages/shared/fixtures/ios-models.json` by reading
 * the iOS Codable structs in `ios/SitePhoto/Models/`.
 *
 * This is a best-effort regex parser — it handles the shapes the
 * Forensic models actually use today. If it ever fails on a new
 * struct shape, fix the parser rather than hand-editing the JSON.
 *
 * Usage:  pnpm parity:regen-fixtures
 *
 * The output is checked into git. The parity contract test compares
 * the canonical TS / zod schemas against this JSON; if they drift,
 * CI fails.
 */

import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");
const IOS_MODELS_DIR = join(REPO_ROOT, "ios", "SitePhoto", "Models");
const OUTPUT_PATH = join(
  REPO_ROOT,
  "packages",
  "shared",
  "fixtures",
  "ios-models.json"
);

/**
 * The set of model + sub-model struct names that participate in the
 * manifest contract. Any other struct in the Models/ directory is
 * iOS-internal (e.g. UI state, transient services) and is not
 * mirrored on the TS side. Adding a new manifest model means adding
 * its name here.
 */
const MANIFEST_STRUCTS = new Set([
  "Project",
  "InspectionChecklistItem",
  "InspectionSession",
  "InspectionReportLayout",
  "InspectionPreset",
  "SearchFilter",
  "SavedSearch",
  "WorkflowLibrary",
  "Photo",
  "FloorPlan",
  "DistressMark",
  "ProjectGPS",
  "Bucket",
  "Tag",
  "TagSuggestion",
  "AIPhotoAnalysis",
  "ProjectTagSelection",
  "ProjectExtraVocabulary",
]);

const MANIFEST_ENUMS = new Set([
  "PositionSource",
  "FlashMode",
  "TagSource",
  "DistressKind",
]);

/** Strip Swift line and block comments so they don't confuse the regex. */
function stripComments(src: string): string {
  let out = src.replace(/\/\*[\s\S]*?\*\//g, "");
  out = out.replace(/(^|[^:])\/\/[^\n]*/g, "$1");
  return out;
}

interface StructRecord {
  source: string;
  fields: Record<string, string>;
}

interface ParsedIOS {
  structs: Record<string, StructRecord>;
  enums: Record<string, string[]>;
}

function parseFile(filePath: string, relPath: string, into: ParsedIOS): void {
  const raw = readFileSync(filePath, "utf8");
  const src = stripComments(raw);

  // Find every `struct Name: ... { ... }`. First occurrence wins —
  // if a name (e.g. `Bucket`) collides with a non-canonical helper
  // struct in another file, the canonical model file (alphabetically
  // earlier — `Bucket.swift` beats `ProjectStore.swift`) takes
  // precedence and the later definition is ignored.
  const structRe = /\b(?:public\s+|internal\s+|private\s+|fileprivate\s+)?struct\s+([A-Za-z_][A-Za-z0-9_]*)\b[^{]*\{/g;
  let m: RegExpExecArray | null;
  while ((m = structRe.exec(src)) !== null) {
    const name = m[1];
    const bodyStart = structRe.lastIndex;
    const body = readBraceBody(src, bodyStart);
    if (!name || !MANIFEST_STRUCTS.has(name)) continue;
    if (name in into.structs) continue; // first occurrence wins
    const fields = extractFields(body);
    into.structs[name] = { source: relPath, fields };
  }

  // Find every `enum Name: ... { ... }` and pull out case identifiers.
  // Same first-occurrence-wins rule as structs.
  const enumRe = /\b(?:public\s+|internal\s+|private\s+|fileprivate\s+)?enum\s+([A-Za-z_][A-Za-z0-9_]*)\b[^{]*\{/g;
  let em: RegExpExecArray | null;
  while ((em = enumRe.exec(src)) !== null) {
    const name = em[1];
    const bodyStart = enumRe.lastIndex;
    const body = readBraceBody(src, bodyStart);
    if (!name || !MANIFEST_ENUMS.has(name)) continue;
    if (name in into.enums) continue;
    into.enums[name] = extractEnumCases(body);
  }
}

/**
 * Reads the body of a `{ ... }` block starting at `from` (which points
 * just past the opening `{`). Returns the inner text. Brace-balanced.
 */
function readBraceBody(src: string, from: number): string {
  let depth = 1;
  let i = from;
  while (i < src.length && depth > 0) {
    const c = src[i];
    if (c === "{") depth++;
    else if (c === "}") depth--;
    if (depth === 0) return src.slice(from, i);
    i++;
  }
  return src.slice(from);
}

/**
 * Pull `var name: Type` and `let name: Type` declarations from a struct
 * body. We stop at the body of any nested function / initializer / enum
 * (those bodies introduce their own scoped vars that aren't Codable
 * fields). Computed properties (vars followed by a `{ ... }` body) and
 * static / private declarations are skipped.
 */
function extractFields(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  // Walk line-by-line at the top level only (depth 0 of the body's own
  // braces — we already consumed the outer struct braces).
  let depth = 0;
  let lineStart = 0;
  const lines: string[] = [];
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c === "{") depth++;
    else if (c === "}") depth--;
    if (c === "\n") {
      if (depth === 0) lines.push(body.slice(lineStart, i));
      lineStart = i + 1;
    }
  }
  if (depth === 0 && lineStart < body.length) lines.push(body.slice(lineStart));

  // Match patterns like:
  //   var foo: String
  //   var foo: String = "x"
  //   let foo: UUID
  //   var foo: [Tag] = []
  //   var foo: [String: [String]]
  //   var foo: String?
  //
  // Skip:
  //   • `static`, `private`, `fileprivate`, `class` modifiers — not
  //     part of the public Codable surface.
  //   • Computed properties: the type is followed by `{ … }` on the
  //     same line. We detect them by forbidding `{` inside the type
  //     capture. (Without this, the regex would slurp e.g.
  //     `Bool { startedAt != nil }` and produce garbage.)
  const fieldRe =
    /^\s*((?:[A-Za-z]+\s+)*)(var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^=\n{]+?)(?:\s*=\s*[^\n]+)?\s*$/;
  for (const rawLine of lines) {
    const trimmed = rawLine.trimEnd();
    const fm = trimmed.match(fieldRe);
    if (!fm) continue;
    const modifiers = (fm[1] || "").trim();
    const name = fm[3];
    const type = (fm[4] || "").trim();
    if (!name || !type) continue;
    if (/\b(static|private|fileprivate|class)\b/.test(modifiers)) continue;
    // Belt-and-suspenders — line shouldn't contain `{` at all
    // (computed property), and the type shouldn't have one either.
    if (trimmed.includes("{") || type.includes("{")) continue;
    out[name] = normalizeType(type);
  }
  return out;
}

/** Light cleanup so types match what we put in the fixture: collapse
 *  internal whitespace and trim a stray leading `var `/ `let `. */
function normalizeType(t: string): string {
  return t.replace(/\s+/g, " ").trim();
}

/**
 * Extract enum case raw values. Handles the patterns the manifest
 * enums use:  `case foo`, `case foo, bar`, `case foo = "x"`.
 *
 * Only walks the enum body at brace-depth 0 — switch statements
 * inside computed properties (`var displayName: String { switch self
 * { case .foo: … } }`) are at depth >= 1 and are skipped. Without
 * this guard, `case .foo:` lines inside switches would leak in.
 */
function extractEnumCases(body: string): string[] {
  const topLevel: string[] = [];
  let depth = 0;
  let lineStart = 0;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c === "{") depth++;
    else if (c === "}") depth--;
    if (c === "\n") {
      if (depth === 0) topLevel.push(body.slice(lineStart, i));
      lineStart = i + 1;
    }
  }
  if (depth === 0 && lineStart < body.length) {
    topLevel.push(body.slice(lineStart));
  }

  // Only match lines whose RHS is a valid case declaration — no
  // leading dot (which would indicate `case .foo:` inside a switch),
  // no `:` (which indicates a switch arm), no `return`/`->`/etc.
  const caseDeclRe =
    /^\s*case\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*=\s*"[^"]*")?(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*(?:\s*=\s*"[^"]*")?)*)\s*$/;
  const cases: string[] = [];
  for (const line of topLevel) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const m = trimmed.match(caseDeclRe);
    if (!m) continue;
    const rhs = m[1] || "";
    for (const part of rhs.split(",")) {
      const p = part.trim();
      if (!p) continue;
      const eqIdx = p.indexOf("=");
      if (eqIdx >= 0) {
        const rawVal = p.slice(eqIdx + 1).trim();
        cases.push(rawVal.replace(/^"|"$/g, ""));
      } else {
        cases.push(p);
      }
    }
  }
  return cases;
}

function main(): void {
  const entries = readdirSync(IOS_MODELS_DIR, { withFileTypes: true });
  const parsed: ParsedIOS = { structs: {}, enums: {} };

  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".swift")) continue;
    const filePath = join(IOS_MODELS_DIR, entry.name);
    const relPath = `ios/SitePhoto/Models/${entry.name}`;
    parseFile(filePath, relPath, parsed);
  }

  // Confirm we found every model + enum we expected.
  const missingStructs = [...MANIFEST_STRUCTS].filter(
    (s) => !(s in parsed.structs)
  );
  if (missingStructs.length > 0) {
    console.error(
      `regen-ios-fixtures: failed to find these manifest structs in ios/SitePhoto/Models/: ${missingStructs.join(", ")}.\n` +
        "If you renamed or moved a struct, update MANIFEST_STRUCTS in scripts/regen-ios-fixtures.ts and packages/shared/."
    );
    process.exit(1);
  }
  const missingEnums = [...MANIFEST_ENUMS].filter((e) => !(e in parsed.enums));
  if (missingEnums.length > 0) {
    console.error(
      `regen-ios-fixtures: failed to find these manifest enums: ${missingEnums.join(", ")}.`
    );
    process.exit(1);
  }

  // Read the existing fixture to preserve manifestSchemaVersion (the
  // parser doesn't know what version we're on; the human bumps it
  // explicitly).
  let manifestSchemaVersion = 1;
  try {
    const existing = JSON.parse(readFileSync(OUTPUT_PATH, "utf8"));
    if (typeof existing.manifestSchemaVersion === "number") {
      manifestSchemaVersion = existing.manifestSchemaVersion;
    }
  } catch {
    // First run — fall back to 1.
  }

  const out = {
    _generated_by:
      "scripts/regen-ios-fixtures.ts — do not edit by hand. Run `pnpm parity:regen-fixtures`.",
    manifestSchemaVersion,
    models: Object.fromEntries(
      [...MANIFEST_STRUCTS]
        .filter((n) => n in parsed.structs)
        .map((n) => [n, parsed.structs[n]])
    ),
    enums: Object.fromEntries(
      [...MANIFEST_ENUMS]
        .filter((n) => n in parsed.enums)
        .map((n) => [n, parsed.enums[n]])
    ),
  };

  writeFileSync(OUTPUT_PATH, JSON.stringify(out, null, 2) + "\n", "utf8");
  console.log(
    `regen-ios-fixtures: wrote ${OUTPUT_PATH} (${Object.keys(out.models).length} structs, ${Object.keys(out.enums).length} enums, schema v${manifestSchemaVersion})`
  );
}

main();
