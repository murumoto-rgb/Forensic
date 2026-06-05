/**
 * Mirrors for the five pieces of app-wide state iOS keeps on
 * `ProjectStore`: tag library, AI rules template, bucket library,
 * report branding, AI prompt templates. Backed by the `app_config`
 * SQL table (migration 0004). Each piece is addressable by an
 * `AppConfigKey` string; the value shape depends on the key and is
 * declared per-key below.
 *
 * Phase 4 ships the first two only — tagLibrary + aiRulesTemplate
 * are what the web "Re-tag with AI" button needs to assemble the
 * same vocabulary-scoped prompt iOS produces. The other three keys
 * are reserved in the union so adding their TS / zod definitions
 * later doesn't require API churn.
 *
 * Source of truth: iOS Swift structs in
 *   ios/SitePhoto/Models/TagLibrary.swift
 *   ios/SitePhoto/Models/AIRulesTemplate.swift
 * The parity contract test extends to these once iOS push lands
 * (Build #5.36.1 follow-up).
 */

// ---------------------------------------------------------------------------
// Tag library — mirrors iOS TagLibrary / InvestigationContext /
// PrimaryTagEntry / SecondaryTagEntry.
// ---------------------------------------------------------------------------

/** Lowest-level vocabulary node. iOS: SecondaryTagEntry. */
export interface SecondaryTagEntry {
  /** UUID. Stable across edits — used by `ProjectTagSelection.deselectedSecondariesByPrimary`. */
  id: string;
  name: string;
}

/** Middle-level vocabulary node. iOS: PrimaryTagEntry. */
export interface PrimaryTagEntry {
  /** UUID. Stable across edits — used by `ProjectTagSelection.primariesByContext`. */
  id: string;
  name: string;
  secondaries: SecondaryTagEntry[];
}

/** Top-level vocabulary node. iOS: InvestigationContext. */
export interface InvestigationContext {
  /** UUID. Stable across edits — used by `ProjectTagSelection.contextIDs`. */
  id: string;
  name: string;
  primaries: PrimaryTagEntry[];
}

/**
 * App-wide three-level catalog the AI tagging pipeline draws from.
 * Each project picks a subset of this catalog into
 * `Project.tagSelection`; the selection is resolved against this
 * library at prompt-compile time to produce the controlled-vocabulary
 * block the model sees.
 *
 * `seedVersion` is informational — iOS records which bundled seed
 * populated the device's library on first launch. The web client
 * does NOT migrate off it; new bundled seeds land via additive
 * iOS-side migration, then sync up to the server.
 */
export interface TagLibrary {
  contexts: InvestigationContext[];
  seedVersion: number;
}

// ---------------------------------------------------------------------------
// AI rules template — just a string today. iOS: AIRulesTemplate.defaultText.
// Wrapped in an object so we can add sibling fields later (e.g.
// `lastEditedBy`, `presets`) without breaking the wire shape.
// ---------------------------------------------------------------------------

export interface AIRulesTemplate {
  /** The full template body — system prompt's rules / schema section. */
  text: string;
}

// ---------------------------------------------------------------------------
// Key union + value-shape mapping.
// ---------------------------------------------------------------------------

/**
 * All app_config keys the server knows about. New entries:
 *  1. Add the key here.
 *  2. Add the value-shape mapping in `AppConfigValueByKey`.
 *  3. Add the zod schema in `validation.ts`.
 *  4. Add the dispatch arm in the server's `/v1/config/:key` route.
 *  5. Update iOS push/pull to cover it.
 */
export type AppConfigKey =
  | "tagLibrary"
  | "aiRulesTemplate"
  | "tagLibraryDefault"
  | "aiRulesTemplateDefault";

/**
 * Map from `AppConfigKey` to the value shape stored under that key.
 * Used by the typed API helpers so callers get back the right type
 * for the key they asked for.
 *
 * **`tagLibrary` / `aiRulesTemplate` are EDITABLE.** They carry the
 * team's current customised values (or the bundled defaults until
 * someone customises them). Both iOS and the web admin pages
 * (`/admin/tag-library`, `/admin/ai-rules`) read and write these.
 *
 * **`tagLibraryDefault` / `aiRulesTemplateDefault` are READ-ONLY
 * mirrors of the iOS-bundled defaults** (Build #5.48.1). iOS pushes
 * them at every launch via `AppConfigSyncer.pullAllFromServer()` so
 * the server stays in step with the iOS code shipped via TestFlight.
 * They are NOT user-editable from any UI — the only way to change
 * them is to ship a new iOS build with different
 * `AIRulesTemplate.defaultText` / `TagLibrary.defaultSeeds` Swift
 * constants. Web reads these to power the "Restore default" button
 * on the admin pages; web does NOT write them.
 *
 * (The "only editable via code" constraint is enforced by
 * convention, not server-side ACL — the server treats all four keys
 * the same way at the routing layer. Don't add a "save default"
 * button to the admin pages.)
 */
export interface AppConfigValueByKey {
  tagLibrary: TagLibrary;
  aiRulesTemplate: AIRulesTemplate;
  tagLibraryDefault: TagLibrary;
  aiRulesTemplateDefault: AIRulesTemplate;
}
