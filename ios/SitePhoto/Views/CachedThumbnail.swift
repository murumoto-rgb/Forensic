import SwiftUI
import ImageIO

/// Process-wide cache for small list thumbnails (photo rows, plan
/// rows). Keyed by file path + modification time so an overwritten
/// file (e.g. a replaced plan image) naturally invalidates its
/// entry. NSCache evicts on memory pressure by itself; the count
/// limit just keeps the steady-state footprint modest.
enum ThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        return cache
    }()

    static func key(for url: URL) -> NSString {
        let mtime = ((try? FileManager.default
            .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
            .map { String($0.timeIntervalSince1970) } ?? "0"
        return "\(url.path)|\(mtime)" as NSString
    }
}

/// Async-loading thumbnail for List rows (Build #6.4.1). Replaces the
/// synchronous `Data(contentsOf:)` + `UIImage(data:)` pattern that ran
/// a disk read + JPEG decode on the MainActor for every visible row —
/// the main source of scroll stutter on photo-heavy projects. First
/// render shows a neutral placeholder; the decoded image lands a beat
/// later and is cached, so steady-state scrolling hits the NSCache and
/// never touches disk.
struct CachedThumbnail: View {
    let url: URL?
    /// SF Symbol shown while loading / when the file is missing.
    var placeholderSystemImage: String = "photo"
    /// When set, the file is downsampled to at most this many pixels
    /// on its long edge via ImageIO instead of fully decoded. Use for
    /// rows backed by a full-resolution source (e.g. plan images,
    /// which have no dedicated thumb file) so the cache holds a small
    /// bitmap, not the whole drawing.
    var maxPixelSize: CGFloat? = nil

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: placeholderSystemImage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let cacheKey = maxPixelSize.map { "\(ThumbnailCache.key(for: url))|\(Int($0))" as NSString }
                ?? ThumbnailCache.key(for: url)
            if let hit = ThumbnailCache.shared.object(forKey: cacheKey) {
                image = hit
                return
            }
            // Read + decode off the MainActor. `preparingForDisplay()`
            // forces the JPEG decode here instead of lazily on the
            // render thread at draw time.
            let maxPixel = maxPixelSize
            let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                if let maxPixel {
                    // ImageIO thumbnail path: never decodes the full
                    // bitmap into memory.
                    let opts: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    ]
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                        return nil
                    }
                    return UIImage(cgImage: cg)
                }
                guard let data = try? Data(contentsOf: url),
                      let img = UIImage(data: data) else { return nil }
                return img.preparingForDisplay() ?? img
            }.value
            guard !Task.isCancelled else { return }
            if let loaded {
                ThumbnailCache.shared.setObject(loaded, forKey: cacheKey)
            }
            image = loaded
        }
    }
}
