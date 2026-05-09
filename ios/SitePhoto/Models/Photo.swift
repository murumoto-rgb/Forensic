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
    /// User-confirmed tags (what shows up on the row, in filters, in the PDF).
    /// Stored verbatim — display case is preserved — but compared
    /// case-insensitively for dedup. Trimmed of leading/trailing whitespace.
    var tags: [String]
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
        self.tags               = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.pendingSuggestions = try c.decodeIfPresent([TagSuggestion].self,
                                                        forKey: .pendingSuggestions) ?? []
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

    var id: String { "\(source.rawValue):\(label.lowercased())" }
}

enum TagSource: String, Codable, Hashable {
    /// On-device Apple Vision (`VNClassifyImageRequest`). Generic and free.
    case vision
    /// Cloud Claude vision call. Forensic-aware but requires an API key.
    case claude
}
