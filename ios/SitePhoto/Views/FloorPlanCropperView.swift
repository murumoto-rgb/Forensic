import SwiftUI
import UIKit

/// Skippable image-crop step shown after a floor-plan source (image or
/// rasterised PDF page) is picked, before calibration. Lets the
/// engineer trim margins, title blocks, or extra rooms off a sheet so
/// the calibration tap-points and bubble positions all map to the
/// region they care about.
///
/// Defaults to "no crop" — the rect starts at full image bounds and a
/// "Use Full Image" button skips through with the source untouched.
/// "Apply Crop" runs `UIGraphicsImageRenderer` at the chosen sub-rect
/// and emits a JPEG at quality 0.9 (matching the rest of the floor-
/// plan import path). Either way the parent receives `Data` ready to
/// drop into `addFloorPlan` / `replaceFloorPlan`.
struct FloorPlanCropperView: View {
    let imageData: Data
    let onUse: (Data) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sourceImage: UIImage?
    /// Crop rect in *image-pixel* coordinates. Initialised once the
    /// source image loads; reset to full-image on "Reset".
    @State private var cropRect: CGRect?
    /// Active gesture state per handle so we can compute deltas
    /// against the rect at gesture-start without committing partial
    /// values. `nil` when no drag is in flight.
    @State private var dragAnchor: CGRect?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let img = sourceImage, let rect = cropRect {
                        GeometryReader { geo in
                            cropCanvas(geo: geo, image: img, rect: rect)
                        }
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
                footerBar
            }
            .navigationTitle("Crop Floor Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use Full Image") {
                        useFullImage()
                    }
                }
            }
            .task { await loadImage() }
        }
    }

    /// Footer with explicit labelled buttons. Lives outside the
    /// `.toolbar` modifier because iOS's `.bottomBar` placement
    /// collapses Button + Label combos to icon-only on iPhone when
    /// space is tight — which made the "Apply Crop" button render as
    /// just a small `crop` symbol with no text, leaving engineers
    /// guessing what it did.
    @ViewBuilder
    private var footerBar: some View {
        HStack(spacing: 12) {
            Button {
                resetCropRect()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(isAtInitialRect)
            Spacer()
            Button {
                applyCrop()
            } label: {
                Label("Apply Crop", systemImage: "crop")
                    .font(.callout.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Canvas

    @ViewBuilder
    private func cropCanvas(geo: GeometryProxy, image: UIImage, rect: CGRect) -> some View {
        let imgSize = image.size
        let fit = min(geo.size.width / max(1, imgSize.width),
                      geo.size.height / max(1, imgSize.height))
        let dispW = imgSize.width  * fit
        let dispH = imgSize.height * fit
        let originX = (geo.size.width  - dispW) / 2
        let originY = (geo.size.height - dispH) / 2

        // Crop rect mapped from image-pixel space → screen-point space.
        let rectOnScreen = CGRect(
            x: originX + rect.minX * fit,
            y: originY + rect.minY * fit,
            width:  rect.width  * fit,
            height: rect.height * fit
        )

        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: dispW, height: dispH)
                .offset(x: originX, y: originY)

            // Dim everything outside the crop rect.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: geo.size))
                p.addRect(rectOnScreen)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Crop rect outline.
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: rectOnScreen.width, height: rectOnScreen.height)
                .position(x: rectOnScreen.midX, y: rectOnScreen.midY)
                .allowsHitTesting(false)

            // Drag-to-pan the whole rect from inside it.
            Color.clear
                .frame(width: rectOnScreen.width, height: rectOnScreen.height)
                .contentShape(Rectangle())
                .position(x: rectOnScreen.midX, y: rectOnScreen.midY)
                .gesture(panGesture(fit: fit, image: image))

            // Eight handles — corners + midpoints.
            ForEach(Handle.allCases, id: \.self) { handle in
                handleView(handle: handle, on: rectOnScreen)
                    .gesture(handleGesture(handle: handle, fit: fit, image: image))
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func handleView(handle: Handle, on rect: CGRect) -> some View {
        let pt = handle.point(in: rect)
        Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
            .overlay(
                Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.5)
            )
            .position(pt)
    }

    // MARK: - Gestures

    private func panGesture(fit: CGFloat, image: UIImage) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragAnchor == nil { dragAnchor = cropRect }
                guard let anchor = dragAnchor else { return }
                let dxImg = value.translation.width / fit
                let dyImg = value.translation.height / fit
                var moved = anchor.offsetBy(dx: dxImg, dy: dyImg)
                // Clamp inside the source image bounds so the user
                // can't drag the rect off-screen.
                moved.origin.x = max(0, min(image.size.width  - moved.width,  moved.origin.x))
                moved.origin.y = max(0, min(image.size.height - moved.height, moved.origin.y))
                cropRect = moved
            }
            .onEnded { _ in
                dragAnchor = nil
            }
    }

    private func handleGesture(handle: Handle,
                                 fit: CGFloat,
                                 image: UIImage) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragAnchor == nil { dragAnchor = cropRect }
                guard let anchor = dragAnchor else { return }
                let dxImg = value.translation.width  / fit
                let dyImg = value.translation.height / fit
                cropRect = handle.applied(to: anchor, dx: dxImg, dy: dyImg, image: image)
            }
            .onEnded { _ in
                dragAnchor = nil
            }
    }

    // MARK: - Image loading + crop

    private func loadImage() async {
        guard let img = UIImage(data: imageData) else { return }
        await MainActor.run {
            sourceImage = img
            cropRect = Self.initialCropRect(for: img)
        }
    }

    /// Inset the starting crop rect away from the image edges so the
    /// corner handles aren't pinned to the screen border — engineers
    /// reported the edge-pinned corners were hard to drag. ~8% of the
    /// shorter dimension or 60 image-pixels, whichever is smaller, so
    /// small and giant images both get a sensible margin.
    private static func initialCropRect(for image: UIImage) -> CGRect {
        let w = image.size.width
        let h = image.size.height
        let shorter = min(w, h)
        let inset = min(shorter * 0.08, 60)
        return CGRect(
            x: inset,
            y: inset,
            width:  max(20, w - 2 * inset),
            height: max(20, h - 2 * inset)
        )
    }

    private func resetCropRect() {
        guard let img = sourceImage else { return }
        cropRect = Self.initialCropRect(for: img)
    }

    /// True when the rect hasn't been moved from its initial inset
    /// position. Drives the Reset button's disabled state — Reset
    /// only makes sense if the engineer has actually moved a handle.
    private var isAtInitialRect: Bool {
        guard let img = sourceImage, let rect = cropRect else { return true }
        return rect == Self.initialCropRect(for: img)
    }

    private func useFullImage() {
        // Skip path — emit the original bytes unchanged so we keep the
        // PDF rasteriser's quality / orientation pass intact.
        onUse(imageData)
        dismiss()
    }

    private func applyCrop() {
        guard let img = sourceImage, let rect = cropRect else {
            useFullImage()
            return
        }
        let snapped = CGRect(
            x: max(0, rect.origin.x.rounded()),
            y: max(0, rect.origin.y.rounded()),
            width:  min(img.size.width  - rect.origin.x.rounded(),  rect.width.rounded()),
            height: min(img.size.height - rect.origin.y.rounded(),  rect.height.rounded())
        )
        guard snapped.width > 0, snapped.height > 0 else {
            useFullImage()
            return
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: snapped.size, format: format)
        let cropped: Data? = autoreleasepool {
            let outImage = renderer.image { _ in
                img.draw(at: CGPoint(x: -snapped.origin.x,
                                       y: -snapped.origin.y))
            }
            return outImage.jpegData(compressionQuality: 0.9)
        }
        if let data = cropped {
            onUse(data)
        } else {
            onUse(imageData)
        }
        dismiss()
    }
}

// MARK: - Resize handles

/// One of the eight drag handles on a rect — four corners + four edge
/// midpoints. The `applied(to:dx:dy:image:)` helper does all the rect
/// math + clamping so the canvas code doesn't switch on the handle
/// type for every gesture frame.
private enum Handle: CaseIterable {
    case topLeft, top, topRight
    case left,           right
    case bottomLeft, bottom, bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Apply a drag translation (in *image-pixel* units) to `rect` for
    /// this handle, clamping so the rect never inverts and stays
    /// inside the source image. Minimum 20px in either dimension so
    /// the handles don't vanish on top of each other.
    func applied(to rect: CGRect, dx: CGFloat, dy: CGFloat, image: UIImage) -> CGRect {
        let minDim: CGFloat = 20
        let maxX = image.size.width
        let maxY = image.size.height
        var out = rect

        let left   = max(0, min(rect.maxX - minDim, rect.minX + dx))
        let right  = max(rect.minX + minDim, min(maxX, rect.maxX + dx))
        let top    = max(0, min(rect.maxY - minDim, rect.minY + dy))
        let bottom = max(rect.minY + minDim, min(maxY, rect.maxY + dy))

        switch self {
        case .topLeft:
            out.origin.x = left;  out.size.width  = rect.maxX - left
            out.origin.y = top;   out.size.height = rect.maxY - top
        case .top:
            out.origin.y = top;   out.size.height = rect.maxY - top
        case .topRight:
            out.size.width  = right - rect.minX
            out.origin.y = top;   out.size.height = rect.maxY - top
        case .left:
            out.origin.x = left;  out.size.width  = rect.maxX - left
        case .right:
            out.size.width  = right - rect.minX
        case .bottomLeft:
            out.origin.x = left;  out.size.width  = rect.maxX - left
            out.size.height = bottom - rect.minY
        case .bottom:
            out.size.height = bottom - rect.minY
        case .bottomRight:
            out.size.width  = right - rect.minX
            out.size.height = bottom - rect.minY
        }
        return out
    }
}
