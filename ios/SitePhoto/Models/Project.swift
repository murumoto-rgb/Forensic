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
    }

    var isActive: Bool { startedAt != nil && !stopped }
    var hasBeenStarted: Bool { startedAt != nil }

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
