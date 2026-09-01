import Foundation
import UIKit

/// Build a directory tree under the app's storage root with one folder per
/// user-defined bucket, photos copied byte-for-byte (so EXIF and timestamps
/// are preserved), and a `captions.txt` per folder summarising each photo.
/// Photos with no bucket land in a final `99 Unbucketed` folder.
///
/// The service writes into the app's iCloud Documents container when iCloud
/// is available (so the user can grab the tree from Files → iCloud Drive →
/// SitePhoto → Exports), and falls back to local Documents otherwise (Files
/// → On My iPhone → SitePhoto → Exports).
@MainActor
struct FolderExportService {
    enum ExportError: LocalizedError {
        case itemUnavailable(String)
        case writeFailed(String, Error)
        case processingFailed(String)
        case destinationUnavailable(String, Error)
        var errorDescription: String? {
            switch self {
            case .itemUnavailable(let item): return "Required export item is unavailable: \(item)."
            case .writeFailed(let item, let error): return "Could not write \(item): \(error.localizedDescription)"
            case .processingFailed(let item): return "Could not process \(item) for export."
            case .destinationUnavailable(let item, let error): return "Could not create the export \(item): \(error.localizedDescription)"
            }
        }
    }
    let project: Project
    let store: ProjectStore
    /// When true, every exported JPG (clean + marked) is re-encoded with
    /// a bottom-right stamp showing the capture timestamp and the project's
    /// GPS coordinates. EXIF metadata is lost on stamped copies since
    /// stamping requires a decode/encode round trip.
    var burnInTimestampAndGPS: Bool = false

    /// Build the tree and return the root folder URL on success, or nil on
    /// failure. `progress` is invoked on the main actor with human-readable
    /// status updates the runner view can display.
    func export(progress: @escaping (String) -> Void) async throws -> URL {
        let fileManager = FileManager.default
        let exportRoot = store.rootURL.appending(
            path: "Exports", directoryHint: .isDirectory
        )
        do {
            try fileManager.createDirectory(
                at: exportRoot, withIntermediateDirectories: true
            )
        } catch { throw ExportError.destinationUnavailable("Exports folder", error) }

        let stamp = stampString()
        let safeProject = sanitize(project.name)
        let dirName = "\(safeProject)_\(stamp)"
        let uniqueName = "\(dirName)_\(UUID().uuidString.prefix(8))"
        let finalDir = exportRoot.appending(path: uniqueName, directoryHint: .isDirectory)
        let stagingDir = exportRoot.appending(path: ".\(uniqueName).incomplete-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: false)
            try await buildExport(at: stagingDir, fileManager: fileManager, progress: progress)
            try fileManager.moveItem(at: stagingDir, to: finalDir)
            return finalDir
        } catch {
            try? fileManager.removeItem(at: stagingDir)
            throw error
        }
    }

    private func buildExport(at finalDir: URL, fileManager: FileManager,
                             progress: @escaping (String) -> Void) async throws {
        // Bucket sort order drives folder prefix numbering. Photos with no
        // bucketID get folded into a sentinel "99 Unbucketed" folder at
        // the end so the engineer can see what slipped through.
        let sortedBuckets = project.buckets.sorted { $0.sortOrder < $1.sortOrder }
        let photosFolder = store.photosFolder(for: project)

        let knownBucketIDs = Set(sortedBuckets.map(\.id))
        for (index, bucket) in sortedBuckets.enumerated() {
            let prefix = String(format: "%02d", index + 1)
            let folderName = sanitize("\(prefix) \(bucket.name)")
            let folderURL = finalDir.appending(
                path: folderName, directoryHint: .isDirectory
            )
            try makeDirectory(folderURL, fileManager: fileManager)
            let photos = project.photos
                .filter { $0.bucketID == bucket.id }
                .sorted { $0.sequenceNumber < $1.sequenceNumber }
            progress("Writing \(folderName) (\(photos.count) photo\(photos.count == 1 ? "" : "s"))…")
            try await copyPhotos(photos, from: photosFolder, to: folderURL, fileManager: fileManager)
            try writeCaptions(for: photos, to: folderURL)
        }

        let unbucketed = project.photos
            .filter { $0.bucketID == nil || !knownBucketIDs.contains($0.bucketID!) }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        if !unbucketed.isEmpty {
            let folderURL = finalDir.appending(
                path: "99 Unbucketed", directoryHint: .isDirectory
            )
            try makeDirectory(folderURL, fileManager: fileManager)
            progress("Writing 99 Unbucketed (\(unbucketed.count) photo\(unbucketed.count == 1 ? "" : "s"))…")
            try await copyPhotos(unbucketed, from: photosFolder, to: folderURL, fileManager: fileManager)
            try writeCaptions(for: unbucketed, to: folderURL)
        }
        if !project.floorPlans.isEmpty {
            let folderURL = finalDir.appending(path: "00 Floor Plans", directoryHint: .isDirectory)
            try makeDirectory(folderURL, fileManager: fileManager)
            progress("Writing floor plans…")
            for plan in project.floorPlans {
                let source = store.planImageURL(for: plan, in: project)
                guard let bytes = await store.loadFileBytes(at: source) else {
                    throw ExportError.itemUnavailable("floor plan \(plan.label) (\(plan.imageFilename))")
                }
                try write(bytes, to: folderURL.appending(path: plan.imageFilename), item: "floor plan \(plan.label)")
            }
        }
    }

    private func copyPhotos(_ photos: [Photo],
                             from photosFolder: URL,
                             to destination: URL,
                             fileManager: FileManager) async throws {
        for photo in photos {
            let src = photosFolder.appending(path: photo.imageFilename)
            // `FileManager.copyItem` doesn't auto-trigger an iCloud download
            // the way `Data(contentsOf:)` does — when the source is still a
            // placeholder it silently produces nothing. Read the bytes via
            // `loadFileBytes`, which both downloads and validates, then
            // write them out. EXIF is preserved bit-for-bit because we
            // round-trip the original JPEG bytes (no decode/encode).
            guard let srcBytes = await store.loadFileBytes(at: src) else {
                throw ExportError.itemUnavailable("original photo \(photo.imageFilename)")
            }
            let dst = destination.appending(path: photo.imageFilename)
            if fileManager.fileExists(atPath: dst.path) {
                throw ExportError.writeFailed("original photo \(photo.imageFilename)", CocoaError(.fileWriteFileExists))
            }
            if burnInTimestampAndGPS {
                let stamped = EXIFStamp.stamp(srcBytes: srcBytes,
                                                dstURL: dst,
                                                photo: photo,
                                                gps: project.projectGPS,
                                                address: project.projectAddress)
                if !stamped {
                    throw ExportError.processingFailed("original photo \(photo.imageFilename) stamp")
                }
            } else {
                try write(srcBytes, to: dst, item: "original photo \(photo.imageFilename)")
            }
            // When the photo has a PencilKit markup overlay, ALSO write
            // a `<stem>_marked.jpg` next to the clean copy so the report
            // can show both versions side-by-side. EXIF is lost on the
            // marked copy (it's re-encoded after compositing) but the
            // clean copy preserves it (when not stamping).
            if let markupName = photo.markupOverlayFilename {
                let markupURL = store.markupsFolder(for: project).appending(path: markupName)
                guard let markupBytes = await store.loadFileBytes(at: markupURL) else {
                    throw ExportError.itemUnavailable("markup overlay \(markupName)")
                }
                let markedURL = destination.appending(
                    path: Self.markedFilename(for: photo.imageFilename)
                )
                if fileManager.fileExists(atPath: markedURL.path) {
                    throw ExportError.writeFailed("marked photo \(photo.imageFilename)", CocoaError(.fileWriteFileExists))
                }
                guard compositeMarkup(photoBytes: srcBytes, markupBytes: markupBytes, dst: markedURL,
                                      burnIn: burnInTimestampAndGPS, photo: photo) else {
                    throw ExportError.processingFailed("marked photo \(photo.imageFilename)")
                }
                let markups = destination.deletingLastPathComponent().appending(path: "01 Markups", directoryHint: .isDirectory)
                try makeDirectory(markups, fileManager: fileManager)
                try write(markupBytes, to: markups.appending(path: markupName), item: "markup overlay \(markupName)")
            }
            if let drawingName = photo.markupDrawingFilename {
                let drawingURL = store.markupsFolder(for: project).appending(path: drawingName)
                guard let drawingBytes = await store.loadFileBytes(at: drawingURL) else {
                    throw ExportError.itemUnavailable("markup drawing \(drawingName)")
                }
                let markups = destination.deletingLastPathComponent().appending(path: "01 Markups", directoryHint: .isDirectory)
                try makeDirectory(markups, fileManager: fileManager)
                try write(drawingBytes, to: markups.appending(path: drawingName), item: "markup drawing \(drawingName)")
            }
        }
    }

    /// Build the filename for the marked twin of a photo. Inserts `_marked`
    /// before the extension so `Foo - 5 - 260509.jpg` becomes
    /// `Foo - 5 - 260509_marked.jpg` — sorts alphabetically right after
    /// the clean original so a Finder listing reads clean → marked.
    private static func markedFilename(for original: String) -> String {
        let stem = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        return ext.isEmpty ? "\(stem)_marked" : "\(stem)_marked.\(ext)"
    }

    /// Render the source JPG + PencilKit overlay PNG into a single JPG at
    /// the destination. Returns false (so the caller falls back to byte
    /// copy) if either image fails to decode or encoding produces nothing.
    /// When `burnIn` is true, the EXIF stamp (timestamp + GPS) is drawn
    /// after the markup so it shows up on top of any strokes.
    private func compositeMarkup(photoBytes: Data,
                                  markupBytes: Data,
                                  dst: URL,
                                  burnIn: Bool,
                                  photo: Photo) -> Bool {
        guard let photoImage = UIImage(data: photoBytes),
              let markupImage = UIImage(data: markupBytes) else {
            return false
        }
        let size = photoImage.size
        guard size.width > 0, size.height > 0 else { return false }
        let renderer = UIGraphicsImageRenderer(
            size: size,
            format: {
                let f = UIGraphicsImageRendererFormat.default()
                f.opaque = true
                f.scale = 1
                return f
            }()
        )
        let composited = renderer.image { ctx in
            photoImage.draw(in: CGRect(origin: .zero, size: size))
            markupImage.draw(in: CGRect(origin: .zero, size: size))
            if burnIn {
                EXIFStamp.stamp(intoContext: ctx.cgContext,
                                  imageSize: size,
                                  photo: photo,
                                  gps: project.projectGPS,
                                  address: project.projectAddress)
            }
        }
        guard let jpeg = composited.jpegData(compressionQuality: 0.92) else {
            return false
        }
        do {
            try jpeg.write(to: dst, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func writeCaptions(for photos: [Photo], to folder: URL) throws {
        var lines: [String] = []
        lines.append("Project: \(project.name)")
        if let address = project.projectAddress, !address.isEmpty {
            lines.append("Address: \(address)")
        }
        lines.append("")
        for photo in photos {
            lines.append("--- Photo #\(photo.sequenceNumber) ---")
            lines.append("File: \(photo.imageFilename)")
            if photo.markupOverlayFilename != nil {
                lines.append("Marked copy: \(Self.markedFilename(for: photo.imageFilename))")
            }
            lines.append("Captured: \(photo.timestamp.formatted(date: .abbreviated, time: .standard))")
            if photo.isFavorite {
                lines.append("Favorite: ★")
            }
            if let analysis = photo.aiAnalysis,
               !analysis.parseFailed,
               !analysis.locationInferred.isEmpty {
                lines.append("Location: \(analysis.locationInferred)")
            }
            if let caption = photo.effectiveCaption {
                let tag = (photo.userCaption?.isEmpty == false) ? "(user)" : "(AI)"
                lines.append("Caption \(tag): \(caption)")
            }
            if let observation = photo.effectiveObservation {
                let tag = (photo.userObservation?.isEmpty == false) ? "(user)" : "(AI)"
                lines.append("Observation \(tag): \(observation)")
            }
            let confirmedTags = photo.tags
                .filter { $0.confidence >= 0.5 }
                .map { tag -> String in
                    if let parent = tag.parentTag {
                        return "\(parent) / \(tag.label)"
                    }
                    return tag.label
                }
            if !confirmedTags.isEmpty {
                lines.append("Tags: \(confirmedTags.joined(separator: ", "))")
            }
            lines.append("")
        }
        let text = lines.joined(separator: "\n")
        let url = folder.appending(path: "captions.txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw ExportError.writeFailed("captions.txt", error) }
    }

    private func makeDirectory(_ url: URL, fileManager: FileManager) throws {
        do { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw ExportError.destinationUnavailable(url.lastPathComponent, error) }
    }

    private func write(_ bytes: Data, to url: URL, item: String) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw ExportError.writeFailed(item, CocoaError(.fileWriteFileExists))
        }
        do { try bytes.write(to: url, options: .atomic) }
        catch { throw ExportError.writeFailed(item, error) }
    }

    private func stampString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmm"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: Date())
    }

    /// Strip characters that would break filesystem semantics on iOS / macOS
    /// (`/ \ : * ? " < > |`) and trim runs of whitespace down to single
    /// spaces. Result is bounded to 60 characters so deeply-nested exports
    /// don't trip the 1024-char total path limit.
    private func sanitize(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let bounded = String(cleaned.prefix(60))
        return bounded.isEmpty ? "Folder" : bounded
    }
}
