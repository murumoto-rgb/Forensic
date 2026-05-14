import Foundation

/// Per-project additions to the controlled vocabulary. Carried on
/// `Project` as an optional sub-structure; absent on every project
/// that hasn't opted in.
///
/// Design choices (user-approved):
/// - **Always-on for the owning project.** No AI Tags picker toggle.
///   If the engineer added these to a project, they're sent to Claude
///   in the prompt for that project and accepted by
///   `AIResponseValidator` for responses to that project. Nothing in
///   the app-wide `TagLibrary` is touched.
/// - **No engineer-named contexts.** Shape is `[primary -> [secondaries]]`.
///   The prompt renders all entries under a single synthetic context
///   header `"Job-Specific Additions"` so Claude treats them
///   identically to the main vocab block.
///
/// `PrimaryTagEntry` and `SecondaryTagEntry` are reused verbatim from
/// `TagLibrary.swift`. Same identifier system, same Codable shape,
/// same iteration helpers in `PromptCompiler` / `ValidationVocabulary`.
struct ProjectExtraVocabulary: Codable, Hashable, Sendable {
    /// Ordered list of project-only primaries. Engineer-determined
    /// display order; the prompt block preserves it. Empty array is
    /// equivalent to "no extras" — callers that emit the extras block
    /// should check `isEmpty` and skip the block entirely so the
    /// prompt cache stays warm.
    var primaries: [PrimaryTagEntry]

    init(primaries: [PrimaryTagEntry] = []) {
        self.primaries = primaries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.primaries = try c.decodeIfPresent([PrimaryTagEntry].self,
                                                 forKey: .primaries) ?? []
    }

    /// True when the engineer has either never opted in or removed
    /// every entry. Callers should treat an empty extras block as
    /// equivalent to a nil one — no prompt block, no validator
    /// merge, no UI footnote.
    var isEmpty: Bool { primaries.isEmpty }

    /// Total count of secondaries across all primaries. Used by the
    /// entry-row badge in `ProjectInfoView` so the engineer can see
    /// at a glance how much extra vocab is attached without opening
    /// the editor.
    var secondaryCount: Int {
        primaries.reduce(0) { $0 + $1.secondaries.count }
    }
}
