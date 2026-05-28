import Foundation
import PDFKit
import UIKit

/// Render the first page of a PDF (typically an architectural floor
/// plan exported from CAD or a dropbox-shared PDF) into a JPEG suitable
/// for the existing floor-plan import path. Centralised here so both
/// `FloorPlanSetupView` and `FloorPlanReplaceView` can share the same
/// rasterisation logic and error handling.
///
/// The renderer:
///   • opens the URL inside `startAccessingSecurityScopedResource()`
///     so files from `.fileImporter` (iCloud, Files providers, network
///     shares) are reachable;
///   • refuses encrypted/locked PDFs with a clear `.locked` error;
///   • computes the rasterisation size from the page's `mediaBox`
///     scaled to a target DPI, clamped so the longest edge never
///     exceeds `maxDimension` (avoids OOM on E-size sheets);
///   • runs the actual `UIGraphicsImageRenderer` block inside an
///     `autoreleasepool` so the intermediate `UIImage` is released
///     before the JPEG-encode step.
enum FloorPlanPDFImportError: Error, LocalizedError {
    case locked
    case empty
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .locked:        return "This PDF is password-protected and can't be imported."
        case .empty:         return "This PDF has no pages."
        case .renderFailed:  return "Could not render the first page of the PDF."
        }
    }
}

enum FloorPlanPDFImport {
    /// Lightweight introspection used to decide whether to show the
    /// page-picker sheet. Cheap — just opens the document and reads
    /// `pageCount`. Throws `.locked` for encrypted PDFs (same as the
    /// renderer) so the caller can surface the error before the user
    /// sees a "0 pages" picker.
    static func pageCount(at url: URL) throws -> Int {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let document = PDFDocument(url: url) else {
            throw FloorPlanPDFImportError.renderFailed
        }
        if document.isLocked || document.isEncrypted {
            throw FloorPlanPDFImportError.locked
        }
        return document.pageCount
    }

    /// Render a specific page of the PDF at `url` to JPEG data.
    /// Page indices are 0-based — page 1 in a UI corresponds to
    /// `pageIndex: 0`.
    ///
    /// - Parameters:
    ///   - pageIndex: which page to rasterise.
    ///   - url: source URL — handled inside a security-scoped block.
    ///   - maxDimension: hard cap on the longest edge in pixels so a
    ///     huge architectural sheet doesn't OOM the device.
    ///   - targetDPI: rasterisation density in pixels per inch on the
    ///     PDF's media box.
    ///   - jpegQuality: passed through to `UIImage.jpegData`.
    /// - Returns: encoded JPEG bytes ready to feed into the floor-plan
    ///   import pipeline.
    static func renderPage(at pageIndex: Int,
                            from url: URL,
                            maxDimension: CGFloat = 4000,
                            targetDPI: CGFloat = 200,
                            jpegQuality: CGFloat = 0.9) throws -> Data {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url) else {
            throw FloorPlanPDFImportError.renderFailed
        }
        if document.isLocked || document.isEncrypted {
            throw FloorPlanPDFImportError.locked
        }
        guard pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else {
            throw FloorPlanPDFImportError.empty
        }

        let mediaBoxSize = page.bounds(for: .mediaBox).size
        guard mediaBoxSize.width > 0, mediaBoxSize.height > 0 else {
            throw FloorPlanPDFImportError.renderFailed
        }

        var pixelSize = CGSize(width: mediaBoxSize.width  * (targetDPI / 72),
                                height: mediaBoxSize.height * (targetDPI / 72))
        let longest = max(pixelSize.width, pixelSize.height)
        if longest > maxDimension {
            let scale = maxDimension / longest
            pixelSize.width  *= scale
            pixelSize.height *= scale
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)

        let jpeg: Data? = autoreleasepool {
            let image = renderer.image { ctx in
                let cg = ctx.cgContext
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(CGRect(origin: .zero, size: pixelSize))
                cg.translateBy(x: 0, y: pixelSize.height)
                cg.scaleBy(x: 1, y: -1)
                let pageBounds = page.bounds(for: .mediaBox)
                cg.scaleBy(x: pixelSize.width  / pageBounds.width,
                            y: pixelSize.height / pageBounds.height)
                cg.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
                page.draw(with: .mediaBox, to: cg)
            }
            return image.jpegData(compressionQuality: jpegQuality)
        }
        guard let data = jpeg else { throw FloorPlanPDFImportError.renderFailed }
        return data
    }

    /// Backward-compat shim — the old single-page-only helper used by
    /// any caller that hasn't migrated to the page-aware API. Just
    /// renders page 0 with the same defaults.
    static func renderFirstPageToJPEG(from url: URL,
                                       maxDimension: CGFloat = 4000,
                                       targetDPI: CGFloat = 200,
                                       jpegQuality: CGFloat = 0.9) throws -> Data {
        try renderPage(at: 0,
                        from: url,
                        maxDimension: maxDimension,
                        targetDPI: targetDPI,
                        jpegQuality: jpegQuality)
    }

    /// Generate a small thumbnail for `pageIndex` suitable for a grid
    /// page picker. Returns nil on any failure rather than throwing —
    /// the picker tolerates a few missing thumbnails (rendered as a
    /// generic placeholder) more gracefully than an aborted load.
    static func pageThumbnail(at pageIndex: Int,
                                from url: URL,
                                size: CGSize = CGSize(width: 150, height: 200)) -> UIImage? {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let document = PDFDocument(url: url),
              !document.isLocked,
              !document.isEncrypted,
              pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else {
            return nil
        }
        return page.thumbnail(of: size, for: .mediaBox)
    }
}
