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
    func export(progress: @escaping (String) -> Void) async -> URL? {
        let fileManager = FileManager.default
        let exportRoot = store.rootURL.appending(
            path: "Exports", directoryHint: .isDirectory
        )
        do {
            try fileManager.createDirectory(
                at: exportRoot, withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let stamp = stampString()
        let safeProject = sanitize(project.name)
        let dirName = "\(safeProject)_\(stamp)"
        let projectDir = exportRoot.appending(
            path: dirName, directoryHint: .isDirectory
        )
        // If a clash somehow happens, append "(1)" / "(2)" until a free
        // slot is found instead of overwriting an earlier export.
        var finalDir = projectDir
        var counter = 1
        while fileManager.fileExists(atPath: finalDir.path()) {
            finalDir = exportRoot.appending(
                path: "\(dirName) (\(counter))", directoryHint: .isDirectory
            )
            counter += 1
        }
        do {
            try fileManager.createDirectory(
                at: finalDir, withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        // Bucket sort order drives folder prefix numbering. Photos with no
        // bucketID get folded into a sentinel "99 Unbucketed" folder at
        // the end so the engineer can see what slipped through.
        let sortedBuckets = project.buckets.sorted { $0.sortOrder < $1.sortOrder }
        let photosFolder = store.photosFolder(for: project)

        for (index, bucket) in sortedBuckets.enumerated() {
            let prefix = String(format: "%02d", index + 1)
            let folderName = sanitize("\(prefix) \(bucket.name)")
            let folderURL = finalDir.appending(
                path: folderName, directoryHint: .isDirectory
            )
            try? fileManager.createDirectory(
                at: folderURL, withIntermediateDirectories: true
            )
            let photos = project.photos
                .filter { $0.bucketID == bucket.id }
                .sorted { $0.sequenceNumber < $1.sequenceNumber }
            progress("Writing \(folderName) (\(photos.count) photo\(photos.count == 1 ? "" : "s"))…")
            await copyPhotos(photos,
                              from: photosFolder,
                              to: folderURL,
                              fileManager: fileManager)
            writeCaptions(for: photos, to: folderURL)
        }

        let unbucketed = project.photos
            .filter { $0.bucketID == nil }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        if !unbucketed.isEmpty {
            let folderURL = finalDir.appending(
                path: "99 Unbucketed", directoryHint: .isDirectory
            )
            try? fileManager.createDirectory(
                at: folderURL, withIntermediateDirectories: true
            )
            progress("Writing 99 Unbucketed (\(unbucketed.count) photo\(unbucketed.count == 1 ? "" : "s"))…")
            await copyPhotos(unbucketed,
                              from: photosFolder,
                              to: folderURL,
                              fileManager: fileManager)
            writeCaptions(for: unbucketed, to: folderURL)
        }

        return finalDir
    }

    private func copyPhotos(_ photos: [Photo],
                             from photosFolder: URL,
                             to destination: URL,
                             fileManager: FileManager) async {
        for photo in photos {
            let src = photosFolder.appending(path: photo.imageFilename)
            // Photos live in iCloud Drive when iCloud is enabled — `copyItem`
            // on an undownloaded placeholder silently writes nothing. Pull
            // the file to this device before touching it. This mirrors what
            // PDFExportService does via `loadFileBytes` and is the difference
            // between an export of N JPGs and an empty bucket folder + a
            // `captions.txt`.
            await store.ensureDownloaded(src)
            guard fileManager.fileExists(atPath: src.path()) else { continue }
            // Reuse the source filename — already sequence-prefixed by
            // ProjectStore.makePhotoFilename, so engineers can sort
            // alphabetically and get sequence order. Byte-copy the original
            // when no stamp is requested so EXIF (date / GPS) is preserved;
            // re-encode with the stamp otherwise.
            let dst = destination.appending(path: photo.imageFilename)
            if burnInTimestampAndGPS {
                let stamped = EXIFStamp.stamp(srcURL: src,
                                                dstURL: dst,
                                                photo: photo,
                                                gps: project.projectGPS,
                                                address: project.projectAddress)
                if !stamped {
                    try? fileManager.copyItem(at: src, to: dst)
                }
            } else {
                try? fileManager.copyItem(at: src, to: dst)
            }
            // When the photo has a PencilKit markup overlay, ALSO write
            // a `<stem>_marked.jpg` next to the clean copy so the report
            // can show both versions side-by-side. EXIF is lost on the
            // marked copy (it's re-encoded after compositing) but the
            // clean copy preserves it (when not stamping).
            if let markupURL = store.markupOverlayURL(for: photo, in: project) {
                await store.ensureDownloaded(markupURL)
                let markedURL = destination.appending(
                    path: Self.markedFilename(for: photo.imageFilename)
                )
                _ = compositeMarkup(photoURL: src,
                                     markupURL: markupURL,
                                     dst: markedURL,
                                     burnIn: burnInTimestampAndGPS,
                                     photo: photo)
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
    /// copy) if either image fails to load or encoding produces nothing.
    /// When `burnIn` is true, the EXIF stamp (timestamp + GPS) is drawn
    /// after the markup so it shows up on top of any strokes.
    private func compositeMarkup(photoURL: URL,
                                  markupURL: URL,
                                  dst: URL,
                                  burnIn: Bool,
                                  photo: Photo) -> Bool {
        guard let photoData = try? Data(contentsOf: photoURL),
              let photoImage = UIImage(data: photoData),
              let markupData = try? Data(contentsOf: markupURL),
              let markupImage = UIImage(data: markupData) else {
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

    private func writeCaptions(for photos: [Photo], to folder: URL) {
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
        try? text.write(to: url, atomically: true, encoding: .utf8)
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
