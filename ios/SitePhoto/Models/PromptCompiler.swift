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
    private static let systemPreamble = """
    You are an AI assistant tagging forensic site-investigation \
    photographs. The rules below describe the JSON schema you must \
    emit. The controlled vocabulary below the rules is scoped to this \
    specific project — use ONLY the investigation contexts, primary \
    tags, and secondary tags listed there.
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

    /// Compiled output: the full system prompt to send + the
    /// project-scoped validation vocabulary the response should be
    /// checked against. Bundled together so callers don't have to walk
    /// the library twice.
    struct Result: Sendable {
        let systemPrompt: String
        let vocabulary: ValidationVocabulary
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
        let notesBlock = compileNotesBlock(project.aiInstructions)

        var parts: [String] = [systemPreamble, rules, vocabularyBlock]
        if let notesBlock { parts.append(notesBlock) }
        parts.append(outputContract)
        return Result(
            systemPrompt: parts.joined(separator: "\n\n"),
            vocabulary: ValidationVocabulary.resolve(library: tagLibrary,
                                                       selection: selection)
        )
    }

    /// Build the vocabulary block in the same shape as the engineer's
    /// starter pack — readable for the human reviewing the prompt, and
    /// unambiguous for Claude.
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
                let activeSecondaries = primary.secondaries.filter { !deselected.contains($0.id) }
                guard !activeSecondaries.isEmpty else { continue }

                lines.append("")
                lines.append("Primary tag: \(primary.name)")
                lines.append("Secondary tags:")
                for s in activeSecondaries {
                    lines.append("- \(s.name)")
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
}
