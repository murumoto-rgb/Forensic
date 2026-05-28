import Foundation

/// Build a CSV of every AI-analysed photo in a project so the engineer can
/// review and filter the AI's output in Excel / Google Sheets. One row per
/// (photo × primary tag) pair so a spreadsheet pivot by Context or Primary
/// Tag works without further transformation. Photos whose primary_tags came
/// back empty still appear once with blank tag columns so the engineer can
/// scan the AI's observation + reviewer_flag and decide whether the
/// vocabulary needs extending.
///
/// Output is UTF-8 with a leading BOM so Excel correctly detects the
/// encoding on import — otherwise diacritics / em-dashes / curly quotes
/// land as mojibake.
@MainActor
struct AIAnalysisCSVExportService {
    let project: Project
    let tagLibrary: TagLibrary
    let store: ProjectStore

    /// Write the CSV under the project's Exports folder and return the
    /// URL, or nil if no AI-analysed photos exist (nothing to write) or
    /// the filesystem write failed.
    func export() -> URL? {
        let analysed = project.photos.filter {
            guard let a = $0.aiAnalysis else { return false }
            return !a.parseFailed
        }
        guard !analysed.isEmpty else { return nil }

        let csvData = makeCSVData(for: analysed)

        let exportRoot = store.rootURL.appending(
            path: "Exports", directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: exportRoot, withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let stamp = stampString()
        let safeProject = sanitize(project.name)
        let baseName = "\(safeProject)_AI_\(stamp)"
        var url = exportRoot.appending(path: "\(baseName).csv")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path()) {
            url = exportRoot.appending(path: "\(baseName) (\(counter)).csv")
            counter += 1
        }

        do {
            try csvData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func makeCSVData(for photos: [Photo]) -> Data {
        // Pre-index primary tag name → containing investigation context so
        // every row lookup is O(1) rather than O(library).
        var contextByPrimary: [String: String] = [:]
        for ctx in tagLibrary.contexts {
            for p in ctx.primaries {
                contextByPrimary[p.name.lowercased()] = ctx.name
            }
        }

        let headers = [
            "Sequence",
            "Filename",
            "Context",
            "Primary Tag",
            "Secondary Tags",
            "Tag Confidence",
            "Observation",
            "Caption",
            "Measurement",
            "Scale",
            "Location",
            "Recommended Use",
            "Reviewer Flag"
        ]

        var rows: [[String]] = [headers]
        let sorted = photos.sorted { $0.sequenceNumber < $1.sequenceNumber }

        for photo in sorted {
            guard let a = photo.aiAnalysis else { continue }
            let head: [String] = [
                String(photo.sequenceNumber),
                photo.imageFilename
            ]
            let tail: [String] = [
                a.summaryObservation,
                a.captionDraft,
                a.measurementVisible ?? "",
                a.scalePresent.displayName,
                a.locationInferred,
                a.recommendedUse.displayName,
                a.reviewerFlag
            ]

            if a.primaryTags.isEmpty {
                // Photo was analysed but the model returned no primary tag
                // — usually because the project's vocabulary didn't have a
                // matching category. Emit one row so observation + reviewer
                // flag still show up in the export.
                rows.append(head + ["", "", "", ""] + tail)
            } else {
                for primary in a.primaryTags {
                    let ctx = contextByPrimary[primary.lowercased()] ?? ""
                    let secondaries = secondaryList(for: primary, in: a)
                    let conf = confidence(for: primary, in: a)
                    rows.append(head + [ctx, primary, secondaries, conf] + tail)
                }
            }
        }

        let body = rows.map(formatRow).joined(separator: "\r\n")
        var out = Data([0xEF, 0xBB, 0xBF])
        out.append(body.data(using: .utf8) ?? Data())
        return out
    }

    /// Join a primary's secondaries into one cell, dropping the "None"
    /// sentinel. Case-insensitive primary-key lookup tolerates the model
    /// returning the key with slightly different casing than it used in
    /// `primary_tags`.
    private func secondaryList(for primary: String,
                                in analysis: AIPhotoAnalysis) -> String {
        let key = analysis.secondaryTagsByPrimary.keys.first {
            $0.lowercased() == primary.lowercased()
        } ?? primary
        let list = analysis.secondaryTagsByPrimary[key] ?? []
        return list
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "none" }
            .joined(separator: "; ")
    }

    /// Look up the per-tag confidence the model emitted, formatted to two
    /// decimals. Empty string when the model didn't include the entry —
    /// matches how `suggestions(from:)` falls back at apply time.
    private func confidence(for tag: String,
                             in analysis: AIPhotoAnalysis) -> String {
        guard let value = analysis.tagConfidences.first(where: {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == tag.lowercased()
        })?.value else { return "" }
        return String(format: "%.2f", value)
    }

    private func formatRow(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    /// Always quote and double-up internal quotes. Cheaper than detecting
    /// which fields contain a comma/quote/newline and produces the same
    /// shape every time, which is easier to spot-check.
    private func escape(_ s: String) -> String {
        let doubled = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(doubled)\""
    }

    private func stampString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmm"
        fmt.timeZone = .current
        return fmt.string(from: Date())
    }

    private func sanitize(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let bounded = String(cleaned.prefix(60))
        return bounded.isEmpty ? "Project" : bounded
    }
}
