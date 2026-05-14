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
    /// `selection`, with optional per-project extras merged in.
    /// Returns an empty vocabulary if `selection` is empty and no
    /// extras are present — call sites should have caught the
    /// nothing-picked case earlier via `PromptCompiler.compile`, but
    /// the fallback keeps the validator safe.
    ///
    /// `extras` carries `Project.aiExtraVocabulary` and is merged
    /// directly into the same primaries / secondaries sets — Claude
    /// sees a single flat vocabulary on the wire, so the validator
    /// can't distinguish (and doesn't care) whether a tag came from
    /// the library + selection or the per-project extras.
    static func resolve(library: TagLibrary,
                          selection: ProjectTagSelection,
                          extras: ProjectExtraVocabulary? = nil) -> ValidationVocabulary {
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
        // Merge per-project extras. Skip primaries with a blank
        // name (defensive — editor shouldn't allow it). For a
        // primary name that ALSO exists in the library + selection,
        // union the secondary sets so the engineer can extend an
        // existing primary's vocabulary on a per-project basis.
        if let extras {
            for primary in extras.primaries {
                let trimmedName = primary.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { continue }
                let key = trimmedName.lowercased()
                primaries.insert(key)
                var secs = secondariesByPrimary[key] ?? ["none"]
                for s in primary.secondaries {
                    let secName = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !secName.isEmpty else { continue }
                    secs.insert(secName.lowercased())
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

        // 1. Primary tag count must be 0, 1, or 2. The empty case is
        //    valid when the photo's main subject doesn't match any
        //    primary in the project's vocabulary — the prompt tells the
        //    model to prefer [] over a misleading best-fit and to use
        //    reviewer_flag to surface the gap.
        if a.primaryTags.count > 2 {
            errors.append("primary_tags has \(a.primaryTags.count) entries (max 2).")
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
            errors.append("scale_present has unknown value \"\(a.scalePresent.displayName)\" (expected Yes / Relative / No).")
        }
        if !a.recommendedUse.isKnown {
            errors.append("recommended_use has unknown value \"\(a.recommendedUse.displayName)\" (expected Body figure / Appendix only / Context/locator / Re-shoot recommended).")
        }

        // 5. summary_observation must not contain disallowed causation
        //    phrases (case-insensitive).
        let obsLC = a.summaryObservation.lowercased()
        for phrase in causationPhrases {
            if obsLC.contains(phrase) {
                errors.append("summary_observation contains disallowed phrase \"\(phrase)\" — use cautious language instead.")
            }
        }

        // 6. tag_confidences sanity. Every value must fall in [0, 1] and
        //    every non-"None" secondary should have an entry. Primaries
        //    do NOT get a confidence — confidence lives only at the
        //    secondary (leaf) level now. Missing-secondary entries are
        //    surfaced as warnings (the suggestions builder falls back
        //    to a neutral value), and out-of-range numbers are surfaced
        //    because they indicate the model misread the schema.
        let confKeysLC = Set(a.tagConfidences.keys.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        for (key, value) in a.tagConfidences where !(0...1).contains(value) {
            errors.append("tag_confidences[\"\(key)\"] = \(value) is out of range (expected 0…1).")
        }
        for (_, secondaries) in a.secondaryTagsByPrimary {
            for sec in secondaries {
                let trimmed = sec.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { continue }
                if !confKeysLC.contains(trimmed.lowercased()) {
                    errors.append("tag_confidences missing entry for secondary \"\(sec)\".")
                }
            }
        }

        return errors
    }
}
