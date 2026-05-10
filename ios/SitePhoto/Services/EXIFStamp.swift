import Foundation
import UIKit

/// Composite a small evidence label onto a JPG — date / time / GPS in the
/// bottom-right corner — and re-encode as JPG. Used by the folder export
/// runner when the user enables the "Burn timestamp + GPS" toggle. Common
/// requirement for forensic-photo / litigation-support work: the metadata
/// has to be visible on the image itself, not just in EXIF where a screen
/// grab would strip it.
///
/// The original file isn't touched. Caller passes a `srcURL` and a `dstURL`;
/// on success the destination contains a re-encoded JPG with the stamp.
/// EXIF metadata on the destination is lost (re-encode); call sites are
/// expected to byte-copy the clean original separately if they need both.
@MainActor
enum EXIFStamp {
    /// Render the stamp directly into an existing `CGContext` — used when
    /// the caller already has a renderer open (e.g. markup compositing
    /// pipeline) and doesn't want to re-decode the photo. Caller is
    /// responsible for having drawn the photo first.
    static func stamp(intoContext ctx: CGContext,
                       imageSize: CGSize,
                       photo: Photo,
                       gps: ProjectGPS?,
                       address: String?) {
        drawLabel(in: ctx,
                   imageSize: imageSize,
                   lines: labelLines(photo: photo, gps: gps, address: address))
    }

    /// Render `srcURL` with a date / GPS label into `dstURL`. Returns true
    /// on success. `gps` and `address` are optional context the caller can
    /// hand in from the project (each photo doesn't currently carry its
    /// own GPS, so we use the project's recorded coordinates as the next-
    /// best stamp).
    @discardableResult
    static func stamp(srcURL: URL,
                       dstURL: URL,
                       photo: Photo,
                       gps: ProjectGPS?,
                       address: String?) -> Bool {
        guard let srcData = try? Data(contentsOf: srcURL),
              let src = UIImage(data: srcData) else { return false }
        let size = src.size
        guard size.width > 0, size.height > 0 else { return false }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let stamped = renderer.image { ctx in
            src.draw(in: CGRect(origin: .zero, size: size))
            drawLabel(in: ctx.cgContext,
                       imageSize: size,
                       lines: labelLines(photo: photo,
                                          gps: gps,
                                          address: address))
        }
        guard let jpeg = stamped.jpegData(compressionQuality: 0.92) else {
            return false
        }
        do {
            try jpeg.write(to: dstURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Build the two- or three-line stamp text: capture timestamp on the
    /// first line, GPS coords on the second, optional address on the third.
    /// Coordinates are formatted to 5 decimals (~1 m precision) which is
    /// the most a phone GPS reliably supplies without faking precision.
    private static func labelLines(photo: Photo,
                                    gps: ProjectGPS?,
                                    address: String?) -> [String] {
        var out: [String] = []
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        out.append(fmt.string(from: photo.timestamp))
        if let gps {
            let coords = String(format: "%.5f° N, %.5f° E", gps.latitude, gps.longitude)
            out.append(coords)
        }
        if let address, !address.isEmpty {
            out.append(address)
        }
        return out
    }

    /// Render the label in the bottom-right with a translucent black plate
    /// behind it so it stays readable over both light and dark photos.
    /// Font size scales with the image's long edge so a 4032×3024 photo
    /// gets a chunky 26pt stamp, while a 1024px thumbnail gets a 7pt one.
    private static func drawLabel(in ctx: CGContext,
                                   imageSize: CGSize,
                                   lines: [String]) {
        guard !lines.isEmpty else { return }
        let longEdge = max(imageSize.width, imageSize.height)
        let fontSize = max(10, longEdge * 0.018)
        let padding: CGFloat = fontSize * 0.6
        let lineGap: CGFloat = fontSize * 0.25
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let textColor = UIColor.white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor
        ]
        let sizes = lines.map { ($0 as NSString).size(withAttributes: attrs) }
        let textWidth = sizes.map(\.width).max() ?? 0
        let textHeight = sizes.reduce(0) { $0 + $1.height }
            + lineGap * CGFloat(max(0, lines.count - 1))
        let plateRect = CGRect(
            x: imageSize.width - textWidth - padding * 2 - fontSize * 0.5,
            y: imageSize.height - textHeight - padding * 2 - fontSize * 0.5,
            width: textWidth + padding * 2,
            height: textHeight + padding * 2
        )
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(plateRect)
        var y = plateRect.minY + padding
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(
                at: CGPoint(x: plateRect.minX + padding, y: y),
                withAttributes: attrs
            )
            y += sizes[i].height + lineGap
        }
    }
}
