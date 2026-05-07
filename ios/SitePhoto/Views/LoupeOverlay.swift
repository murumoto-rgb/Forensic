import SwiftUI

/// Magnifier loupe shown while dragging to place a calibration point.
/// Renders the image at zoom×fitScale, offset so the pixel under the finger
/// sits at the centre of a clipped circle floated above the finger.
struct LoupeOverlay: View {
    let image: UIImage
    let finger: CGPoint        // current finger position in canvas-local coords
    let imageOriginX: CGFloat  // where the displayed image's top-left sits
    let imageOriginY: CGFloat
    let fitScale: CGFloat      // how the image is aspect-fit into the canvas
    let canvasSize: CGSize

    private let radius: CGFloat = 64
    private let zoom: CGFloat = 3.5

    var body: some View {
        let imgSize = image.size
        let displayedW = imgSize.width * fitScale * zoom
        let displayedH = imgSize.height * fitScale * zoom

        // Image pixel under finger.
        let pxX = (finger.x - imageOriginX) / fitScale
        let pxY = (finger.y - imageOriginY) / fitScale

        // Offset within the loupe so that pixel lands at (radius, radius).
        let loupeImgX = radius - pxX * fitScale * zoom
        let loupeImgY = radius - pxY * fitScale * zoom

        // Float the loupe above the finger. Hop to below if it would clip the top.
        let preferredY = finger.y - radius - 56
        let loupeY: CGFloat
        if preferredY - radius < 8 {
            loupeY = finger.y + radius + 56
        } else {
            loupeY = preferredY
        }
        let loupeX = max(radius + 8, min(canvasSize.width - radius - 8, finger.x))

        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: displayedW, height: displayedH)
                .offset(x: loupeImgX, y: loupeImgY)

            Path { p in
                p.move(to: CGPoint(x: radius - 16, y: radius))
                p.addLine(to: CGPoint(x: radius + 16, y: radius))
                p.move(to: CGPoint(x: radius, y: radius - 16))
                p.addLine(to: CGPoint(x: radius, y: radius + 16))
            }
            .stroke(Color.red, lineWidth: 1.5)

            Circle()
                .stroke(.red.opacity(0.85), lineWidth: 1.5)
                .frame(width: 6, height: 6)
                .position(x: radius, y: radius)
        }
        .frame(width: radius * 2, height: radius * 2)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(.white, lineWidth: 3)
        )
        .shadow(color: .black.opacity(0.5), radius: 6)
        .position(x: loupeX, y: loupeY)
        .allowsHitTesting(false)
    }
}
