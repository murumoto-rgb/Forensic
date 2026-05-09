import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@Observable
final class ProjectStore {
    private(set) var activeProjects: [Project] = []
    private(set) var deletedProjects: [Project] = []
    private(set) var usingICloud: Bool = false
    /// Human-readable explanation for why iCloud isn't being used (nil when it is).
    private(set) var iCloudUnavailableReason: String?
    /// True once `loadInitial()` has finished — the App scene's splash
    /// keeps showing until this flips, so the slow first-launch iCloud
    /// probe doesn't push the splash render back behind a blank screen.
    private(set) var isReady: Bool = false

    private let fileManager = FileManager.default
    /// Mutated once during `loadInitial()` when the iCloud probe finishes.
    /// Defaults to local while loadInitial is in flight so the rest of the
    /// API never has a nil rootURL to deal with.
    private var storageRoot: URL

    var rootURL: URL { storageRoot }

    /// "Active Projects" subfolder — projects shown in the main list.
    var activeRoot: URL {
        storageRoot.appending(path: Self.activeFolderName, directoryHint: .isDirectory)
    }

    /// "Deleted Projects" subfolder — soft-deleted projects, recoverable
    /// until permanently deleted.
    var deletedRoot: URL {
        storageRoot.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
    }

    static let activeFolderName  = "Active Projects"
    static let deletedFolderName = "Deleted Projects"

    /// Fast init — only sets up the local storage root. The slow iCloud
    /// probe + project load is in `loadInitial()` so the splash screen can
    /// render immediately and the user doesn't see a 1–3-second white
    /// pause before any UI appears.
    init() {
        let local = Self.localProjectsURL
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        Self.ensureSubfolders(in: local)
        self.storageRoot = local
    }

    /// Async setup: probe iCloud (slow on cold launch), promote storageRoot
    /// to iCloud if available, run the local→iCloud migration, then load
    /// projects. Safe to call multiple times — guarded by `isReady`.
    @MainActor
    func loadInitial() async {
        guard !isReady else { return }

        // The iCloud-container probe is the dominant cost on first launch
        // (sometimes 1–3 s while iOS sets up the container). Run it on a
        // background task so the main actor stays free to render the
        // splash screen.
        let iCloudURL: URL? = await Task.detached {
            guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                return nil
            }
            let docs = containerURL.appending(path: "Documents", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let projects = docs.appending(path: "Projects", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            return projects
        }.value

        if let iCloud = iCloudURL {
            self.storageRoot = iCloud
            self.usingICloud = true
            self.iCloudUnavailableReason = nil
        } else {
            self.usingICloud = false
            self.iCloudUnavailableReason = "iCloud Drive isn't enabled. Open Settings → Apple ID → iCloud → iCloud Drive and turn it on (and SitePhoto inside the app list) to back projects up to iCloud."
        }

        Self.ensureSubfolders(in: storageRoot)

        // Defensive only: copies any project folders the user created in
        // local storage (because iCloud was offline) up to iCloud now that
        // it's available. Fast no-op when local is empty.
        if usingICloud {
            let local = Self.localProjectsURL
            let activeLocal   = local.appending(path: Self.activeFolderName,  directoryHint: .isDirectory)
            let activeICloud  = storageRoot.appending(path: Self.activeFolderName,  directoryHint: .isDirectory)
            let deletedLocal  = local.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
            let deletedICloud = storageRoot.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
            await Task.detached {
                Self.migrateProjects(from: activeLocal,  to: activeICloud)
                Self.migrateProjects(from: deletedLocal, to: deletedICloud)
            }.value
        }

        load()
        isReady = true
    }

    private static var localProjectsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Projects", directoryHint: .isDirectory)
    }

    private static func ensureSubfolders(in root: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: root.appending(path: activeFolderName, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try? fm.createDirectory(
            at: root.appending(path: deletedFolderName, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
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
        let root = isDeleted(project) ? deletedRoot : activeRoot
        return root.appending(path: folderName, directoryHint: .isDirectory)
    }

    private func isDeleted(_ project: Project) -> Bool {
        deletedProjects.contains { $0.id == project.id }
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
        activeProjects = loadProjects(in: activeRoot)
        deletedProjects = loadProjects(in: deletedRoot)
    }

    /// Walks one root (Active Projects or Deleted Projects) and decodes
    /// each manifest. Trusts the on-disk folder name as the canonical
    /// folderName for each project — no rename is performed.
    private func loadProjects(in root: URL) -> [Project] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        var loaded: [Project] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let manifest = dir.appending(path: "manifest.json")
            guard let data = try? Data(contentsOf: manifest) else { continue }
            do {
                var project = try decoder().decode(Project.self, from: data)
                // Defend against in-memory drift between project.folderName
                // and the actual folder name on disk: trust the folder name.
                let actualName = dir.lastPathComponent
                if project.folderName != actualName {
                    project.folderName = actualName
                }
                loaded.append(project)
            } catch {
                #if DEBUG
                print("Failed to decode project at \(manifest.path): \(error)")
                #endif
            }
        }
        return loaded.sorted { $0.createdAt > $1.createdAt }
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
        // Keep existing projects in their current list; new projects go into
        // Active Projects.
        if let idx = activeProjects.firstIndex(where: { $0.id == project.id }) {
            activeProjects[idx] = project
        } else if let idx = deletedProjects.firstIndex(where: { $0.id == project.id }) {
            deletedProjects[idx] = project
        } else {
            activeProjects.insert(project, at: 0)
        }
        return project
    }

    /// Soft delete: move the project's folder from "Active Projects" to
    /// "Deleted Projects" so the data stays available for recovery. The
    /// permanent purge happens in `permanentlyDelete(_)`.
    func delete(_ project: Project) {
        let idPrefix = String(project.id.uuidString.lowercased().prefix(6))
        let fullUUID = project.id.uuidString.lowercased()

        moveMatchingFolders(idPrefix: idPrefix, fullUUID: fullUUID,
                            from: activeRoot, to: deletedRoot)
        if usingICloud {
            moveMatchingFolders(
                idPrefix: idPrefix, fullUUID: fullUUID,
                from: Self.localProjectsURL.appending(path: Self.activeFolderName, directoryHint: .isDirectory),
                to:   Self.localProjectsURL.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
            )
        }

        activeProjects.removeAll { $0.id == project.id }
        if !deletedProjects.contains(where: { $0.id == project.id }) {
            deletedProjects.insert(project, at: 0)
        }
    }

    /// Restore a soft-deleted project — move its folder from "Deleted
    /// Projects" back to "Active Projects".
    func restore(_ project: Project) {
        let idPrefix = String(project.id.uuidString.lowercased().prefix(6))
        let fullUUID = project.id.uuidString.lowercased()

        moveMatchingFolders(idPrefix: idPrefix, fullUUID: fullUUID,
                            from: deletedRoot, to: activeRoot)
        if usingICloud {
            moveMatchingFolders(
                idPrefix: idPrefix, fullUUID: fullUUID,
                from: Self.localProjectsURL.appending(path: Self.deletedFolderName, directoryHint: .isDirectory),
                to:   Self.localProjectsURL.appending(path: Self.activeFolderName, directoryHint: .isDirectory)
            )
        }

        deletedProjects.removeAll { $0.id == project.id }
        if !activeProjects.contains(where: { $0.id == project.id }) {
            activeProjects.insert(project, at: 0)
        }
    }

    /// Permanently remove every folder for this project — from both
    /// Active/Deleted in the active root and the legacy local root.
    func permanentlyDelete(_ project: Project) {
        let idPrefix = String(project.id.uuidString.lowercased().prefix(6))
        let fullUUID = project.id.uuidString.lowercased()

        removeMatchingFolders(idPrefix: idPrefix, fullUUID: fullUUID, under: activeRoot)
        removeMatchingFolders(idPrefix: idPrefix, fullUUID: fullUUID, under: deletedRoot)
        if usingICloud {
            removeMatchingFolders(
                idPrefix: idPrefix, fullUUID: fullUUID,
                under: Self.localProjectsURL.appending(path: Self.activeFolderName, directoryHint: .isDirectory)
            )
            removeMatchingFolders(
                idPrefix: idPrefix, fullUUID: fullUUID,
                under: Self.localProjectsURL.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
            )
        }

        activeProjects.removeAll { $0.id == project.id }
        deletedProjects.removeAll { $0.id == project.id }
    }

    private func moveMatchingFolders(idPrefix: String, fullUUID: String,
                                      from src: URL, to dst: URL) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: src,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        try? fileManager.createDirectory(at: dst, withIntermediateDirectories: true)

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let nameLower = entry.lastPathComponent.lowercased()
            guard nameLower.hasSuffix("_\(idPrefix)") || nameLower == fullUUID else { continue }
            let target = dst.appending(path: entry.lastPathComponent, directoryHint: .isDirectory)
            coordinatedMove(from: entry, to: target)
        }
    }

    private func removeMatchingFolders(idPrefix: String, fullUUID: String, under root: URL) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let nameLower = entry.lastPathComponent.lowercased()
            guard nameLower.hasSuffix("_\(idPrefix)") || nameLower == fullUUID else { continue }
            coordinatedRemove(entry)
        }
    }

    /// File-coordinated move (for iCloud safety). If a folder already exists
    /// at the destination it is removed first so the move can proceed.
    private func coordinatedMove(from src: URL, to dst: URL) {
        if fileManager.fileExists(atPath: dst.path()) {
            coordinatedRemove(dst)
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(
            writingItemAt: src, options: .forMoving,
            writingItemAt: dst, options: .forReplacing,
            error: &coordError
        ) { newSrc, newDst in
            do {
                try fileManager.moveItem(at: newSrc, to: newDst)
            } catch {
                #if DEBUG
                print("coordinated move failed \(newSrc.lastPathComponent) → \(newDst.lastPathComponent): \(error)")
                #endif
            }
        }
        if let coordError {
            #if DEBUG
            print("move coordination failed for \(src.lastPathComponent): \(coordError)")
            #endif
            try? fileManager.moveItem(at: src, to: dst)
        }
    }

    /// Use NSFileCoordinator so the iCloud sync daemon registers the delete
    /// and won't push the folder back. Falls back to a direct remove if
    /// coordination itself fails.
    private func coordinatedRemove(_ url: URL) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { newURL in
            do {
                try fileManager.removeItem(at: newURL)
            } catch {
                #if DEBUG
                print("coordinated removeItem failed at \(newURL.lastPathComponent): \(error)")
                #endif
            }
        }
        if let coordError {
            #if DEBUG
            print("file coordination failed for \(url.lastPathComponent): \(coordError)")
            #endif
            try? fileManager.removeItem(at: url)
        }
    }

    func project(withID id: UUID) -> Project? {
        activeProjects.first { $0.id == id } ?? deletedProjects.first { $0.id == id }
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
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        p.projectAddress = trimmed.isEmpty ? nil : trimmed
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
        // If photos already carry localXFeet/Y from a previous plan
        // (e.g. user removed the plan, then added a new one), project
        // them onto the new plan using the new calibration. New projects
        // with no located photos are unaffected since the helper skips
        // photos without local coords.
        Self.recomputePixelCoords(in: &p)
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
        let saved = save(p)
        scheduleVisionAutoTagging(projectID: saved.id, photoID: photoID)
        return saved
    }

    func imageURL(for photo: Photo, in project: Project) -> URL {
        photosFolder(for: project).appending(path: photo.imageFilename)
    }

    func thumbnailURL(for photo: Photo, in project: Project) -> URL? {
        guard let name = photo.thumbnailFilename else { return nil }
        return thumbnailsFolder(for: project).appending(path: name)
    }

    // MARK: - Photo import (from Photos library / Files)

    /// Save an externally-sourced JPEG/HEIC into the project. Same naming and
    /// thumbnail behaviour as a camera capture, but the timestamp comes from
    /// the source EXIF/TIFF data when available so the filename reflects the
    /// real capture time rather than today's date.
    @discardableResult
    func importPhoto(to project: Project, imageData: Data, capturedAt: Date) throws -> Project {
        var p = project
        let photosFolder = photosFolder(for: p)
        let thumbsFolder = thumbnailsFolder(for: p)
        try fileManager.createDirectory(at: photosFolder, withIntermediateDirectories: true)

        let photoID = UUID()
        let seq = p.photos.count + 1
        let imageName = Self.makePhotoFilename(sequenceNumber: seq, timestamp: capturedAt, projectName: p.name)
        let imageURL = photosFolder.appending(path: imageName)
        try imageData.write(to: imageURL, options: .atomic)

        var thumbName: String?
        if let thumb = Self.makeThumbnail(from: imageData, maxPixelSize: 256) {
            try? fileManager.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)
            let n = "thumb_\(imageName)"
            let url = thumbsFolder.appending(path: n)
            try? thumb.write(to: url, options: .atomic)
            thumbName = n
        }

        var photo = Photo(id: photoID, sequenceNumber: seq, imageFilename: imageName)
        photo.timestamp = capturedAt
        photo.thumbnailFilename = thumbName
        photo.cameraZoom = 1.0
        photo.lensName = "imported"
        photo.flashMode = .off

        p.photos.append(photo)
        let saved = save(p)
        scheduleVisionAutoTagging(projectID: saved.id, photoID: photoID)
        return saved
    }

    /// Pull DateTimeOriginal (or TIFF DateTime) out of an image's metadata.
    /// Returns nil when the source has no usable date — caller should fall
    /// back to Date().
    static func extractCaptureDate(from imageData: Data) -> Date? {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current

        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
           let d = formatter.date(from: s) {
            return d
        }
        if let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let s = tiff[kCGImagePropertyTIFFDateTime as String] as? String,
           let d = formatter.date(from: s) {
            return d
        }
        return nil
    }

    // MARK: - Photo location updates

    /// Set or replace the plan-pixel location of an existing photo. Also
    /// re-derives the localXFeet/Y from the current calibration. Use this
    /// for photos imported without a location, or to relocate a photo that
    /// was previously placed.
    @discardableResult
    func setPhotoLocation(_ project: Project,
                          photoID: UUID,
                          planPixelX: Double,
                          planPixelY: Double,
                          headingDegrees: Double?) -> Project {
        var p = project
        guard let plan = p.floorPlan,
              let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        p.photos[idx].planPixelX = planPixelX
        p.photos[idx].planPixelY = planPixelY
        p.photos[idx].localXFeet = (planPixelX - plan.anchorPixelX) / plan.pixelsPerFoot
        p.photos[idx].localYFeet = (planPixelY - plan.anchorPixelY) / plan.pixelsPerFoot
        p.photos[idx].headingDegrees = headingDegrees
        p.photos[idx].positionSource = .manual
        // A re-located photo is always treated as a standalone marker — don't
        // tail off some other group's lead just because it shares a groupID.
        p.photos[idx].groupID = nil
        p.photos[idx].isPrimary = false
        return save(p)
    }

    /// Attach `photoID` as a tail of `leadPhotoID`'s group. The photo inherits
    /// the lead's plan position; if the lead doesn't yet have a groupID, a new
    /// one is minted and the lead is marked as the group's primary. Used by
    /// the Locate / Change-Location flow's "Group with another photo" option.
    @discardableResult
    func attachToGroup(_ project: Project, photoID: UUID, leadPhotoID: UUID) -> Project {
        var p = project
        guard let plan = p.floorPlan,
              let leadIdx = p.photos.firstIndex(where: { $0.id == leadPhotoID }),
              let joinIdx = p.photos.firstIndex(where: { $0.id == photoID }),
              leadPhotoID != photoID,
              let lpx = p.photos[leadIdx].planPixelX,
              let lpy = p.photos[leadIdx].planPixelY else { return p }

        let gid: UUID
        if let existing = p.photos[leadIdx].groupID {
            gid = existing
        } else {
            gid = UUID()
            p.photos[leadIdx].groupID = gid
            p.photos[leadIdx].isPrimary = true
        }

        p.photos[joinIdx].planPixelX = lpx
        p.photos[joinIdx].planPixelY = lpy
        p.photos[joinIdx].localXFeet = (lpx - plan.anchorPixelX) / plan.pixelsPerFoot
        p.photos[joinIdx].localYFeet = (lpy - plan.anchorPixelY) / plan.pixelsPerFoot
        // Tails don't carry a direction arrow — the lead owns the heading.
        p.photos[joinIdx].headingDegrees = nil
        p.photos[joinIdx].positionSource = .manual
        p.photos[joinIdx].groupID = gid
        p.photos[joinIdx].isPrimary = false

        return save(p)
    }

    /// Delete a single photo: remove its image + thumbnail from disk, drop
    /// it from the project's photos array, then renumber the remaining
    /// photos sequentially (1…N) — and rename their files on disk to match
    /// the new sequence numbers so the iCloud filenames stay consistent.
    @discardableResult
    func deletePhoto(_ project: Project, photoID: UUID) throws -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let photosDir = photosFolder(for: p)
        let thumbsDir = thumbnailsFolder(for: p)

        // Remove the deleted photo's files first.
        let removed = p.photos.remove(at: idx)
        try? fileManager.removeItem(at: photosDir.appending(path: removed.imageFilename))
        if let thumb = removed.thumbnailFilename {
            try? fileManager.removeItem(at: thumbsDir.appending(path: thumb))
        }

        // Renumber + rename the survivors so seq 1…N is contiguous and the
        // filenames match the new sequence numbers. Iterating in array order
        // (which is also ascending sequence order) lets each rename go to a
        // slot that's just been freed by an earlier rename or the delete.
        for i in p.photos.indices {
            let oldSeq = p.photos[i].sequenceNumber
            let newSeq = i + 1
            guard oldSeq != newSeq else { continue }

            let timestamp = p.photos[i].timestamp
            let newImageName = Self.makePhotoFilename(
                sequenceNumber: newSeq,
                timestamp: timestamp,
                projectName: p.name
            )

            let oldImageURL = photosDir.appending(path: p.photos[i].imageFilename)
            let newImageURL = photosDir.appending(path: newImageName)
            try? fileManager.moveItem(at: oldImageURL, to: newImageURL)
            p.photos[i].imageFilename = newImageName

            if let oldThumb = p.photos[i].thumbnailFilename {
                let newThumb = "thumb_\(newImageName)"
                let oldThumbURL = thumbsDir.appending(path: oldThumb)
                let newThumbURL = thumbsDir.appending(path: newThumb)
                try? fileManager.moveItem(at: oldThumbURL, to: newThumbURL)
                p.photos[i].thumbnailFilename = newThumb
            }

            p.photos[i].sequenceNumber = newSeq
        }

        return save(p)
    }

    // MARK: - AI instructions

    /// Set or clear the project's custom AI tagging guide. Pass `nil` (or
    /// the empty string) to revert to `AIInstructions.defaultText`.
    @discardableResult
    func setAIInstructions(_ project: Project, _ text: String?) -> Project {
        var p = project
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            p.aiInstructions = t
        } else {
            p.aiInstructions = nil
        }
        return save(p)
    }

    // MARK: - Tags

    /// Add a tag to a photo. Trims whitespace, dedupes case-insensitively
    /// against the photo's existing tags. Manually-typed tags get
    /// `confidence = 1.0` so they always pass any threshold the user sets.
    /// If the tag already exists, the higher of the two confidences wins.
    @discardableResult
    func addTag(_ project: Project,
                photoID: UUID,
                tag rawLabel: String,
                confidence: Double = 1.0) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return p }
        let lc = trimmed.lowercased()
        if let existing = p.photos[idx].tags.firstIndex(where: { $0.label.lowercased() == lc }) {
            // Promote confidence if the new value is higher; otherwise leave
            // the existing tag alone.
            if p.photos[idx].tags[existing].confidence < confidence {
                p.photos[idx].tags[existing].confidence = confidence
            }
            return save(p)
        }
        p.photos[idx].tags.append(Tag(label: trimmed, confidence: confidence))
        return save(p)
    }

    /// Remove a tag from a photo. Case-insensitive match.
    @discardableResult
    func removeTag(_ project: Project, photoID: UUID, tag: String) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let lc = tag.lowercased()
        p.photos[idx].tags.removeAll { $0.label.lowercased() == lc }
        return save(p)
    }

    /// Replace the full tag list for a photo. Trims + dedupes.
    @discardableResult
    func setTags(_ project: Project, photoID: UUID, tags: [Tag]) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        var seen: [String: Int] = [:]   // lowercase → out index
        var out: [Tag] = []
        for t in tags {
            let trimmed = t.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lc = trimmed.lowercased()
            if let i = seen[lc] {
                // Duplicate within input — keep the higher-confidence copy.
                if out[i].confidence < t.confidence {
                    out[i].confidence = t.confidence
                }
                continue
            }
            seen[lc] = out.count
            out.append(Tag(label: trimmed, confidence: t.confidence))
        }
        p.photos[idx].tags = out
        return save(p)
    }

    /// Merge a list of `(label, confidence)` pairs into the photo's existing
    /// tags. Used by the AI auto-accept paths so confidence is preserved
    /// instead of being collapsed to 1.0.
    @discardableResult
    func mergeTags(_ project: Project,
                    photoID: UUID,
                    additions: [Tag]) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        var lookup: [String: Int] = [:]
        for (i, t) in p.photos[idx].tags.enumerated() {
            lookup[t.label.lowercased()] = i
        }
        for incoming in additions {
            let trimmed = incoming.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lc = trimmed.lowercased()
            if let i = lookup[lc] {
                if p.photos[idx].tags[i].confidence < incoming.confidence {
                    p.photos[idx].tags[i].confidence = incoming.confidence
                }
            } else {
                let newTag = Tag(label: trimmed, confidence: incoming.confidence)
                lookup[lc] = p.photos[idx].tags.count
                p.photos[idx].tags.append(newTag)
            }
        }
        return save(p)
    }

    /// Replace the photo's pending AI suggestions, dropping any candidates
    /// already present in the confirmed tags.
    @discardableResult
    func setPendingSuggestions(_ project: Project,
                                photoID: UUID,
                                suggestions: [TagSuggestion]) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let confirmed = Set(p.photos[idx].tags.map { $0.label.lowercased() })
        // Keep only one suggestion per (label,source); rank by confidence so the
        // top-confidence one wins. Different sources can suggest the same label
        // — that's fine, both are kept (different `id`s).
        var bySrcLabel: [String: TagSuggestion] = [:]
        for s in suggestions {
            let key = "\(s.source.rawValue):\(s.label.lowercased())"
            if confirmed.contains(s.label.lowercased()) { continue }
            if let existing = bySrcLabel[key], existing.confidence >= s.confidence { continue }
            bySrcLabel[key] = s
        }
        p.photos[idx].pendingSuggestions = bySrcLabel.values
            .sorted { $0.confidence > $1.confidence }
        return save(p)
    }

    /// Promote a single AI suggestion into a confirmed tag, preserving the
    /// suggestion's confidence on the resulting Tag.
    @discardableResult
    func confirmSuggestion(_ project: Project,
                            photoID: UUID,
                            suggestion: TagSuggestion) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let lc = suggestion.label.lowercased()
        if let existing = p.photos[idx].tags.firstIndex(where: { $0.label.lowercased() == lc }) {
            if p.photos[idx].tags[existing].confidence < suggestion.confidence {
                p.photos[idx].tags[existing].confidence = suggestion.confidence
            }
        } else {
            p.photos[idx].tags.append(Tag(label: suggestion.label,
                                          confidence: suggestion.confidence))
        }
        // Drop every pending suggestion for the same label, regardless of
        // source — once confirmed, neither vision nor claude needs to keep
        // pestering the user.
        p.photos[idx].pendingSuggestions.removeAll { $0.label.lowercased() == lc }
        return save(p)
    }

    /// Apply the per-photo metadata Claude returns alongside its tags
    /// (severity, observation, follow-up). Empty/whitespace-only strings are
    /// stored as `nil` so the editor can show "—" placeholders.
    @discardableResult
    func setPhotoAIMetadata(_ project: Project,
                             photoID: UUID,
                             severity: String?,
                             observation: String?,
                             followUp: String?) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        func clean(_ s: String?) -> String? {
            guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        p.photos[idx].aiSeverity    = clean(severity)
        p.photos[idx].aiObservation = clean(observation)
        p.photos[idx].aiFollowUp    = clean(followUp)
        return save(p)
    }

    /// Drop a single AI suggestion without confirming it.
    @discardableResult
    func dismissSuggestion(_ project: Project,
                            photoID: UUID,
                            suggestion: TagSuggestion) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        p.photos[idx].pendingSuggestions.removeAll { $0.id == suggestion.id }
        return save(p)
    }

    /// Tags currently in use across the given project. Sorted by frequency
    /// (most-used first). Tags below `minConfidence` (per-photo) are not
    /// counted, so the typeahead/filter list reflects the user's threshold.
    func tagsUsed(in project: Project, minConfidence: Double = 0) -> [String] {
        rankTags(in: project.photos, minConfidence: minConfidence)
    }

    /// Tags currently in use across every project the user has — used to
    /// surface previously-typed tags on a fresh project. Sorted by frequency.
    func tagsUsedGlobally(minConfidence: Double = 0) -> [String] {
        let all = activeProjects.flatMap { $0.photos } + deletedProjects.flatMap { $0.photos }
        return rankTags(in: all, minConfidence: minConfidence)
    }

    private func rankTags(in photos: [Photo], minConfidence: Double) -> [String] {
        // Count case-insensitively, but remember the most-common display
        // casing for each lowercase key.
        var counts: [String: Int] = [:]
        var displays: [String: [String: Int]] = [:]
        for photo in photos {
            for t in photo.tags where t.confidence >= minConfidence {
                let key = t.label.lowercased()
                counts[key, default: 0] += 1
                displays[key, default: [:]][t.label, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { (key, _) in
                let perCasing = displays[key] ?? [:]
                return perCasing.max { $0.value < $1.value }?.key ?? key
            }
    }

    // MARK: - Vision auto-tagging hook

    /// Kick off an off-main on-device classification for the given photo.
    /// Fire-and-forget — when the Vision request finishes, any extracted
    /// forensic-relevant labels land in the photo's `pendingSuggestions`.
    /// Does nothing on failure (e.g. corrupt image, request error) — the
    /// user can still tap "Suggest with AI" later.
    func scheduleVisionAutoTagging(projectID: UUID, photoID: UUID) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let urlOpt: URL? = await MainActor.run {
                guard let p = self.project(withID: projectID),
                      let photo = p.photos.first(where: { $0.id == photoID })
                else { return nil }
                return self.imageURL(for: photo, in: p)
            }
            guard let url = urlOpt else { return }
            // iCloud-backed photos have to materialise on disk before Vision
            // can read them. The freshly-saved file in addPhoto/importPhoto
            // is already local so this is a no-op there, but doing it
            // unconditionally makes the helper safe to call against any
            // photoID later on.
            await self.ensureDownloaded(url)
            let suggestions = VisionTaggingService.tag(imageURL: url) ?? []
            guard !suggestions.isEmpty else { return }
            await MainActor.run {
                guard let current = self.project(withID: projectID) else { return }
                _ = self.setPendingSuggestions(
                    current, photoID: photoID, suggestions: suggestions
                )
            }
        }
    }

    // MARK: - Batch Claude tagging

    /// Run Claude vision tagging across every photo in the project, then
    /// auto-confirm whatever Claude returns. Designed for the "tag all
    /// photos at once" project-detail button, where the user has already
    /// agreed to the cost.
    ///
    /// `skipAlreadyTagged` — when true (default), photos that already have
    /// at least one confirmed tag are left alone. Lets the user add manual
    /// tags first, then top up with AI for the rest.
    ///
    /// `onProgress` is called on the main actor before each photo and once
    /// more on completion. `current` is 1-based; `current == total` and a
    /// non-empty `summary` indicate the run finished.
    ///
    /// Throws `ClaudeTaggingService.Error.missingAPIKey` immediately if no
    /// key is on file. Per-photo errors (network blips, parse failures) are
    /// swallowed so a single bad photo doesn't kill the rest of the batch —
    /// the result tuple reports how many photos got at least one tag and
    /// how many failed.
    @MainActor
    @discardableResult
    func batchClaudeTagging(
        projectID: UUID,
        skipAlreadyTagged: Bool = true,
        onProgress: @escaping @MainActor (_ current: Int, _ total: Int, _ photoSeq: Int?) -> Void
    ) async throws -> (tagged: Int, failed: Int, skipped: Int) {
        guard KeychainStore.loadAnthropicKey()?.isEmpty == false else {
            throw ClaudeTaggingService.Error.missingAPIKey
        }
        guard let project = self.project(withID: projectID) else {
            return (0, 0, 0)
        }

        let candidates = project.photos.filter { photo in
            skipAlreadyTagged ? photo.tags.isEmpty : true
        }
        let skipped = project.photos.count - candidates.count
        let total = candidates.count
        let instructions = project.effectiveAIInstructions

        // Read concurrency from the user's setting (default 5). Tier-1
        // Anthropic accounts handle ~5 concurrent comfortably; users on
        // higher tiers can dial it up in Settings.
        let raw = UserDefaults.standard.integer(forKey: "sitephoto.aiConcurrency")
        let maxConcurrent = max(1, min(20, raw == 0 ? 5 : raw))

        // Pre-compute the per-photo work list on the main actor so the
        // task closures don't have to call back into `self` for URLs —
        // keeps the closures Sendable-clean.
        struct WorkItem {
            let photoID: UUID
            let sequenceNumber: Int
            let url: URL
        }
        let work: [WorkItem] = candidates.map { p in
            WorkItem(photoID: p.id,
                      sequenceNumber: p.sequenceNumber,
                      url: self.imageURL(for: p, in: project))
        }

        var tagged = 0
        var failed = 0
        var completed = 0

        try await withThrowingTaskGroup(of: PhotoTagResult.self) { group in
            var iterator = work.makeIterator()

            // Helper: launch the next photo's API call. Returns false once
            // the iterator is empty so the drain loop can stop scheduling.
            // Captures only value types (URL, UUID, Int, String) so the
            // Sendable contract on `addTask` holds.
            func launchNext() -> Bool {
                guard let item = iterator.next() else { return false }
                let url = item.url
                let pid = item.photoID
                let seq = item.sequenceNumber
                let inst = instructions
                group.addTask {
                    await Self.ensureDownloadedStatic(at: url)
                    do {
                        let r = try await ClaudeTaggingService.tag(
                            imageURL: url,
                            instructions: inst
                        )
                        return PhotoTagResult(photoID: pid, sequenceNumber: seq,
                                              outcome: .success(r))
                    } catch ClaudeTaggingService.Error.missingAPIKey {
                        return PhotoTagResult(photoID: pid, sequenceNumber: seq,
                                              outcome: .authFailure)
                    } catch {
                        return PhotoTagResult(photoID: pid, sequenceNumber: seq,
                                              outcome: .otherFailure(error.localizedDescription))
                    }
                }
                return true
            }

            // Seed the pool with up to `maxConcurrent` in-flight tasks.
            for _ in 0..<maxConcurrent {
                if !launchNext() { break }
            }

            // Drain: as each task finishes, apply its result on the main
            // actor and queue the next one. Maintains a steady N tasks in
            // flight until `iterator` is exhausted.
            for try await result in group {
                try Task.checkCancellation()
                completed += 1

                switch result.outcome {
                case .authFailure:
                    group.cancelAll()
                    throw ClaudeTaggingService.Error.missingAPIKey
                case .success(let r):
                    if let proj = self.project(withID: projectID) {
                        var p = proj
                        if !r.suggestions.isEmpty {
                            let additions = r.suggestions.map {
                                Tag(label: $0.label, confidence: $0.confidence)
                            }
                            p = self.mergeTags(p, photoID: result.photoID, additions: additions)
                            tagged += 1
                        }
                        // Always persist metadata, even on photos with no
                        // tags returned — the observation/follow-up may be
                        // useful (e.g. "no_visible_distress").
                        _ = self.setPhotoAIMetadata(
                            p, photoID: result.photoID,
                            severity:    r.metadata.severity,
                            observation: r.metadata.observation,
                            followUp:    r.metadata.followUp
                        )
                    }
                case .otherFailure(let msg):
                    failed += 1
                    #if DEBUG
                    print("Claude batch failed for #\(result.sequenceNumber): \(msg)")
                    #endif
                }

                onProgress(completed, total, result.sequenceNumber)
                _ = launchNext()
            }
        }

        onProgress(total, total, nil)
        return (tagged: tagged, failed: failed, skipped: skipped)
    }

    /// Per-photo result emitted by the batch task group. Aggregating the
    /// outcome inside one envelope keeps the drain loop's switch tidy.
    private struct PhotoTagResult: Sendable {
        let photoID: UUID
        let sequenceNumber: Int
        let outcome: Outcome

        enum Outcome: Sendable {
            case success(ClaudeTaggingService.Result)
            case authFailure
            case otherFailure(String)
        }
    }

    /// Strip the location from an existing photo (turns it back into "NO LOC").
    @discardableResult
    func clearPhotoLocation(_ project: Project, photoID: UUID) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        p.photos[idx].planPixelX = nil
        p.photos[idx].planPixelY = nil
        p.photos[idx].localXFeet = nil
        p.photos[idx].localYFeet = nil
        p.photos[idx].headingDegrees = nil
        p.photos[idx].positionSource = .none
        p.photos[idx].groupID = nil
        p.photos[idx].isPrimary = false
        return save(p)
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
        await Self.ensureDownloadedStatic(at: url, timeoutSeconds: timeoutSeconds)
    }

    /// Sendable-friendly variant — usable from inside `TaskGroup.addTask`
    /// closures without capturing `self`. Same behaviour as the instance
    /// method.
    static func ensureDownloadedStatic(at url: URL,
                                        timeoutSeconds: Double = 30) async {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus == .current { return }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
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

}
