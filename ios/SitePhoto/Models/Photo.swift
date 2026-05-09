import Foundation

struct Photo: Identifiable, Codable, Hashable {
    let id: UUID
    var sequenceNumber: Int
    var timestamp: Date
    var imageFilename: String
    var thumbnailFilename: String?
    var localXFeet: Double?
    var localYFeet: Double?
    var planPixelX: Double?
    var planPixelY: Double?
    var headingDegrees: Double?
    var positionSource: PositionSource
    var groupID: UUID?
    var isPrimary: Bool
    var cameraZoom: Double
    var lensName: String?
    var flashMode: FlashMode
    var aiDescription: String?
    /// Severity bucket Claude assigned to the most relevant distress in the
    /// photo. One of: None, Minor, Moderate, Significant, Severe, Cannot
    /// Determine. Stored verbatim so the UI can show it as Claude returned
    /// it.
    var aiSeverity: String?
    /// One-sentence report-style observation Claude wrote about the photo
    /// — uses cautious language ("visible", "appears", etc.).
    var aiObservation: String?
    /// One-sentence follow-up recommendation Claude wrote (e.g. "Correlate
    /// with elevation survey", "Field-measure crack width").
    var aiFollowUp: String?
    /// User-confirmed tags (what shows up on the row, in filters, in the PDF).
    /// Each carries a confidence — `1.0` for manually-typed/confirmed tags,
    /// the originating AI score for accepted suggestions. The threshold
    /// slider in Settings filters which of these actually render.
    var tags: [Tag]
    /// AI-generated tag candidates that haven't been confirmed yet. Persisted
    /// so the user can come back later and accept/reject without re-running
    /// the analysis. Empty array (not nil) when none are pending.
    var pendingSuggestions: [TagSuggestion]

    init(id: UUID = UUID(), sequenceNumber: Int, imageFilename: String) {
        self.id = id
        self.sequenceNumber = sequenceNumber
        self.timestamp = Date()
        self.imageFilename = imageFilename
        self.thumbnailFilename = nil
        self.localXFeet = nil
        self.localYFeet = nil
        self.planPixelX = nil
        self.planPixelY = nil
        self.headingDegrees = nil
        self.positionSource = .none
        self.groupID = nil
        self.isPrimary = false
        self.cameraZoom = 1.0
        self.lensName = nil
        self.flashMode = .auto
        self.aiDescription = nil
        self.aiSeverity = nil
        self.aiObservation = nil
        self.aiFollowUp = nil
        self.tags = []
        self.pendingSuggestions = []
    }

    /// Tolerate manifests written before tags existed — decode the new fields
    /// as empty when missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                 = try c.decode(UUID.self,              forKey: .id)
        self.sequenceNumber     = try c.decode(Int.self,               forKey: .sequenceNumber)
        self.timestamp          = try c.decode(Date.self,              forKey: .timestamp)
        self.imageFilename      = try c.decode(String.self,            forKey: .imageFilename)
        self.thumbnailFilename  = try c.decodeIfPresent(String.self,   forKey: .thumbnailFilename)
        self.localXFeet         = try c.decodeIfPresent(Double.self,   forKey: .localXFeet)
        self.localYFeet         = try c.decodeIfPresent(Double.self,   forKey: .localYFeet)
        self.planPixelX         = try c.decodeIfPresent(Double.self,   forKey: .planPixelX)
        self.planPixelY         = try c.decodeIfPresent(Double.self,   forKey: .planPixelY)
        self.headingDegrees     = try c.decodeIfPresent(Double.self,   forKey: .headingDegrees)
        self.positionSource     = try c.decode(PositionSource.self,    forKey: .positionSource)
        self.groupID            = try c.decodeIfPresent(UUID.self,     forKey: .groupID)
        self.isPrimary          = try c.decode(Bool.self,              forKey: .isPrimary)
        self.cameraZoom         = try c.decode(Double.self,            forKey: .cameraZoom)
        self.lensName           = try c.decodeIfPresent(String.self,   forKey: .lensName)
        self.flashMode          = try c.decode(FlashMode.self,         forKey: .flashMode)
        self.aiDescription      = try c.decodeIfPresent(String.self,   forKey: .aiDescription)
        self.aiSeverity         = try c.decodeIfPresent(String.self,   forKey: .aiSeverity)
        self.aiObservation      = try c.decodeIfPresent(String.self,   forKey: .aiObservation)
        self.aiFollowUp         = try c.decodeIfPresent(String.self,   forKey: .aiFollowUp)
        // tags has shipped in two formats — legacy `[String]` (no
        // confidence) and the current `[Tag]`. Decode whichever the
        // manifest contains, treating legacy entries as confidence 1.0
        // (manual / confirmed) so they pass any threshold the user sets.
        if let typed = try? c.decode([Tag].self, forKey: .tags) {
            self.tags = typed
        } else if let legacy = try? c.decode([String].self, forKey: .tags) {
            self.tags = legacy.map { Tag(label: $0, confidence: 1.0) }
        } else {
            self.tags = []
        }
        self.pendingSuggestions = try c.decodeIfPresent([TagSuggestion].self,
                                                        forKey: .pendingSuggestions) ?? []
    }
}

/// A tag attached to a photo. `label` is the display string (case
/// preserved as the user / AI typed it). `confidence` is 1.0 for
/// manually-added tags and the originating AI score (0.0–1.0) for
/// accepted suggestions. A threshold slider in Settings filters which
/// tags actually render.
///
/// `parentTag` encodes the primary→secondary hierarchy from the AI guide.
/// `nil` means the tag is a primary tag (e.g. "Masonry"); a non-nil value
/// means this is a secondary tag whose parent primary is named there
/// (e.g. label = "Brick crack", parentTag = "Masonry"). Manually-typed
/// tags default to nil and are treated as primary-level entries by the
/// filter view.
struct Tag: Codable, Hashable {
    var label: String
    var confidence: Double
    var parentTag: String?

    init(label: String, confidence: Double = 1.0, parentTag: String? = nil) {
        self.label = label
        self.confidence = max(0, min(1, confidence))
        self.parentTag = parentTag?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// Tolerate manifests written before `parentTag` existed, and migrate
    /// flattened "Primary / Secondary" labels (the brief format we shipped
    /// between the bucket rewrite and the hierarchy rewrite) into separate
    /// label + parentTag values so they participate in the new filter UI.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawLabel = try c.decode(String.self, forKey: .label)
        let conf     = try c.decode(Double.self, forKey: .confidence)
        let parent   = try c.decodeIfPresent(String.self, forKey: .parentTag)
        if parent == nil, let split = Tag.splitFlattenedLabel(rawLabel) {
            self.label = split.secondary
            self.parentTag = split.primary
        } else {
            self.label = rawLabel
            self.parentTag = parent?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        self.confidence = max(0, min(1, conf))
    }

    /// Split "Primary / Secondary" → ("Primary", "Secondary") if the input
    /// looks like exactly that shape. Returns nil for plain primary-only
    /// labels and for labels that contain " / " for unrelated reasons
    /// (e.g. category names like "Drainage / Grading" that *are* primary
    /// tags themselves).
    private static func splitFlattenedLabel(_ raw: String) -> (primary: String, secondary: String)? {
        let parts = raw.components(separatedBy: " / ")
        guard parts.count == 2 else { return nil }
        let primary = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primary.isEmpty, !secondary.isEmpty else { return nil }
        // Only split when the left side matches a known primary tag from the
        // AI guide — otherwise we'd accidentally chop "Drainage / Grading".
        guard AIInstructions.knownPrimaryTagsLowercased.contains(primary.lowercased()) else {
            return nil
        }
        return (primary, secondary)
    }
}

private extension String {
    /// Returns nil if the trimmed string is empty; otherwise returns the
    /// trimmed string. Used to coalesce optional/empty-string parentTag
    /// values into a clean nil.
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

enum PositionSource: String, Codable, Hashable {
    case manual
    case gps
    case none
}

enum FlashMode: String, Codable, Hashable, CaseIterable {
    case auto
    case on
    case off
}

/// One AI-generated tag candidate awaiting user confirmation.
struct TagSuggestion: Codable, Hashable, Identifiable {
    var label: String
    var confidence: Double
    var source: TagSource
    /// Primary tag this suggestion lives under, mirroring `Tag.parentTag`.
    /// Nil for primary-level suggestions; non-nil means `label` is the
    /// secondary tag and `parentTag` is its primary category.
    var parentTag: String?

    var id: String {
        let parentPart = parentTag?.lowercased() ?? ""
        return "\(source.rawValue):\(parentPart)|\(label.lowercased())"
    }

    init(label: String,
         confidence: Double,
         source: TagSource,
         parentTag: String? = nil) {
        self.label = label
        self.confidence = confidence
        self.source = source
        self.parentTag = parentTag?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// Tolerate cached suggestions written before `parentTag` existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.label      = try c.decode(String.self, forKey: .label)
        self.confidence = try c.decode(Double.self, forKey: .confidence)
        self.source     = try c.decode(TagSource.self, forKey: .source)
        self.parentTag  = try c.decodeIfPresent(String.self, forKey: .parentTag)
    }
}

enum TagSource: String, Codable, Hashable {
    /// On-device Apple Vision (`VNClassifyImageRequest`). Generic and free.
    case vision
    /// Cloud Claude vision call. Forensic-aware but requires an API key.
    case claude
}
