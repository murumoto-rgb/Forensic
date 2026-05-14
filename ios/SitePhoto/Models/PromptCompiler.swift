import Foundation

/// Compose Claude's system prompt for AI tagging by combining the
/// app-wide rules template with the project's chosen vocabulary subset
/// (and any free-text notes). Pure function — no I/O, no side effects.
///
/// Decoupled from `ClaudeTaggingService` so callers can:
///   * surface a clear "pick at least one investigation context first"
///     error before any network work is done (avoid burning rate limit
///     budget on a request that's missing vocabulary);
///   * unit-test the prompt shape without mocking URLSession;
///   * preview the compiled prompt in a future Settings-side "Preview
///     prompt" affordance if we ever want one.
enum PromptCompiler {

    enum CompileError: Swift.Error, LocalizedError {
        case noContextsPicked

        var errorDescription: String? {
            switch self {
            case .noContextsPicked:
                return "Pick at least one investigation context in AI Tags first. The AI needs project-scoped vocabulary to know which tags to consider."
            }
        }
    }

    /// Short framing prepended to the rules template. Stable across
    /// projects so it benefits from Anthropic's ephemeral prompt cache.
    /// Lives here (not in the user-editable rules template) because it
    /// also carries the comma-separator format hint that pairs with
    /// `compileVocabularyBlock`'s compact output — that contract has
    /// to stay in sync with the network shape regardless of how the
    /// engineer customises their rules text.
    private static let systemPreamble = """
    You are an AI assistant tagging forensic site-investigation \
    photographs. The rules below describe the JSON schema you must \
    emit. The controlled vocabulary below the rules is scoped to this \
    specific project — use ONLY the investigation contexts, primary \
    tags, and secondary tags listed there.

    Vocabulary format: each primary tag's "Secondary tags:" line is a \
    comma-separated list. Treat each comma-separated value as ONE \
    verbatim secondary tag — none of the listed tags themselves \
    contain commas, so a comma inside the list is always a separator.
    """

    /// Short reinforcement appended after everything else. Re-emphasises
    /// "no code fences, no prose" because Claude occasionally adds them
    /// despite the rules template's instructions.
    private static let outputContract = """
    OUTPUT FORMAT (reinforces the rules above; do not contradict them):

    Emit ONLY the single JSON object described above. No prose before \
    or after, no markdown code fences, no commentary, no explanation. \
    Start your response with `{` and end it with `}`.
    """

    /// A single text section of the compiled system prompt. The
    /// `cacheable` flag tells the network layer whether to attach a
    /// `cache_control: ephemeral` marker after this block. The order
    /// of the returned array IS the order of blocks Anthropic sees.
    ///
    /// Blocks are arranged most-stable to least-stable so a cache hit
    /// on the stable prefix survives small edits to downstream blocks:
    ///
    ///   * preamble + rules — only changes when the engineer edits the
    ///     app-wide rules template in Settings (rare).
    ///   * vocabulary — changes when the per-project tag selection
    ///     changes (moderate).
    ///   * notes — changes whenever the engineer tweaks "AI Notes" on
    ///     this project (frequent for some workflows).
    ///   * outputContract — stable but tiny; not worth a cache slot of
    ///     its own.
    struct Block: Sendable {
        let text: String
        let cacheable: Bool
    }

    /// Compiled output: the ordered list of system-prompt blocks +
    /// the project-scoped validation vocabulary the response should be
    /// checked against. Bundled together so callers don't have to walk
    /// the library twice.
    struct Result: Sendable {
        let blocks: [Block]
        let vocabulary: ValidationVocabulary

        /// Convenience accessor — joins every block's text in order
        /// with a blank line between them. Used by the DEBUG prompt
        /// inspector + by anything that just wants the full prompt as
        /// a string.
        var joinedSystemPrompt: String {
            blocks.map(\.text).joined(separator: "\n\n")
        }
    }

    /// Build the system prompt + validation vocabulary for `project`.
    /// Throws when the project has no tag selection yet — the AI
    /// tagging entry points map that error to a friendly toast that
    /// directs the engineer to the AI Tags picker.
    static func compile(rulesTemplate: String,
                         tagLibrary: TagLibrary,
                         project: Project) throws -> Result {
        guard let selection = project.tagSelection, !selection.isEmpty else {
            throw CompileError.noContextsPicked
        }

        let vocabularyBlock = compileVocabularyBlock(
            library: tagLibrary,
            selection: selection
        )

        // If the selection refers entirely to stale IDs (e.g. every
        // picked context was deleted from the library after the
        // selection was saved), the vocabulary block can come back
        // empty even though `selection.isEmpty` is false. Treat that
        // the same as no contexts picked.
        guard !vocabularyBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompileError.noContextsPicked
        }

        let rules = rulesTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let extrasBlock = compileExtraVocabularyBlock(project.aiExtraVocabulary)
        let notesBlock = compileNotesBlock(project.aiInstructions)

        // Block layout — see the `Block` docstring for the rationale.
        // The first block bundles preamble + rules so a small change
        // to either doesn't cost an extra cache slot, and so the
        // combined block easily exceeds Anthropic's 1024-token cache
        // minimum even when the rules template is tiny.
        //
        // Job-specific additions slot between the main vocabulary
        // and the notes block: Claude treats them as part of the
        // vocabulary contract (not advisory text), and putting them
        // after the main vocab means a project-only extras edit
        // invalidates the cache for this block + notes downstream
        // but keeps the preamble + main vocab warm across projects.
        var blocks: [Block] = [
            Block(text: systemPreamble + "\n\n" + rules, cacheable: true),
            Block(text: vocabularyBlock,                  cacheable: true)
        ]
        if let extrasBlock {
            blocks.append(Block(text: extrasBlock, cacheable: true))
        }
        if let notesBlock {
            blocks.append(Block(text: notesBlock, cacheable: true))
        }
        blocks.append(Block(text: outputContract, cacheable: false))

        return Result(
            blocks: blocks,
            vocabulary: ValidationVocabulary.resolve(library: tagLibrary,
                                                       selection: selection,
                                                       extras: project.aiExtraVocabulary)
        )
    }

    /// Build the vocabulary block in a compact comma-separated form.
    /// Semantically identical to the older bullet-per-secondary format
    /// — every tag is still listed verbatim — but uses ~50% fewer
    /// tokens, which directly shortens AI tagging latency and reduces
    /// cache-write cost on first-photo-of-batch.
    ///
    /// Format Claude sees:
    ///   INVESTIGATION CONTEXT: Foundation Performance
    ///   Primary tag: Drainage / Grading
    ///   Secondary tags: None, Adequate drainage, Marginal drainage, …
    ///
    /// The matching "Use commas as field separators inside Secondary
    /// tags lists" hint lives in `AIRulesTemplate.defaultText` so the
    /// model never confuses a comma inside a tag name (none of the
    /// seeded tags carry commas) with a separator.
    private static func compileVocabularyBlock(library: TagLibrary,
                                                 selection: ProjectTagSelection) -> String {
        var lines: [String] = ["Controlled vocabulary for this project:"]

        for contextID in selection.contextIDs {
            guard let ctx = library.context(id: contextID) else { continue }
            let pickedPrimaryIDs = selection.primariesByContext[contextID] ?? []
            let pickedPrimaries = ctx.primaries.filter { pickedPrimaryIDs.contains($0.id) }
            guard !pickedPrimaries.isEmpty else { continue }

            lines.append("")
            lines.append("INVESTIGATION CONTEXT: \(ctx.name)")

            for primary in pickedPrimaries {
                let deselected = selection.deselectedSecondariesByPrimary[primary.id] ?? []
                // Filter out the legacy "None" sentinel here so existing
                // on-disk libraries that still carry it from v2-era seeds
                // don't ship it to Claude. Fresh v3+ seeds no longer
                // include "None" at all; this filter is the bridge for
                // libraries that already have it persisted. Behaviour is
                // case-insensitive and trims whitespace so a
                // typo-renamed " none " stays filtered too.
                let activeSecondaries = primary.secondaries.filter { sec in
                    if deselected.contains(sec.id) { return false }
                    let n = sec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return n != "none"
                }

                lines.append("")
                lines.append("Primary tag: \(primary.name)")
                if activeSecondaries.isEmpty {
                    // Primary has no real secondaries (either the library
                    // genuinely has none, every one was deselected, or
                    // only the legacy "None" sentinel remains). Emit a
                    // bare hint line so the model sees the primary at
                    // all rather than silently dropping the heading.
                    lines.append("Secondary tags: (no specific secondaries — tag the primary alone if visible)")
                } else {
                    let joined = activeSecondaries.map(\.name).joined(separator: ", ")
                    lines.append("Secondary tags: \(joined)")
                }
            }
        }

        // If nothing made it past the filters (every picked context was
        // empty / stale), return an empty string and let the caller treat
        // it as `noContextsPicked`.
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    /// Render the optional per-project notes as a labelled block that
    /// Claude can clearly distinguish from the rules / vocabulary.
    /// Returns nil when there are no notes so the joined prompt stays
    /// tidy.
    private static func compileNotesBlock(_ notes: String?) -> String? {
        let trimmed = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "Additional notes for this project:\n\(trimmed)"
    }

    /// Render the optional per-project extra vocabulary as a labelled
    /// block that mirrors the main `compileVocabularyBlock` format —
    /// `INVESTIGATION CONTEXT: …` heading, then `Primary tag: …` /
    /// `Secondary tags: …` lines. Claude needs no special instruction
    /// to read it because the shape is identical to the main block.
    ///
    /// Returns nil when `extras` is nil, has no primaries, or every
    /// primary has been emptied to an empty `secondaries` array (in
    /// which case the block would degrade to bare headings, which the
    /// cross-check rule can't validate against).
    private static func compileExtraVocabularyBlock(_ extras: ProjectExtraVocabulary?) -> String? {
        guard let extras, !extras.primaries.isEmpty else { return nil }

        // Drop primaries with no name (defensive — the editor should
        // prevent this, but defending here keeps stale data from
        // sneaking blank "Primary tag:" lines into the prompt).
        let cleanPrimaries = extras.primaries.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !cleanPrimaries.isEmpty else { return nil }

        var lines: [String] = [
            "Job-specific additions to the controlled vocabulary:",
            "",
            "INVESTIGATION CONTEXT: Job-Specific Additions"
        ]
        for primary in cleanPrimaries {
            // Match the main block's "None" filter so a legacy extras
            // entry that picked up a "None" secondary from the picker
            // wouldn't ship that sentinel to Claude.
            let secondaries = primary.secondaries.filter { sec in
                let n = sec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !n.isEmpty && n != "none"
            }
            lines.append("")
            lines.append("Primary tag: \(primary.name)")
            if secondaries.isEmpty {
                lines.append("Secondary tags: (no specific secondaries — tag the primary alone if visible)")
            } else {
                let joined = secondaries.map(\.name).joined(separator: ", ")
                lines.append("Secondary tags: \(joined)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
