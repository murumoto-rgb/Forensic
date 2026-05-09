import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var startedAt: Date?
    var lastResumedAt: Date?
    var lastStoppedAt: Date?
    var stopped: Bool
    var projectGPS: ProjectGPS?
    var projectAddress: String?
    var photos: [Photo]
    var floorPlan: FloorPlan?
    /// Stable, human-readable folder name used on disk. Computed once at
    /// creation; nil only on projects created before this field existed.
    var folderName: String?
    /// Optional per-project tagging guide that gets injected into Claude's
    /// system prompt. `nil` means use the app-wide default
    /// (`AIInstructions.default`). Empty string means the user explicitly
    /// disabled custom instructions.
    var aiInstructions: String?
    /// User-defined categories for grouping photos in this project. Each
    /// `Photo.bucketID` references one of these (or nil). Folder export
    /// renders one directory per bucket in `sortOrder`. Empty by default —
    /// the user opts in by creating buckets via the manager sheet.
    var buckets: [Bucket]

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.startedAt = nil
        self.lastResumedAt = nil
        self.lastStoppedAt = nil
        self.stopped = false
        self.projectGPS = nil
        self.projectAddress = nil
        self.photos = []
        self.floorPlan = nil
        self.folderName = Self.makeFolderName(id: id, name: name, createdAt: self.createdAt)
        self.aiInstructions = nil
        self.buckets = []
    }

    /// Tolerate manifests written before `aiInstructions` existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self,            forKey: .id)
        self.name            = try c.decode(String.self,          forKey: .name)
        self.createdAt       = try c.decode(Date.self,            forKey: .createdAt)
        self.startedAt       = try c.decodeIfPresent(Date.self,   forKey: .startedAt)
        self.lastResumedAt   = try c.decodeIfPresent(Date.self,   forKey: .lastResumedAt)
        self.lastStoppedAt   = try c.decodeIfPresent(Date.self,   forKey: .lastStoppedAt)
        self.stopped         = try c.decode(Bool.self,            forKey: .stopped)
        self.projectGPS      = try c.decodeIfPresent(ProjectGPS.self, forKey: .projectGPS)
        self.projectAddress  = try c.decodeIfPresent(String.self, forKey: .projectAddress)
        self.photos          = try c.decode([Photo].self,         forKey: .photos)
        self.floorPlan       = try c.decodeIfPresent(FloorPlan.self, forKey: .floorPlan)
        self.folderName      = try c.decodeIfPresent(String.self, forKey: .folderName)
        self.aiInstructions  = try c.decodeIfPresent(String.self, forKey: .aiInstructions)
        self.buckets         = try c.decodeIfPresent([Bucket].self, forKey: .buckets) ?? []
    }

    var isActive: Bool { startedAt != nil && !stopped }
    var hasBeenStarted: Bool { startedAt != nil }

    /// The instructions actually fed to Claude — falls back to the app-wide
    /// default when the project hasn't been customised.
    var effectiveAIInstructions: String {
        if let s = aiInstructions, !s.isEmpty { return s }
        return AIInstructions.defaultText
    }

    /// True when the project is using whatever the user typed into the
    /// instructions editor (not the bundled default). Drives a "Customised"
    /// badge in the UI.
    var hasCustomAIInstructions: Bool {
        guard let s = aiInstructions, !s.isEmpty else { return false }
        return s != AIInstructions.defaultText
    }

    static func makeFolderName(id: UUID, name: String, createdAt: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        let dateStr = dateFormatter.string(from: createdAt)

        let cleaned = name
            .replacingOccurrences(of: "[^A-Za-z0-9 -]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let dashed = cleaned.replacingOccurrences(of: " +", with: "-", options: .regularExpression)
        let safe = String(dashed.prefix(40))
        let body = safe.isEmpty ? "project" : safe
        let idPrefix = String(id.uuidString.lowercased().prefix(6))
        return "\(dateStr)_\(body)_\(idPrefix)"
    }
}

struct ProjectGPS: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var accuracyFeet: Double?
    var timestamp: Date
}

struct FloorPlan: Codable, Hashable {
    var imageFilename: String
    var pixelsPerFoot: Double
    var calibrationDistanceFeet: Double
    var anchorPixelX: Double
    var anchorPixelY: Double
    var anchorLocalXFeet: Double
    var anchorLocalYFeet: Double
    var northDeg: Double
}
