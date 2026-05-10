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
    /// Render page 1 of the PDF at `url` to JPEG data.
    ///
    /// - Parameters:
    ///   - url: source URL — handled inside a security-scoped block so
    ///     files outside the sandbox (Files providers, iCloud) work.
    ///   - maxDimension: hard cap on the longest edge in pixels so a
    ///     huge architectural sheet doesn't OOM the device. Default
    ///     4000 px ≈ 50 MP raw, well within iPhone limits.
    ///   - targetDPI: rasterisation density in pixels per inch on the
    ///     PDF's media box. 200 DPI is the threshold where annotations
    ///     and small text remain legible; we trade memory above that
    ///     for marginal sharpness.
    ///   - jpegQuality: passed through to `UIImage.jpegData`. 0.9
    ///     matches the existing image-import path.
    /// - Returns: encoded JPEG bytes ready to feed into the existing
    ///   `store.saveFloorPlan(...)` / `store.replaceFloorPlan(...)`
    ///   call sites.
    static func renderFirstPageToJPEG(from url: URL,
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
        guard let page = document.page(at: 0) else {
            throw FloorPlanPDFImportError.empty
        }

        let mediaBoxSize = page.bounds(for: .mediaBox).size
        guard mediaBoxSize.width > 0, mediaBoxSize.height > 0 else {
            throw FloorPlanPDFImportError.renderFailed
        }

        // Compute the desired pixel size: targetDPI × (size in inches),
        // where 1pt = 1/72in. Clamp the longest edge to maxDimension so
        // E-size sheets (36×48in) cap out instead of pushing 240MB into
        // the renderer.
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

        // autoreleasepool keeps the rasterised UIImage alive only long
        // enough to JPEG-encode; the encoded Data is what we return.
        let jpeg: Data? = autoreleasepool {
            let image = renderer.image { ctx in
                let cg = ctx.cgContext
                // White background — most CAD PDFs use a transparent
                // canvas; rendering directly to a transparent context
                // would produce a JPEG with black pixels.
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(CGRect(origin: .zero, size: pixelSize))
                // PDF coordinates are origin-bottom-left; UIKit is
                // origin-top-left. Flip vertically so the page renders
                // upright.
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
}
