import SwiftUI

/// Magnifier loupe shown while dragging to place a calibration point.
/// Uses Canvas for direct, layout-quirk-free drawing - the image is
/// rasterised at zoom×fitScale, with the pixel under the finger placed
/// at the centre of a circle floated above (or below) the finger.
struct LoupeOverlay: View {
    let image: UIImage
    let finger: CGPoint        // current finger position in canvas-local coords
    let imageOriginX: CGFloat  // where the displayed image's top-left sits in canvas-local
    let imageOriginY: CGFloat
    let fitScale: CGFloat      // how the image is aspect-fit into the canvas
    let canvasSize: CGSize

    private let radius: CGFloat = 64
    private let zoom: CGFloat = 3.5

    var body: some View {
        let preferredY = finger.y - radius - 56
        let loupeY: CGFloat = (preferredY - radius < 8)
            ? finger.y + radius + 56
            : preferredY
        let loupeX = max(radius + 8, min(canvasSize.width - radius - 8, finger.x))

        Canvas { context, size in
            let imgSize = image.size
            let scaledW = imgSize.width * fitScale * zoom
            let scaledH = imgSize.height * fitScale * zoom

            // Position the source image so the pixel under the finger lands at
            // the centre of the loupe canvas.
            let imgX = size.width / 2 - (finger.x - imageOriginX) * zoom
            let imgY = size.height / 2 - (finger.y - imageOriginY) * zoom

            let imgRect = CGRect(x: imgX, y: imgY, width: scaledW, height: scaledH)
            if let cg = image.cgImage {
                context.draw(SwiftUI.Image(decorative: cg, scale: 1, orientation: image.imageOrientation.swiftUIOrientation),
                             in: imgRect)
            }

            // Crosshair at the centre.
            let cx = size.width / 2
            let cy = size.height / 2
            var cross = Path()
            cross.move(to: CGPoint(x: cx - 16, y: cy))
            cross.addLine(to: CGPoint(x: cx + 16, y: cy))
            cross.move(to: CGPoint(x: cx, y: cy - 16))
            cross.addLine(to: CGPoint(x: cx, y: cy + 16))
            context.stroke(cross, with: .color(.red), lineWidth: 1.5)

            // Tiny dot exactly where the point will be set.
            context.stroke(
                Path(ellipseIn: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6)),
                with: .color(.red.opacity(0.85)),
                lineWidth: 1.5
            )
        }
        .frame(width: radius * 2, height: radius * 2)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 3))
        .shadow(color: .black.opacity(0.5), radius: 6)
        .position(x: loupeX, y: loupeY)
        .allowsHitTesting(false)
    }
}

private extension UIImage.Orientation {
    var swiftUIOrientation: SwiftUI.Image.Orientation {
        switch self {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}
