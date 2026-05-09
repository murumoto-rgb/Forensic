import Foundation

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
    static func validate(_ a: AIPhotoAnalysis) -> [String] {
        var errors: [String] = []

        // 1. Primary tag count must be 1 or 2.
        switch a.primaryTags.count {
        case 1, 2: break
        case 0:    errors.append("primary_tags is empty (need 1 or 2 entries).")
        default:   errors.append("primary_tags has \(a.primaryTags.count) entries (max 2).")
        }

        // 2. Each primary must be one of the 23 controlled categories.
        for primary in a.primaryTags {
            if !ControlledVocabulary.isValidPrimary(primary) {
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
                if !ControlledVocabulary.isValid(secondary: sec, under: primary) {
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
