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
    /// Ordered list of *optional* sections. Cover is always page 1 and
    /// is intentionally not in this array — it can't be moved or
    /// removed. The runtime renders sections in this order, skipping
    /// any whose data isn't applicable (no plan → skip `.plan`,
    /// `includeMetadataTable == false` → skip `.metadataTable`).
    var sectionOrder: [Section]

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
         sectionOrder: [Section]) {
        self.perPage = perPage
        self.groupByBucket = groupByBucket
        self.includeMetadataTable = includeMetadataTable
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
