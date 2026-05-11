import Foundation

/// Per-project vocabulary the validator checks AI responses against.
/// Built from a `TagLibrary` + a `ProjectTagSelection` so the validator
/// accepts tags the engineer has added to the library — without that
/// indirection the legacy hardcoded vocabulary would flag every
/// user-added tag as "unknown."
///
/// Lookups are case-folded; canonical capitalisation is preserved for
/// presenting tags back to the user but the comparisons are
/// case-insensitive (Claude occasionally lowercases primaries).
struct ValidationVocabulary: Sendable {
    /// Lowercased primary names. Membership = "this primary is in the
    /// project's scope and is therefore a valid tag for Claude to return."
    let primariesLowercased: Set<String>
    /// For each lowercased primary, the lowercased set of allowed
    /// secondary names. The sentinel `"none"` is always allowed under
    /// every primary because the prompt explicitly tells Claude to use
    /// `["None"]` for contextual photos.
    let secondariesByPrimary: [String: Set<String>]

    /// Resolve the project-scoped vocabulary from `library` +
    /// `selection`. Returns an empty vocabulary if `selection` is empty
    /// — call sites should have caught that earlier via
    /// `PromptCompiler.compile`, but the fallback keeps the validator
    /// safe.
    static func resolve(library: TagLibrary,
                          selection: ProjectTagSelection) -> ValidationVocabulary {
        var primaries: Set<String> = []
        var secondariesByPrimary: [String: Set<String>] = [:]
        for contextID in selection.contextIDs {
            guard let ctx = library.context(id: contextID) else { continue }
            let pickedPrimaryIDs = selection.primariesByContext[contextID] ?? []
            for primary in ctx.primaries where pickedPrimaryIDs.contains(primary.id) {
                let key = primary.name.lowercased()
                primaries.insert(key)
                let deselected = selection.deselectedSecondariesByPrimary[primary.id] ?? []
                var secs: Set<String> = ["none"]
                for s in primary.secondaries where !deselected.contains(s.id) {
                    secs.insert(s.name.lowercased())
                }
                secondariesByPrimary[key] = secs
            }
        }
        return ValidationVocabulary(
            primariesLowercased: primaries,
            secondariesByPrimary: secondariesByPrimary
        )
    }

    /// Static fallback used when no per-project vocabulary is available
    /// (e.g. unit tests, or call paths that haven't been migrated yet).
    /// Mirrors the legacy behaviour: every primary + secondary in the
    /// hardcoded `ControlledVocabulary.entries` is accepted.
    static let fallback: ValidationVocabulary = {
        var primaries: Set<String> = []
        var secondariesByPrimary: [String: Set<String>] = [:]
        for entry in ControlledVocabulary.entries {
            let key = entry.primary.lowercased()
            primaries.insert(key)
            var secs: Set<String> = ["none"]
            for s in entry.secondaries { secs.insert(s.lowercased()) }
            secondariesByPrimary[key] = secs
        }
        return ValidationVocabulary(
            primariesLowercased: primaries,
            secondariesByPrimary: secondariesByPrimary
        )
    }()

    func isValidPrimary(_ name: String) -> Bool {
        primariesLowercased.contains(name.lowercased())
    }

    func isValidSecondary(_ name: String, under primary: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "none" { return true }
        return secondariesByPrimary[primary.lowercased()]?.contains(trimmed) ?? false
    }
}

/// Checks a decoded `AIPhotoAnalysis` against the controlled vocabulary
/// and the prompt's content rules. Returns human-readable error strings
/// — never throws, never mutates. Failed photos are kept in the manifest
/// with the error list attached so the user can review and fix.
enum AIResponseValidator {

    /// Disallowed phrasings in `summaryObservation`. The prompt forbids
    /// causation language; we mirror that here so a slip past the model's
    /// instructions still gets surfaced.
    private static let causationPhrases: [String] = [
        "caused by",
        "due to",
        "because of"
    ]

    /// Run every check from the schema-2 spec. Returns a list of
    /// human-facing error messages — empty when the response validates
    /// clean.
    ///
    /// `vocabulary` defaults to the legacy hardcoded set so call sites
    /// that haven't been migrated to per-project vocabulary keep
    /// validating the way they used to.
    static func validate(_ a: AIPhotoAnalysis,
                          vocabulary: ValidationVocabulary = .fallback) -> [String] {
        var errors: [String] = []

        // 1. Primary tag count must be 1 or 2.
        switch a.primaryTags.count {
        case 1, 2: break
        case 0:    errors.append("primary_tags is empty (need 1 or 2 entries).")
        default:   errors.append("primary_tags has \(a.primaryTags.count) entries (max 2).")
        }

        // 2. Each primary must be in the project's scoped vocabulary.
        for primary in a.primaryTags {
            if !vocabulary.isValidPrimary(primary) {
                errors.append("Unknown primary tag: \"\(primary)\".")
            }
        }

        // 3. Every primary must have an entry in secondary_tags_by_primary,
        //    and every secondary in that entry must be verbatim under that
        //    primary (or the universal "None").
        for primary in a.primaryTags {
            let matchingKey = a.secondaryTagsByPrimary.keys.first {
                $0.lowercased() == primary.lowercased()
            }
            guard let key = matchingKey else {
                errors.append("Missing secondary_tags_by_primary entry for primary \"\(primary)\".")
                continue
            }
            let secondaries = a.secondaryTagsByPrimary[key] ?? []
            if secondaries.isEmpty {
                errors.append("secondary_tags_by_primary[\"\(primary)\"] is empty (use [\"None\"] if no distress).")
                continue
            }
            for sec in secondaries {
                if !vocabulary.isValidSecondary(sec, under: primary) {
                    errors.append("Secondary \"\(sec)\" is not listed under primary \"\(primary)\".")
                }
            }
        }

        // 4. Constrained enums must have decoded to a known case.
        if !a.scalePresent.isKnown {
            errors.append("scale_present has unknown value \"\(a.scalePresent.displayName)\" (expected Yes / Partial / No).")
        }
        if !a.recommendedUse.isKnown {
            errors.append("recommended_use has unknown value \"\(a.recommendedUse.displayName)\" (expected Body figure / Appendix only / Context/locator / Re-shoot recommended).")
        }
        if !a.confidence.isKnown {
            errors.append("confidence has unknown value \"\(a.confidence.displayName)\" (expected High / Medium / Low).")
        }
        if !a.likelyCompanion.isKnown {
            errors.append("likely_companion has unknown value \"\(a.likelyCompanion.displayName)\" (expected Close-up / Overview / Standalone).")
        }

        // 5. summary_observation must not contain disallowed causation
        //    phrases (case-insensitive).
        let obsLC = a.summaryObservation.lowercased()
        for phrase in causationPhrases {
            if obsLC.contains(phrase) {
                errors.append("summary_observation contains disallowed phrase \"\(phrase)\" — use cautious language instead.")
            }
        }

        return errors
    }
}
