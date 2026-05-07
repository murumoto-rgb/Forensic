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
    }

    var isActive: Bool { startedAt != nil && !stopped }
    var hasBeenStarted: Bool { startedAt != nil }
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
