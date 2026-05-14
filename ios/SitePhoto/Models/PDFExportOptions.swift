import Foundation

/// Persisted-by-`@AppStorage` user preferences for the PDF export
/// pipeline. Encoded as JSON `Data` so the section-order array can
/// travel through `@AppStorage` without a custom string codec.
///
/// Every Codable field uses `decodeIfPresent` with a default so adding
/// a new field in the future never wedges previously-saved data.
struct PDFExportOptions: Codable, Equatable, Sendable {
    var perPage: Int
    var groupByBucket: Bool
    var includeMetadataTable: Bool
    /// Per-photo annotations rendered under each contact-sheet cell.
    /// Each field is independently toggleable so the engineer can pick
    /// "just photos + tags" or "photos with full AI annotations" etc.
    /// Default keeps the legacy behaviour (tags only).
    var annotations: AnnotationOptions
    /// Ordered list of *optional* sections. Cover is always page 1 and
    /// is intentionally not in this array — it can't be moved or
    /// removed. The runtime renders sections in this order, skipping
    /// any whose data isn't applicable (no plan → skip `.plan`,
    /// `includeMetadataTable == false` → skip `.metadataTable`).
    var sectionOrder: [Section]

    /// Bag of independent toggles for per-photo annotations rendered
    /// under each contact-sheet cell. Adding a new annotation = adding
    /// a Bool here + a `decodeIfPresent` line in the decoder + a
    /// branch in `PDFExportService.drawContactSheet`.
    struct AnnotationOptions: Codable, Equatable, Sendable {
        var includeTags: Bool
        var includeCaption: Bool
        var includeObservation: Bool
        var includeMeasurement: Bool
        var includeReviewerFlag: Bool
        var includeConfidence: Bool

        static let defaults = AnnotationOptions(
            includeTags: true,
            includeCaption: false,
            includeObservation: false,
            includeMeasurement: false,
            includeReviewerFlag: false,
            includeConfidence: false
        )

        init(includeTags: Bool,
             includeCaption: Bool,
             includeObservation: Bool,
             includeMeasurement: Bool,
             includeReviewerFlag: Bool,
             includeConfidence: Bool) {
            self.includeTags = includeTags
            self.includeCaption = includeCaption
            self.includeObservation = includeObservation
            self.includeMeasurement = includeMeasurement
            self.includeReviewerFlag = includeReviewerFlag
            self.includeConfidence = includeConfidence
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = AnnotationOptions.defaults
            self.includeTags         = try c.decodeIfPresent(Bool.self, forKey: .includeTags)         ?? d.includeTags
            self.includeCaption      = try c.decodeIfPresent(Bool.self, forKey: .includeCaption)      ?? d.includeCaption
            self.includeObservation  = try c.decodeIfPresent(Bool.self, forKey: .includeObservation)  ?? d.includeObservation
            self.includeMeasurement  = try c.decodeIfPresent(Bool.self, forKey: .includeMeasurement)  ?? d.includeMeasurement
            self.includeReviewerFlag = try c.decodeIfPresent(Bool.self, forKey: .includeReviewerFlag) ?? d.includeReviewerFlag
            self.includeConfidence   = try c.decodeIfPresent(Bool.self, forKey: .includeConfidence)   ?? d.includeConfidence
        }

        /// True when no annotation is enabled — the renderer skips the
        /// whole caption row in that case so the photo fills the cell.
        var allDisabled: Bool {
            !includeTags && !includeCaption && !includeObservation
                && !includeMeasurement && !includeReviewerFlag && !includeConfidence
        }
    }

    enum Section: String, Codable, CaseIterable, Identifiable, Sendable {
        case plan
        case contactSheets
        case metadataTable

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plan:           return "Floor plan"
            case .contactSheets:  return "Contact sheets"
            case .metadataTable:  return "Metadata table"
            }
        }
    }

    static let defaults = PDFExportOptions(
        perPage: 6,
        groupByBucket: false,
        includeMetadataTable: false,
        annotations: .defaults,
        sectionOrder: [.plan, .contactSheets, .metadataTable]
    )

    /// Tolerant decoder — every field falls back to its default when
    /// missing. Lets older persisted blobs survive new field additions
    /// without a migration step.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.perPage              = try c.decodeIfPresent(Int.self, forKey: .perPage)
            ?? PDFExportOptions.defaults.perPage
        self.groupByBucket        = try c.decodeIfPresent(Bool.self, forKey: .groupByBucket)
            ?? PDFExportOptions.defaults.groupByBucket
        self.includeMetadataTable = try c.decodeIfPresent(Bool.self, forKey: .includeMetadataTable)
            ?? PDFExportOptions.defaults.includeMetadataTable
        self.annotations          = try c.decodeIfPresent(AnnotationOptions.self, forKey: .annotations)
            ?? PDFExportOptions.defaults.annotations
        let storedOrder = try c.decodeIfPresent([Section].self, forKey: .sectionOrder)
            ?? PDFExportOptions.defaults.sectionOrder
        // Ensure every Section case appears exactly once, in case a
        // newly-added case isn't in the persisted blob.
        var seen = Set<Section>()
        var resolved: [Section] = []
        for s in storedOrder where !seen.contains(s) {
            resolved.append(s); seen.insert(s)
        }
        for s in Section.allCases where !seen.contains(s) {
            resolved.append(s); seen.insert(s)
        }
        self.sectionOrder = resolved
    }

    init(perPage: Int,
         groupByBucket: Bool,
         includeMetadataTable: Bool,
         annotations: AnnotationOptions = .defaults,
         sectionOrder: [Section]) {
        self.perPage = perPage
        self.groupByBucket = groupByBucket
        self.includeMetadataTable = includeMetadataTable
        self.annotations = annotations
        self.sectionOrder = sectionOrder
    }

    /// Encode + decode helpers used by `@AppStorage` callers that need
    /// to round-trip through `Data`.
    func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func from(jsonData data: Data) -> PDFExportOptions {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(PDFExportOptions.self, from: data) else {
            return .defaults
        }
        return decoded
    }
}
