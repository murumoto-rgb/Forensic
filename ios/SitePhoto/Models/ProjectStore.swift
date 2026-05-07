import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []

    private let fileManager = FileManager.default

    var rootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appending(path: "Projects", directoryHint: .isDirectory)
    }

    init() {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        load()
    }

    func projectURL(_ project: Project) -> URL {
        rootURL.appending(path: project.id.uuidString, directoryHint: .isDirectory)
    }

    func photosFolder(for project: Project) -> URL {
        projectURL(project).appending(path: "photos", directoryHint: .isDirectory)
    }

    func manifestURL(for project: Project) -> URL {
        projectURL(project).appending(path: "manifest.json")
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    func load() {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            projects = []
            return
        }
        var loaded: [Project] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let manifest = dir.appending(path: "manifest.json")
            guard let data = try? Data(contentsOf: manifest) else { continue }
            do {
                let project = try decoder().decode(Project.self, from: data)
                loaded.append(project)
            } catch {
                #if DEBUG
                print("Failed to decode project at \(manifest.path): \(error)")
                #endif
            }
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ project: Project) -> Project {
        let dir = projectURL(project)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: photosFolder(for: project), withIntermediateDirectories: true)
        do {
            let data = try encoder().encode(project)
            try data.write(to: manifestURL(for: project), options: .atomic)
        } catch {
            #if DEBUG
            print("Failed to save project: \(error)")
            #endif
        }
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        } else {
            projects.insert(project, at: 0)
        }
        return project
    }

    func delete(_ project: Project) {
        let dir = projectURL(project)
        try? fileManager.removeItem(at: dir)
        projects.removeAll { $0.id == project.id }
    }

    func project(withID id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    // MARK: - Session lifecycle

    @discardableResult
    func startSession(_ project: Project) -> Project {
        var p = project
        if p.startedAt == nil {
            p.startedAt = Date()
        } else {
            p.lastResumedAt = Date()
        }
        p.stopped = false
        return save(p)
    }

    @discardableResult
    func stopSession(_ project: Project) -> Project {
        var p = project
        p.stopped = true
        p.lastStoppedAt = Date()
        return save(p)
    }

    @discardableResult
    func updateGPS(_ project: Project, _ gps: ProjectGPS) -> Project {
        var p = project
        p.projectGPS = gps
        return save(p)
    }

    @discardableResult
    func updateAddress(_ project: Project, _ address: String) -> Project {
        var p = project
        p.projectAddress = address
        return save(p)
    }

    // MARK: - Floor plan

    @discardableResult
    func saveFloorPlan(
        to project: Project,
        imageData: Data,
        anchorPixelX: Double,
        anchorPixelY: Double,
        pixelsPerFoot: Double,
        calibrationDistanceFeet: Double,
        northDeg: Double
    ) throws -> Project {
        var p = project
        let dir = projectURL(p)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        // Replace any existing plan image.
        let filename = "plan.jpg"
        let url = dir.appending(path: filename)
        try? fileManager.removeItem(at: url)
        try imageData.write(to: url, options: .atomic)

        p.floorPlan = FloorPlan(
            imageFilename: filename,
            pixelsPerFoot: pixelsPerFoot,
            calibrationDistanceFeet: calibrationDistanceFeet,
            anchorPixelX: anchorPixelX,
            anchorPixelY: anchorPixelY,
            anchorLocalXFeet: 0,
            anchorLocalYFeet: 0,
            northDeg: northDeg
        )
        return save(p)
    }

    @discardableResult
    func clearFloorPlan(_ project: Project) -> Project {
        var p = project
        if let plan = p.floorPlan {
            let url = projectURL(p).appending(path: plan.imageFilename)
            try? fileManager.removeItem(at: url)
        }
        p.floorPlan = nil
        return save(p)
    }

    func floorPlanURL(for project: Project) -> URL? {
        guard let plan = project.floorPlan else { return nil }
        return projectURL(project).appending(path: plan.imageFilename)
    }

    /// Move the origin (anchorPixelX/Y) to a new spot on the current plan image.
    /// Photo planPixelX/Y stay put (visually nothing changes); localXFeet/Y are
    /// re-derived against the new origin.
    @discardableResult
    func updateFloorPlanOrigin(_ project: Project,
                               anchorPixelX: Double,
                               anchorPixelY: Double) -> Project {
        var p = project
        guard var plan = p.floorPlan else { return p }
        plan.anchorPixelX = anchorPixelX
        plan.anchorPixelY = anchorPixelY
        p.floorPlan = plan
        Self.recomputeLocalCoords(in: &p)
        return save(p)
    }

    /// Set the north direction (degrees clockwise from image up).
    @discardableResult
    func updateFloorPlanNorth(_ project: Project, northDeg: Double) -> Project {
        var p = project
        guard var plan = p.floorPlan else { return p }
        plan.northDeg = northDeg
        p.floorPlan = plan
        return save(p)
    }

    /// Replace the plan image with new calibration + origin. Photo planPixelX/Y
    /// are recomputed from each photo's localXFeet/Y so they land in the same
    /// physical place on the new image. Old plan image is deleted.
    @discardableResult
    func replaceFloorPlan(in project: Project,
                          imageData: Data,
                          pixelsPerFoot: Double,
                          calibrationDistanceFeet: Double,
                          anchorPixelX: Double,
                          anchorPixelY: Double,
                          northDeg: Double) throws -> Project {
        var p = project

        // Make sure local coords are fresh against the OLD calibration before
        // we swap. If the user never set an origin, this writes whatever the
        // current anchor implies; it's still self-consistent.
        Self.recomputeLocalCoords(in: &p)

        let dir = projectURL(p)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "plan.jpg"
        let url = dir.appending(path: filename)
        try? fileManager.removeItem(at: url)
        try imageData.write(to: url, options: .atomic)

        p.floorPlan = FloorPlan(
            imageFilename: filename,
            pixelsPerFoot: pixelsPerFoot,
            calibrationDistanceFeet: calibrationDistanceFeet,
            anchorPixelX: anchorPixelX,
            anchorPixelY: anchorPixelY,
            anchorLocalXFeet: 0,
            anchorLocalYFeet: 0,
            northDeg: northDeg
        )

        // Project photo positions onto the new plan.
        Self.recomputePixelCoords(in: &p)

        return save(p)
    }

    /// Derive each photo's localXFeet/Y from its planPixelX/Y using the current calibration.
    private static func recomputeLocalCoords(in project: inout Project) {
        guard let plan = project.floorPlan else { return }
        for i in project.photos.indices {
            let photo = project.photos[i]
            guard let px = photo.planPixelX, let py = photo.planPixelY else { continue }
            project.photos[i].localXFeet = (px - plan.anchorPixelX) / plan.pixelsPerFoot
            project.photos[i].localYFeet = (py - plan.anchorPixelY) / plan.pixelsPerFoot
        }
    }

    /// Derive each photo's planPixelX/Y from its localXFeet/Y using the current calibration.
    private static func recomputePixelCoords(in project: inout Project) {
        guard let plan = project.floorPlan else { return }
        for i in project.photos.indices {
            let photo = project.photos[i]
            guard let lx = photo.localXFeet, let ly = photo.localYFeet else { continue }
            project.photos[i].planPixelX = plan.anchorPixelX + lx * plan.pixelsPerFoot
            project.photos[i].planPixelY = plan.anchorPixelY + ly * plan.pixelsPerFoot
        }
    }

    // MARK: - Photos

    /// Optional location data attached when a photo is saved against a calibrated plan.
    struct PhotoLocation {
        var planPixelX: Double
        var planPixelY: Double
        var localXFeet: Double
        var localYFeet: Double
        var headingDegrees: Double?
        var groupID: UUID?
        var isPrimary: Bool
    }

    /// Persist a captured photo to disk and append it to the project. Returns the updated project.
    @discardableResult
    func addPhoto(to project: Project, captured: CapturedPhoto, location: PhotoLocation? = nil) throws -> Project {
        var p = project
        let folder = photosFolder(for: p)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let photoID = UUID()
        let imageName = "photo_\(photoID.uuidString).jpg"
        let imageURL = folder.appending(path: imageName)
        try captured.data.write(to: imageURL, options: .atomic)

        var thumbName: String?
        if let thumb = Self.makeThumbnail(from: captured.data, maxPixelSize: 256) {
            let n = "thumb_\(photoID.uuidString).jpg"
            let url = folder.appending(path: n)
            try? thumb.write(to: url, options: .atomic)
            thumbName = n
        }

        var photo = Photo(id: photoID,
                          sequenceNumber: p.photos.count + 1,
                          imageFilename: imageName)
        photo.thumbnailFilename = thumbName
        photo.cameraZoom = captured.userZoom
        photo.lensName = captured.lensName
        photo.flashMode = captured.flashMode

        if let loc = location {
            photo.planPixelX = loc.planPixelX
            photo.planPixelY = loc.planPixelY
            photo.localXFeet = loc.localXFeet
            photo.localYFeet = loc.localYFeet
            photo.headingDegrees = loc.headingDegrees
            photo.groupID = loc.groupID
            photo.isPrimary = loc.isPrimary
            photo.positionSource = .manual
        }

        p.photos.append(photo)
        return save(p)
    }

    func imageURL(for photo: Photo, in project: Project) -> URL {
        photosFolder(for: project).appending(path: photo.imageFilename)
    }

    func thumbnailURL(for photo: Photo, in project: Project) -> URL? {
        guard let name = photo.thumbnailFilename else { return nil }
        return photosFolder(for: project).appending(path: name)
    }

    private static func makeThumbnail(from imageData: Data, maxPixelSize: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }

        // Redraw into an opaque context so the resulting JPEG has no alpha
        // channel - avoids ImageIO's "saving opaque image with AlphaPremulLast"
        // warning and halves the in-memory footprint when the thumbnail is
        // decoded for display.
        let width = cg.width
        let height = cg.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let opaque = ctx.makeImage() else { return nil }

        let mut = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mut, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let writeOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(dest, opaque, writeOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mut as Data
    }
}
