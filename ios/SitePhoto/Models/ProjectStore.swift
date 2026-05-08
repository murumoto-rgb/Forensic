import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private(set) var usingICloud: Bool = false
    /// Human-readable explanation for why iCloud isn't being used (nil when it is).
    private(set) var iCloudUnavailableReason: String?

    private let fileManager = FileManager.default
    private let storageRoot: URL

    var rootURL: URL { storageRoot }

    init() {
        let local = Self.localProjectsURL
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        var iCloudProjectsURL: URL?
        var unavailableReason: String?

        // url(forUbiquityContainerIdentifier:) blocks the first time iCloud is
        // probed but is fast on subsequent calls. Doing it inline at startup is
        // acceptable - the launch screen masks any short delay.
        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let docs = containerURL.appending(path: "Documents", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let projects = docs.appending(path: "Projects", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            iCloudProjectsURL = projects
        } else {
            unavailableReason = "iCloud Drive isn't enabled. Open Settings → Apple ID → iCloud → iCloud Drive and turn it on (and SitePhoto inside the app list) to back projects up to iCloud."
        }

        if let iCloud = iCloudProjectsURL {
            // Migrate any existing local projects to iCloud on first launch
            // with iCloud available. Each project's UUID-named folder is moved
            // intact (manifest, photos, plan).
            Self.migrateProjects(from: local, to: iCloud)
            self.storageRoot = iCloud
            self.usingICloud = true
            self.iCloudUnavailableReason = nil
        } else {
            self.storageRoot = local
            self.usingICloud = false
            self.iCloudUnavailableReason = unavailableReason
        }

        load()
    }

    private static var localProjectsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Projects", directoryHint: .isDirectory)
    }

    /// Move every project folder from `src` to `dst`. If a folder with the
    /// same name already exists in `dst` (e.g. a previous partial migration),
    /// skip it - the iCloud copy is treated as authoritative.
    private static func migrateProjects(from src: URL, to dst: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path()) else { return }
        guard let entries = try? fm.contentsOfDirectory(at: src,
                                                        includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let destEntry = dst.appending(path: entry.lastPathComponent, directoryHint: .isDirectory)
            if fm.fileExists(atPath: destEntry.path()) {
                // Already there from a previous run; remove the local copy
                // since iCloud is now the source of truth.
                try? fm.removeItem(at: entry)
                continue
            }
            do {
                try fm.copyItem(at: entry, to: destEntry)
                // Verify the manifest came through before deleting the source.
                let manifestExists = fm.fileExists(
                    atPath: destEntry.appending(path: "manifest.json").path()
                )
                if manifestExists {
                    try fm.removeItem(at: entry)
                }
            } catch {
                #if DEBUG
                print("iCloud migration failed for \(entry.lastPathComponent): \(error)")
                #endif
            }
        }
    }

    func projectURL(_ project: Project) -> URL {
        let folderName = project.folderName
            ?? Project.makeFolderName(id: project.id, name: project.name, createdAt: project.createdAt)
        return rootURL.appending(path: folderName, directoryHint: .isDirectory)
    }

    func photosFolder(for project: Project) -> URL {
        projectURL(project).appending(path: "photos", directoryHint: .isDirectory)
    }

    func thumbnailsFolder(for project: Project) -> URL {
        projectURL(project).appending(path: "thumbnails", directoryHint: .isDirectory)
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
                var project = try decoder().decode(Project.self, from: data)
                // Migrate: project predates folderName field, or its folder is
                // not at the canonical location.
                let canonicalName = Project.makeFolderName(
                    id: project.id,
                    name: project.name,
                    createdAt: project.createdAt
                )
                let actualName = dir.lastPathComponent
                let canonicalDir = rootURL.appending(path: canonicalName, directoryHint: .isDirectory)
                if actualName != canonicalName {
                    if !fileManager.fileExists(atPath: canonicalDir.path()) {
                        do {
                            try fileManager.moveItem(at: dir, to: canonicalDir)
                            project.folderName = canonicalName
                            // Re-write the manifest with the new folderName.
                            let manifestNew = canonicalDir.appending(path: "manifest.json")
                            if let bytes = try? encoder().encode(project) {
                                try? bytes.write(to: manifestNew, options: .atomic)
                            }
                        } catch {
                            #if DEBUG
                            print("Folder rename failed for \(actualName): \(error)")
                            #endif
                            project.folderName = actualName
                        }
                    } else {
                        project.folderName = actualName
                    }
                } else if project.folderName != canonicalName {
                    project.folderName = canonicalName
                }

                migrateThumbnailLocation(for: project)
                migratePhotoFilenames(for: &project)
                loaded.append(project)
            } catch {
                #if DEBUG
                print("Failed to decode project at \(manifest.path): \(error)")
                #endif
            }
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    /// Move any thumb_*.jpg files that historically lived inside photos/ into
    /// the new thumbnails/ subfolder so the photos folder is just full-res
    /// JPEGs.
    private func migrateThumbnailLocation(for project: Project) {
        let photos = photosFolder(for: project)
        let thumbs = thumbnailsFolder(for: project)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: photos,
            includingPropertiesForKeys: nil
        ) else { return }
        var moved = 0
        for entry in entries where entry.lastPathComponent.hasPrefix("thumb_") {
            if moved == 0 {
                try? fileManager.createDirectory(at: thumbs, withIntermediateDirectories: true)
            }
            let dest = thumbs.appending(path: entry.lastPathComponent)
            if !fileManager.fileExists(atPath: dest.path()) {
                try? fileManager.moveItem(at: entry, to: dest)
            } else {
                try? fileManager.removeItem(at: entry)
            }
            moved += 1
        }
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
        // Remove every folder whose manifest carries this project's id, in
        // both the active root (iCloud or local) AND the legacy local root
        // when running on iCloud. The legacy cleanup is what prevents the
        // local→iCloud migration from re-resurrecting a deleted project on
        // the next launch.
        deleteAllFolders(forID: project.id, under: rootURL)
        if usingICloud {
            deleteAllFolders(forID: project.id, under: Self.localProjectsURL)
        }
        projects.removeAll { $0.id == project.id }
    }

    private func deleteAllFolders(forID id: UUID, under root: URL) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let manifest = entry.appending(path: "manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let project = try? decoder().decode(Project.self, from: data),
                  project.id == id else { continue }
            deleteCoordinated(at: entry)
        }
    }

    /// Use NSFileCoordinator for the actual remove so the iCloud daemon
    /// registers the delete properly and won't restore the folder.
    private func deleteCoordinated(at url: URL) {
        guard fileManager.fileExists(atPath: url.path()) else { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { newURL in
            do {
                try fileManager.removeItem(at: newURL)
            } catch {
                #if DEBUG
                print("removeItem failed at \(newURL.path()): \(error)")
                #endif
            }
        }
        if let coordError {
            #if DEBUG
            print("file coordination failed for \(url.path()): \(coordError)")
            #endif
        }
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

    /// Re-calibrate the scale (pixelsPerFoot / calibrationDistanceFeet) without
    /// touching the plan image or origin. Photo planPixelX/Y stay put -
    /// visually nothing changes - and localXFeet/Y are re-derived so the
    /// readouts match the new scale.
    @discardableResult
    func recalibrateScale(_ project: Project,
                          pixelsPerFoot: Double,
                          calibrationDistanceFeet: Double) -> Project {
        var p = project
        guard var plan = p.floorPlan else { return p }
        plan.pixelsPerFoot = pixelsPerFoot
        plan.calibrationDistanceFeet = calibrationDistanceFeet
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
        let photosFolder = photosFolder(for: p)
        let thumbsFolder = thumbnailsFolder(for: p)
        try fileManager.createDirectory(at: photosFolder, withIntermediateDirectories: true)

        let photoID = UUID()
        let seq = p.photos.count + 1
        let now = Date()
        let imageName = Self.makePhotoFilename(sequenceNumber: seq, timestamp: now, projectName: p.name)
        let imageURL = photosFolder.appending(path: imageName)
        try captured.data.write(to: imageURL, options: .atomic)

        var thumbName: String?
        if let thumb = Self.makeThumbnail(from: captured.data, maxPixelSize: 256) {
            try? fileManager.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)
            let n = "thumb_\(imageName)"
            let url = thumbsFolder.appending(path: n)
            try? thumb.write(to: url, options: .atomic)
            thumbName = n
        }

        var photo = Photo(id: photoID, sequenceNumber: seq, imageFilename: imageName)
        photo.timestamp = now
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
        return thumbnailsFolder(for: project).appending(path: name)
    }

    // MARK: - iCloud-aware loading

    /// Read the bytes at `url`, ensuring an iCloud Drive placeholder is downloaded
    /// first if necessary. Returns nil if the file isn't there or download
    /// times out.
    func loadFileBytes(at url: URL, timeoutSeconds: Double = 30) async -> Data? {
        await ensureDownloaded(url, timeoutSeconds: timeoutSeconds)
        return try? Data(contentsOf: url)
    }

    /// If `url` is an iCloud-backed item that hasn't been downloaded to this
    /// device, request a download and wait until it lands.
    func ensureDownloaded(_ url: URL, timeoutSeconds: Double = 30) async {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus == .current { return }

        try? fileManager.startDownloadingUbiquitousItem(at: url)
        let stepMillis: UInt64 = 250
        let total = max(1, Int(timeoutSeconds * 1000) / Int(stepMillis))
        for _ in 0..<total {
            try? await Task.sleep(nanoseconds: stepMillis * 1_000_000)
            if let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               v.ubiquitousItemDownloadingStatus == .current {
                return
            }
        }
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

    // MARK: - Photo filename scheme

    /// "Project Name - 3 - 260508 14-30-22.jpg"
    /// Colons replaced with hyphens (invalid in file names on iOS/macOS).
    static func makePhotoFilename(sequenceNumber: Int, timestamp: Date, projectName: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyMMdd HH-mm-ss"
        fmt.timeZone = TimeZone.current
        let dateStr = fmt.string(from: timestamp)
        let safe = projectName
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let body = String(safe.prefix(30)).isEmpty ? "project" : String(safe.prefix(30))
        return "\(body) - \(sequenceNumber) - \(dateStr).jpg"
    }

    /// Rename any photos whose filenames still use the old "photo_<UUID>.jpg" scheme.
    private func migratePhotoFilenames(for project: inout Project) {
        let photosDir = photosFolder(for: project)
        let thumbsDir = thumbnailsFolder(for: project)
        var changed = false

        for i in project.photos.indices {
            let photo = project.photos[i]
            guard photo.imageFilename.hasPrefix("photo_") else { continue }

            let newImageName = Self.makePhotoFilename(
                sequenceNumber: photo.sequenceNumber,
                timestamp: photo.timestamp,
                projectName: project.name
            )
            let oldURL = photosDir.appending(path: photo.imageFilename)
            let newURL = photosDir.appending(path: newImageName)
            if fileManager.fileExists(atPath: oldURL.path()) &&
               !fileManager.fileExists(atPath: newURL.path()) {
                try? fileManager.moveItem(at: oldURL, to: newURL)
            }
            project.photos[i].imageFilename = newImageName
            changed = true

            if let oldThumb = photo.thumbnailFilename {
                let newThumbName = "thumb_\(newImageName)"
                let oldThumbURL = thumbsDir.appending(path: oldThumb)
                let newThumbURL = thumbsDir.appending(path: newThumbName)
                if fileManager.fileExists(atPath: oldThumbURL.path()) &&
                   !fileManager.fileExists(atPath: newThumbURL.path()) {
                    try? fileManager.moveItem(at: oldThumbURL, to: newThumbURL)
                }
                project.photos[i].thumbnailFilename = newThumbName
            }
        }

        if changed, let data = try? encoder().encode(project) {
            try? data.write(to: manifestURL(for: project), options: .atomic)
        }
    }
}
