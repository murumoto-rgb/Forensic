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
