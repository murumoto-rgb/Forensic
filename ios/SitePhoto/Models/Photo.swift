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
    /// Legacy severity field from the pre-schema-2 prompt. The new prompt
    /// no longer asks for severity; this field is preserved on existing
    /// records and is set to nil whenever a new analysis lands.
    var aiSeverity: String?
    /// One-sentence report-style observation Claude wrote about the photo
    /// — uses cautious language ("visible", "appears", etc.). Mirrored
    /// from `aiAnalysis.summaryObservation` whenever a new analysis lands
    /// so existing UI surfaces (and the PDF caption row) keep working.
    var aiObservation: String?
    /// Legacy follow-up field from the pre-schema-2 prompt. The new prompt
    /// uses `aiAnalysis.reviewerFlag` for the related concept; this field
    /// is preserved on existing records and is set to nil whenever a new
    /// analysis lands.
    var aiFollowUp: String?
    /// Full structured analysis from the new schema-2 prompt. Optional so
    /// pre-schema-2 manifests (and freshly-imported photos that haven't
    /// been tagged yet) decode without complaint. Once populated it is the
    /// authoritative source for everything beyond raw tags — caption
    /// drafts, recommended use, confidence, reviewer flags, validation
    /// errors, etc.
    var aiAnalysis: AIPhotoAnalysis?
    /// User-confirmed tags (what shows up on the row, in filters, in the PDF).
    /// Each carries a confidence — `1.0` for manually-typed/confirmed tags,
    /// the originating AI score for accepted suggestions. The threshold
    /// slider in Settings filters which of these actually render.
    var tags: [Tag]
    /// AI-generated tag candidates that haven't been confirmed yet. Persisted
    /// so the user can come back later and accept/reject without re-running
    /// the analysis. Empty array (not nil) when none are pending.
    var pendingSuggestions: [TagSuggestion]
    /// Optional reference to a `Bucket` defined on the parent project. nil
    /// means the photo hasn't been categorized; folder export drops those
    /// into a fallback "Unbucketed" folder.
    var bucketID: UUID?
    /// Filename (inside the project's markups folder) of a transparent PNG
    /// overlay drawn by the engineer with PencilKit — arrows, circles,
    /// callouts. Compositied onto the photo in PDF + folder exports. nil
    /// means no markup yet.
    var markupOverlayFilename: String?
    /// Filename of the raw `PKDrawing.dataRepresentation()` (lives next to
    /// the PNG). Preserved so the user can re-edit existing markup; the PNG
    /// alone would lose stroke structure. nil when no markup exists.
    var markupDrawingFilename: String?
    /// When this photo is a re-shoot of an earlier photo at the same spot,
    /// points at the original's `id`. The comparison view follows this chain
    /// to render before/after spreads. nil means this photo is itself a
    /// "root" (or has no reshoots associated yet).
    var reshootsPhotoID: UUID?
    /// User flag for "include this in the headline figures of the report".
    /// Drives a star icon in the photo row and the "Favorites only" chip
    /// in the filter bar. Optional in the export pipelines later.
    var isFavorite: Bool
    /// Timestamp captured when the photo was soft-deleted. Set when the
    /// photo is moved into `Project.trashedPhotos`; cleared on restore.
    /// Used by the 30-day auto-purge sweep in `ProjectStore.purgeOldTrash()`
    /// and to render "Trashed N days ago" in the Trash row.
    var trashedAt: Date?
    /// User-typed caption that overrides `aiAnalysis.captionDraft` when set.
    /// nil = use the AI's draft; empty string = use the AI's draft (treated
    /// the same as nil so deleting all the text reverts to the AI version).
    /// PDF and folder exports prefer this over the AI version when present.
    var userCaption: String?
    /// User-typed observation that overrides `aiAnalysis.summaryObservation`
    /// when set. Same nil/empty semantics as `userCaption`.
    var userObservation: String?

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
        self.aiAnalysis = nil
        self.tags = []
        self.pendingSuggestions = []
        self.bucketID = nil
        self.isFavorite = false
        self.trashedAt = nil
        self.userCaption = nil
        self.userObservation = nil
        self.markupOverlayFilename = nil
        self.markupDrawingFilename = nil
        self.reshootsPhotoID = nil
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
        self.aiAnalysis         = try c.decodeIfPresent(AIPhotoAnalysis.self,
                                                         forKey: .aiAnalysis)
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
        self.bucketID           = try c.decodeIfPresent(UUID.self,
                                                         forKey: .bucketID)
        self.isFavorite         = try c.decodeIfPresent(Bool.self,
                                                         forKey: .isFavorite) ?? false
        self.trashedAt          = try c.decodeIfPresent(Date.self,
                                                         forKey: .trashedAt)
        self.userCaption        = try c.decodeIfPresent(String.self,
                                                         forKey: .userCaption)
        self.userObservation    = try c.decodeIfPresent(String.self,
                                                         forKey: .userObservation)
        self.markupOverlayFilename = try c.decodeIfPresent(String.self,
                                                            forKey: .markupOverlayFilename)
        self.markupDrawingFilename = try c.decodeIfPresent(String.self,
                                                            forKey: .markupDrawingFilename)
        self.reshootsPhotoID       = try c.decodeIfPresent(UUID.self,
                                                            forKey: .reshootsPhotoID)
    }

    /// Caption to show in exports / report surfaces. Prefers the user's
    /// override when set, falls back to the AI's draft, and returns nil
    /// when neither is available.
    var effectiveCaption: String? {
        if let u = userCaption?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
            return u
        }
        let ai = aiAnalysis?.captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (ai?.isEmpty ?? true) ? nil : ai
    }

    /// Observation sentence to show in exports / report surfaces. Prefers
    /// the user's override when set, falls back to the AI's
    /// `summaryObservation`, and returns nil when neither is available.
    var effectiveObservation: String? {
        if let u = userObservation?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
            return u
        }
        let ai = aiAnalysis?.summaryObservation.trimmingCharacters(in: .whitespacesAndNewlines)
        return (ai?.isEmpty ?? true) ? nil : ai
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

// MARK: - AIPhotoAnalysis (schema 2)

/// Full structured response from the schema-2 AI Instructions prompt.
/// Persisted on the photo so the app can render the new UI surfaces
/// (recommended use, confidence, reviewer flag, validation errors), drive
/// the rich batch summary, and let the user revisit the raw response
/// when something looks wrong.
///
/// On a parse failure, the service still constructs an `AIPhotoAnalysis`
/// with empty fields, `parseFailed = true`, and the raw response text in
/// `rawResponse` — the photo is marked but not dropped.
struct AIPhotoAnalysis: Codable, Hashable {
    /// Filename or identifier the model echoed back. Empty when none was
    /// supplied in the user prompt.
    var photoID: String
    /// One or two Primary Tags from the controlled vocabulary.
    var primaryTags: [String]
    /// Map of Primary Tag → array of Secondary Tags under that primary.
    /// `["None"]` is valid and means the photo is contextual under that
    /// primary.
    var secondaryTagsByPrimary: [String: [String]]
    /// Best-guess room/elevation/area from visible cues. "Unknown" when
    /// the model couldn't tell.
    var locationInferred: String
    /// Short phrase explaining what cued the location (e.g. "double oven
    /// and island visible"). "Not determinable" when no cue is visible.
    var orientationCue: String
    /// Yes / Partial / No / unknown — whether a usable scale is present.
    var scalePresent: ScalePresent
    /// Visible measurement transcribed exactly as shown (with units and
    /// sign). Nil when the photo shows no measurement.
    var measurementVisible: String?
    /// One cautious-language sentence about what the photo shows.
    var summaryObservation: String
    /// One short, neutral sentence usable as a figure caption.
    var captionDraft: String
    /// Where this photo belongs in a deliverable.
    var recommendedUse: RecommendedUse
    /// Model's self-assessed confidence in its tag picks.
    var confidence: Confidence
    /// Short clause explaining a Medium / Low rating. Empty for High.
    var confidenceNote: String
    /// Whether the photo looks like a close-up, an overview, or
    /// standalone.
    var likelyCompanion: LikelyCompanion
    /// Short note when the engineer should look at this photo directly.
    /// Empty when nothing flagged.
    var reviewerFlag: String

    /// Validator output — human-readable messages for things like
    /// "secondary X not in vocabulary under primary Y" or "summary
    /// observation contains disallowed phrase 'caused by'". Empty when
    /// the response validates clean.
    var validationErrors: [String]
    /// Raw response text from Claude. Always populated so a user can
    /// revisit what the model actually said.
    var rawResponse: String?
    /// True when the JSON could not be decoded. Other fields will be at
    /// their empty defaults; `rawResponse` carries the offending text.
    var parseFailed: Bool

    /// Empty value used as the "no analysis yet" placeholder when the
    /// service needs to return *something* on a parse failure.
    static let empty = AIPhotoAnalysis(
        photoID: "",
        primaryTags: [],
        secondaryTagsByPrimary: [:],
        locationInferred: "",
        orientationCue: "",
        scalePresent: .unknown(""),
        measurementVisible: nil,
        summaryObservation: "",
        captionDraft: "",
        recommendedUse: .unknown(""),
        confidence: .unknown(""),
        confidenceNote: "",
        likelyCompanion: .unknown(""),
        reviewerFlag: "",
        validationErrors: [],
        rawResponse: nil,
        parseFailed: false
    )

    /// Decode every field optionally so a partial / older payload still
    /// produces a usable struct rather than throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.photoID                = (try? c.decodeIfPresent(String.self, forKey: .photoID)) ?? ""
        self.primaryTags            = (try? c.decodeIfPresent([String].self, forKey: .primaryTags)) ?? []
        self.secondaryTagsByPrimary = (try? c.decodeIfPresent([String: [String]].self, forKey: .secondaryTagsByPrimary)) ?? [:]
        self.locationInferred       = (try? c.decodeIfPresent(String.self, forKey: .locationInferred)) ?? ""
        self.orientationCue         = (try? c.decodeIfPresent(String.self, forKey: .orientationCue)) ?? ""
        self.scalePresent           = (try? c.decodeIfPresent(ScalePresent.self, forKey: .scalePresent)) ?? .unknown("")
        self.measurementVisible     = try? c.decodeIfPresent(String.self, forKey: .measurementVisible)
        self.summaryObservation     = (try? c.decodeIfPresent(String.self, forKey: .summaryObservation)) ?? ""
        self.captionDraft           = (try? c.decodeIfPresent(String.self, forKey: .captionDraft)) ?? ""
        self.recommendedUse         = (try? c.decodeIfPresent(RecommendedUse.self, forKey: .recommendedUse)) ?? .unknown("")
        self.confidence             = (try? c.decodeIfPresent(Confidence.self, forKey: .confidence)) ?? .unknown("")
        self.confidenceNote         = (try? c.decodeIfPresent(String.self, forKey: .confidenceNote)) ?? ""
        self.likelyCompanion        = (try? c.decodeIfPresent(LikelyCompanion.self, forKey: .likelyCompanion)) ?? .unknown("")
        self.reviewerFlag           = (try? c.decodeIfPresent(String.self, forKey: .reviewerFlag)) ?? ""
        self.validationErrors       = (try? c.decodeIfPresent([String].self, forKey: .validationErrors)) ?? []
        self.rawResponse            = try? c.decodeIfPresent(String.self, forKey: .rawResponse)
        self.parseFailed            = (try? c.decodeIfPresent(Bool.self, forKey: .parseFailed)) ?? false
    }

    init(photoID: String,
         primaryTags: [String],
         secondaryTagsByPrimary: [String: [String]],
         locationInferred: String,
         orientationCue: String,
         scalePresent: ScalePresent,
         measurementVisible: String?,
         summaryObservation: String,
         captionDraft: String,
         recommendedUse: RecommendedUse,
         confidence: Confidence,
         confidenceNote: String,
         likelyCompanion: LikelyCompanion,
         reviewerFlag: String,
         validationErrors: [String] = [],
         rawResponse: String? = nil,
         parseFailed: Bool = false) {
        self.photoID = photoID
        self.primaryTags = primaryTags
        self.secondaryTagsByPrimary = secondaryTagsByPrimary
        self.locationInferred = locationInferred
        self.orientationCue = orientationCue
        self.scalePresent = scalePresent
        self.measurementVisible = measurementVisible
        self.summaryObservation = summaryObservation
        self.captionDraft = captionDraft
        self.recommendedUse = recommendedUse
        self.confidence = confidence
        self.confidenceNote = confidenceNote
        self.likelyCompanion = likelyCompanion
        self.reviewerFlag = reviewerFlag
        self.validationErrors = validationErrors
        self.rawResponse = rawResponse
        self.parseFailed = parseFailed
    }
}

// MARK: - Constrained-string enums

/// Marker so all four constrained-string enums can share a `displayName`
/// rendering helper and the `unknown(String)` decode pattern.
protocol ConstrainedStringEnum: Hashable, Codable {
    /// Human-facing label. For known cases this is the canonical spelling;
    /// for `.unknown` it's the raw value the model emitted.
    var displayName: String { get }
    /// True when the model's value matched a known case.
    var isKnown: Bool { get }
}

/// Whether a usable scale reference (ruler, tape, hand, coin) is in the
/// frame. `.unknown(String)` preserves whatever the model emitted when it
/// doesn't match — keeps decoding non-fatal and lets the validator flag
/// the drift.
enum ScalePresent: ConstrainedStringEnum {
    case yes
    case partial
    case no
    case unknown(String)

    var displayName: String {
        switch self {
        case .yes:           return "Yes"
        case .partial:       return "Partial"
        case .no:            return "No"
        case .unknown(let s): return s
        }
    }
    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes":     self = .yes
        case "partial": self = .partial
        case "no":      self = .no
        default:        self = .unknown(raw)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(displayName)
    }
}

/// Where the photo belongs in a deliverable. Drives a colour-coded chip
/// in the photo editor and the per-bucket count in the batch summary.
enum RecommendedUse: ConstrainedStringEnum {
    case bodyFigure
    case appendixOnly
    case contextLocator
    case reshootRecommended
    case unknown(String)

    var displayName: String {
        switch self {
        case .bodyFigure:         return "Body figure"
        case .appendixOnly:       return "Appendix only"
        case .contextLocator:     return "Context/locator"
        case .reshootRecommended: return "Re-shoot recommended"
        case .unknown(let s):     return s
        }
    }
    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "body figure":          self = .bodyFigure
        case "appendix only":        self = .appendixOnly
        case "context/locator",
             "context / locator":    self = .contextLocator
        case "re-shoot recommended",
             "reshoot recommended":  self = .reshootRecommended
        default:                     self = .unknown(raw)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(displayName)
    }

    /// Stable key for use in dictionaries / count buckets — keeps unknown
    /// values distinguishable rather than collapsing them to a single
    /// "Unknown" cell.
    var bucketKey: String {
        switch self {
        case .unknown(let s): return s.isEmpty ? "Unknown" : "Other: \(s)"
        default:              return displayName
        }
    }
}

/// Model's self-assessed confidence in its tag picks (not severity).
enum Confidence: ConstrainedStringEnum {
    case high
    case medium
    case low
    case unknown(String)

    var displayName: String {
        switch self {
        case .high:           return "High"
        case .medium:         return "Medium"
        case .low:            return "Low"
        case .unknown(let s): return s
        }
    }
    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high":   self = .high
        case "medium": self = .medium
        case "low":    self = .low
        default:       self = .unknown(raw)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(displayName)
    }
}

/// Whether the photo looks like a detail shot, a context shot, or a
/// standalone frame.
enum LikelyCompanion: ConstrainedStringEnum {
    case closeUp
    case overview
    case standalone
    case unknown(String)

    var displayName: String {
        switch self {
        case .closeUp:        return "Close-up"
        case .overview:       return "Overview"
        case .standalone:     return "Standalone"
        case .unknown(let s): return s
        }
    }
    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "close-up", "closeup": self = .closeUp
        case "overview":            self = .overview
        case "standalone":          self = .standalone
        default:                    self = .unknown(raw)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(displayName)
    }
}
