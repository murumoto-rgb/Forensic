/**
 * iOS ↔ shared TS parity contract test.
 *
 * Runs in CI on every PR. Fails if:
 *   • An iOS struct field has no matching field on the TS zod schema.
 *   • A TS zod schema has a field that doesn't exist on the iOS struct.
 *   • The field types don't agree (e.g. iOS `Date?` vs TS `string`
 *     without nullable).
 *   • An iOS enum has cases not in the TS literal union (or vice versa).
 *   • A manifest model is in the iOS fixture but has no zod schema in
 *     `src/validation.ts`, or vice versa.
 *
 * The iOS side is read from a checked-in fixture
 * (`fixtures/ios-models.json`), regenerated from iOS source by
 * `scripts/regen-ios-fixtures.ts`. The TS side is reflected from the
 * zod schemas at runtime — zod's `_def` carries the structural info we
 * need.
 *
 * When this test fails, the failure message tells you exactly which
 * field on which model is out of sync; fix it on whichever side hasn't
 * been updated yet.
 */

import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z, type ZodTypeAny } from "zod";
import * as schemas from "../src/validation.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = resolve(__dirname, "..", "fixtures", "ios-models.json");

interface Fixture {
  manifestSchemaVersion: number;
  models: Record<string, { source: string; fields: Record<string, string> }>;
  enums: Record<string, string[]>;
}

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, "utf8")) as Fixture;

/**
 * Swift type names that are not manifest models — they're TagLibrary
 * internals or other opaque records. Both sides treat them as an
 * opaque `record<string, unknown>` for round-tripping purposes.
 *
 * If you promote one of these to a real manifest model later, remove
 * it from this set, add it to `MANIFEST_STRUCTS` in the regen script
 * and the shared package, and define matching TS / zod / Swift
 * representations.
 */
const OPAQUE_SWIFT_TYPES = new Set([
  "PrimaryTagEntry",
  "SecondaryTagEntry",
]);

/**
 * Swift types whose default Codable encoding produces JSON arrays
 * rather than JSON objects. We let the wire shape stay loose
 * (`unknown` on both sides) for these; consumers (web, server) do
 * any structural interpretation themselves.
 *
 * CGPoint encodes as `[x, y]` per Apple's default Codable, which
 * means the distress `points` arrays serialize as arrays-of-arrays.
 * Both the TS type and the zod schema reflect this as `unknown[]`.
 */
const OPAQUE_AS_UNKNOWN = new Set([
  "CGPoint",
]);

/**
 * Build a lookup from zod schema reference → its exported name (with
 * the conventional `Schema` suffix stripped). This lets us, when
 * we see a child ZodObject inside another schema, recognize it as
 * "Photo" rather than collapsing it to a generic "object".
 */
const namedSchemas: Record<string, ZodTypeAny> = {};
const nameByRef = new Map<ZodTypeAny, string>();
for (const [exportName, value] of Object.entries(schemas)) {
  if (!exportName.endsWith("Schema")) continue;
  const baseName = exportName.replace(/Schema$/, "");
  namedSchemas[baseName] = value as ZodTypeAny;
  nameByRef.set(value as ZodTypeAny, baseName);
}

// ---------------------------------------------------------------------------
// Type-descriptor normalization
// ---------------------------------------------------------------------------

/**
 * Reduce both Swift and TS-zod types to the same normalized
 * descriptor language so we can compare them as strings.
 *
 *   string, number, boolean, unknown
 *   nullable<X>
 *   array<X>
 *   record<X, Y>
 *   enum<a|b|c>
 *   <NamedType>           (Project, Photo, …)
 */

function normalizeSwiftType(swift: string): string {
  let t = swift.trim();
  // Trailing `?` → nullable<>. Operate on the *outermost* `?` only.
  if (t.endsWith("?")) {
    const inner = t.slice(0, -1).trim();
    return `nullable<${normalizeSwiftType(inner)}>`;
  }
  // Array: `[T]`
  if (t.startsWith("[") && t.endsWith("]") && !t.includes(":")) {
    const inner = t.slice(1, -1).trim();
    return `array<${normalizeSwiftType(inner)}>`;
  }
  // Dictionary: `[K: V]`. Split on the topmost colon (not nested
  // inside another `[ ]`).
  if (t.startsWith("[") && t.endsWith("]") && t.includes(":")) {
    const inner = t.slice(1, -1);
    const colonIdx = topLevelColonIndex(inner);
    if (colonIdx >= 0) {
      const k = inner.slice(0, colonIdx).trim();
      const v = inner.slice(colonIdx + 1).trim();
      return `record<${normalizeSwiftType(k)}, ${normalizeSwiftType(v)}>`;
    }
  }
  // Set<T> serializes as array<T> on the wire.
  const setMatch = t.match(/^Set<(.+)>$/);
  if (setMatch && setMatch[1] !== undefined) {
    return `array<${normalizeSwiftType(setMatch[1].trim())}>`;
  }
  // Primitives.
  switch (t) {
    case "String":
    case "UUID":
    case "Date":
      return "string";
    case "Int":
    case "Double":
    case "Float":
    case "CGFloat":
      return "number";
    case "Bool":
      return "boolean";
  }
  // Opaque types — substitute a record<string, unknown> on both sides.
  if (OPAQUE_SWIFT_TYPES.has(t)) {
    return "record<string, unknown>";
  }
  // Opaque types whose wire shape is itself an array (CGPoint's
  // `[x, y]`). Both the zod side and Swift side land on `unknown`.
  if (OPAQUE_AS_UNKNOWN.has(t)) {
    return "unknown";
  }
  // Otherwise: a named manifest type (Project, Photo, Tag, …) or a
  // named enum (PositionSource, FlashMode, …). Pass through verbatim;
  // the comparison expects the same name on the TS side.
  return t;
}

function topLevelColonIndex(s: string): number {
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "[" || c === "<") depth++;
    else if (c === "]" || c === ">") depth--;
    else if (c === ":" && depth === 0) return i;
  }
  return -1;
}

function normalizeZodType(schema: ZodTypeAny): string {
  // If this schema is a named export (e.g. PhotoSchema), short-circuit
  // to the model name. Enums get the same treatment so they compare
  // to their Swift enum name.
  const named = nameByRef.get(schema);
  if (named) return named;

  const def: any = (schema as any)._def;
  const typeName: string = def?.typeName;
  switch (typeName) {
    case "ZodString":
      return "string";
    case "ZodNumber":
      return "number";
    case "ZodBoolean":
      return "boolean";
    case "ZodUnknown":
    case "ZodAny":
      return "unknown";
    case "ZodEffects":
      // `.transform()` / `.preprocess()` wrap the actual schema in
      // ZodEffects. The descriptor is whatever the inner schema is.
      return normalizeZodType(def.schema);
    case "ZodNullable": {
      const inner = normalizeZodType(def.innerType);
      // Already-nullable inner means `nullable(nullable(X))` — collapse.
      return inner.startsWith("nullable<") ? inner : `nullable<${inner}>`;
    }
    case "ZodOptional": {
      // Optional collapses to the same descriptor as nullable — both
      // represent "may be missing" on the wire. Nested
      // `optional(nullable(X))` (from our `nullable()` helper in
      // validation.ts) collapses to a single `nullable<X>`.
      const inner = normalizeZodType(def.innerType);
      return inner.startsWith("nullable<") ? inner : `nullable<${inner}>`;
    }
    case "ZodArray":
      return `array<${normalizeZodType(def.type)}>`;
    case "ZodRecord":
      return `record<${normalizeZodType(def.keyType)}, ${normalizeZodType(def.valueType)}>`;
    case "ZodEnum":
      return `enum<${(def.values as string[]).join("|")}>`;
    case "ZodObject":
      return "object";
    default:
      return typeName ?? "<unknown>";
  }
}

function zodObjectShape(schema: ZodTypeAny): Record<string, ZodTypeAny> {
  const def: any = (schema as any)._def;
  if (def.typeName !== "ZodObject") {
    throw new Error(`expected ZodObject, got ${def?.typeName}`);
  }
  const shape = typeof def.shape === "function" ? def.shape() : def.shape;
  return shape as Record<string, ZodTypeAny>;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("iOS ↔ shared TS parity contract", () => {
  it("manifestSchemaVersion in fixture matches the constant in manifest.ts", async () => {
    const { MANIFEST_SCHEMA_VERSION } = await import("../src/manifest.ts");
    assert.equal(
      fixture.manifestSchemaVersion,
      MANIFEST_SCHEMA_VERSION,
      `Fixture says v${fixture.manifestSchemaVersion} but manifest.ts says v${MANIFEST_SCHEMA_VERSION}. ` +
        "These must agree — bump them together in the same PR."
    );
  });

  it("every iOS manifest struct has a zod schema (and vice versa)", () => {
    const iosModelNames = new Set(Object.keys(fixture.models));
    const tsSchemaNames = new Set(Object.keys(namedSchemas));

    // Enums live in the fixture's "enums" map; they're also exported
    // as `…Schema` (e.g. PositionSourceSchema). Filter them out of
    // the struct comparison.
    const enumNames = new Set(Object.keys(fixture.enums));
    const tsStructNames = new Set(
      [...tsSchemaNames].filter((n) => !enumNames.has(n))
    );
    // Trim ScalePresent/RecommendedUse since those are constrained
    // strings on the wire, not real structs.
    tsStructNames.delete("ScalePresent");
    tsStructNames.delete("RecommendedUse");

    const missingOnTS = [...iosModelNames].filter((n) => !tsStructNames.has(n));
    const orphanOnTS = [...tsStructNames].filter((n) => !iosModelNames.has(n));

    assert.deepEqual(
      { missingOnTS, orphanOnTS },
      { missingOnTS: [], orphanOnTS: [] },
      "iOS / TS struct sets diverged. " +
        (missingOnTS.length > 0
          ? `Missing zod schema for iOS struct(s): ${missingOnTS.join(", ")}. `
          : "") +
        (orphanOnTS.length > 0
          ? `Orphan TS schema with no iOS counterpart: ${orphanOnTS.join(", ")}.`
          : "")
    );
  });

  it("every iOS manifest enum has a matching zod enum with the same cases", () => {
    for (const [enumName, iosCases] of Object.entries(fixture.enums)) {
      const schema = namedSchemas[enumName];
      assert.ok(
        schema,
        `iOS enum ${enumName} has no zod export named ${enumName}Schema in validation.ts`
      );
      const def: any = (schema as any)._def;
      assert.equal(
        def.typeName,
        "ZodEnum",
        `${enumName}Schema is ${def?.typeName}, expected ZodEnum`
      );
      const tsCases = new Set(def.values as string[]);
      const iosCaseSet = new Set(iosCases);
      const onlyInIOS = [...iosCaseSet].filter((c) => !tsCases.has(c));
      const onlyInTS = [...tsCases].filter((c) => !iosCaseSet.has(c));
      assert.deepEqual(
        { onlyInIOS, onlyInTS },
        { onlyInIOS: [], onlyInTS: [] },
        `Enum ${enumName} cases diverged. ` +
          (onlyInIOS.length > 0 ? `Only in iOS: ${onlyInIOS.join(", ")}. ` : "") +
          (onlyInTS.length > 0 ? `Only in TS: ${onlyInTS.join(", ")}.` : "")
      );
    }
  });

  for (const [modelName, model] of Object.entries(fixture.models)) {
    it(`${modelName}: fields and types match the zod schema`, () => {
      const schema = namedSchemas[modelName];
      assert.ok(
        schema,
        `No zod schema named ${modelName}Schema is exported from validation.ts`
      );
      const shape = zodObjectShape(schema);

      const iosFields = new Set(Object.keys(model.fields));
      const tsFields = new Set(Object.keys(shape));

      const missingOnTS = [...iosFields].filter((f) => !tsFields.has(f));
      const orphanOnTS = [...tsFields].filter((f) => !iosFields.has(f));
      assert.deepEqual(
        { missingOnTS, orphanOnTS },
        { missingOnTS: [], orphanOnTS: [] },
        `${modelName} field set diverged. ` +
          (missingOnTS.length > 0
            ? `iOS has fields the TS schema is missing: ${missingOnTS.join(", ")}. `
            : "") +
          (orphanOnTS.length > 0
            ? `TS schema has fields the iOS struct is missing: ${orphanOnTS.join(", ")}.`
            : "")
      );

      // Field-by-field type comparison.
      for (const [fieldName, iosSwiftType] of Object.entries(model.fields)) {
        const tsZod = shape[fieldName];
        if (!tsZod) continue; // already reported above
        const iosDesc = normalizeSwiftType(iosSwiftType);
        const tsDesc = normalizeZodType(tsZod);
        assert.equal(
          tsDesc,
          iosDesc,
          `${modelName}.${fieldName}: iOS says "${iosSwiftType}" → ${iosDesc}; ` +
            `TS zod schema says ${tsDesc}. Fix whichever side is out of date.`
        );
      }
    });
  }
});
