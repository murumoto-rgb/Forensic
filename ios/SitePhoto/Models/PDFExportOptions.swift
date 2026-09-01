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
    /// Specific floor plans to include in the export. `nil` = "include
    /// all floors" (also the default for projects that pre-date this
    /// option). Photos not on any included plan land in the trailing
    /// "Unlocated photos" section so nothing gets dropped.
    var selectedFloorIDs: Set<UUID>?
    /// How each floor's `.plan` section is rendered. The default
    /// `.photoOnly` matches the legacy behaviour so existing exports
    /// produce the same output.
    var planMode: PlanRenderMode

    /// Choices for the `.plan` section rendering when distress
    /// annotations are present on a floor. The four modes cover the
    /// cross-product of {photo pins, distress marks} × {separate
    /// pages, one merged page}.
    enum PlanRenderMode: String, Codable, CaseIterable, Sendable, Identifiable {
        case photoOnly
        case distressOnly
        case photoAndDistressSeparate
        case merged

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .photoOnly:                return "Photo plan only"
            case .distressOnly:             return "Distress plan only"
            case .photoAndDistressSeparate: return "Both on separate pages"
            case .merged:                   return "Both merged on one page"
            }
        }

        /// Whether the photo-pin overlay should be drawn for this mode.
        var rendersPhotos: Bool {
            self == .photoOnly || self == .photoAndDistressSeparate || self == .merged
        }
        /// Whether the distress overlay should be drawn for this mode.
        var rendersDistress: Bool {
            self == .distressOnly || self == .photoAndDistressSeparate || self == .merged
        }
        /// Whether photos + distress share a single page (otherwise
        /// they get one page each).
        var collapsesOntoOnePage: Bool {
            self == .merged || self == .photoOnly || self == .distressOnly
        }
    }

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

        static let defaults = AnnotationOptions(
            includeTags: true,
            includeCaption: false,
            includeObservation: false,
            includeMeasurement: false,
            includeReviewerFlag: false
        )

        init(includeTags: Bool,
             includeCaption: Bool,
             includeObservation: Bool,
             includeMeasurement: Bool,
             includeReviewerFlag: Bool) {
            self.includeTags = includeTags
            self.includeCaption = includeCaption
            self.includeObservation = includeObservation
            self.includeMeasurement = includeMeasurement
            self.includeReviewerFlag = includeReviewerFlag
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = AnnotationOptions.defaults
            self.includeTags         = try c.decodeIfPresent(Bool.self, forKey: .includeTags)         ?? d.includeTags
            self.includeCaption      = try c.decodeIfPresent(Bool.self, forKey: .includeCaption)      ?? d.includeCaption
            self.includeObservation  = try c.decodeIfPresent(Bool.self, forKey: .includeObservation)  ?? d.includeObservation
            self.includeMeasurement  = try c.decodeIfPresent(Bool.self, forKey: .includeMeasurement)  ?? d.includeMeasurement
            self.includeReviewerFlag = try c.decodeIfPresent(Bool.self, forKey: .includeReviewerFlag) ?? d.includeReviewerFlag
        }

        /// True when no annotation is enabled — the renderer skips the
        /// whole caption row in that case so the photo fills the cell.
        var allDisabled: Bool {
            !includeTags && !includeCaption && !includeObservation
                && !includeMeasurement && !includeReviewerFlag
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
        sectionOrder: [.plan, .contactSheets, .metadataTable],
        selectedFloorIDs: nil,
        planMode: .photoOnly
    )

    /// Tolerant decoder — every field falls back to its default when
    /// missing. Lets older persisted blobs survive new field additions
    /// without a migration step.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.perPage = min(12, max(1, try c.decodeIfPresent(Int.self, forKey: .perPage)
            ?? PDFExportOptions.defaults.perPage))
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
        self.selectedFloorIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .selectedFloorIDs)
        self.planMode = try c.decodeIfPresent(PlanRenderMode.self, forKey: .planMode)
            ?? PDFExportOptions.defaults.planMode
    }

    init(perPage: Int,
         groupByBucket: Bool,
         includeMetadataTable: Bool,
         annotations: AnnotationOptions = .defaults,
         sectionOrder: [Section],
         selectedFloorIDs: Set<UUID>? = nil,
         planMode: PlanRenderMode = .photoOnly) {
        self.perPage = min(12, max(1, perPage))
        self.groupByBucket = groupByBucket
        self.includeMetadataTable = includeMetadataTable
        self.annotations = annotations
        self.sectionOrder = sectionOrder
        self.selectedFloorIDs = selectedFloorIDs
        self.planMode = planMode
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
