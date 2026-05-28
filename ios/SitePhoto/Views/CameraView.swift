import AVFoundation
import SwiftUI
import UIKit

struct CameraView: View {
    let onCapture: (CapturedPhoto) -> Void
    let onCancel: () -> Void

    @State private var controller = CameraController()
    @State private var motion = CameraMotionService()
    @State private var setupError: String?
    @State private var capturing = false
    @State private var flashTrigger = false

    /// Focus reticle position in CameraView's local coordinate space.
    /// Set when the user taps the preview; auto-clears after ~1s.
    @State private var focusReticle: CGPoint?
    @State private var focusReticleHideTask: Task<Void, Never>?

    /// Last valid physical orientation reported by `UIDevice`. We ignore
    /// `.faceUp`/`.faceDown`/`.unknown` so the controls don't snap around
    /// when the engineer puts the phone down on a table mid-capture.
    @State private var physicalOrientation: UIDeviceOrientation = .portrait

    @AppStorage("sitephoto.capture48MP") private var capture48MP: Bool = true
    @AppStorage("sitephoto.camera.showGrid") private var showGrid: Bool = false
    @AppStorage("sitephoto.camera.showLevel") private var showLevel: Bool = false

    var body: some View {
        GeometryReader { geo in
            let canvasIsLandscape = geo.size.width > geo.size.height

            ZStack {
                Color.black.ignoresSafeArea()

                if let err = setupError {
                    errorView(err)
                } else {
                    CameraPreviewView(
                        session: controller.session,
                        onTap: { viewPoint, devicePoint in
                            handleTap(viewPoint: viewPoint, devicePoint: devicePoint)
                        }
                    )
                    .ignoresSafeArea()

                    if showGrid {
                        GridOverlay()
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                    if showLevel {
                        LevelOverlay(rollRadians: motion.rollRadians)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }

                    if let reticle = focusReticle {
                        FocusReticle()
                            .position(reticle)
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale))
                    }

                    if flashTrigger {
                        Color.white
                            .ignoresSafeArea()
                            .opacity(0.6)
                            .transition(.opacity)
                    }

                    if canvasIsLandscape {
                        landscapeControls
                    } else {
                        portraitControls
                    }
                }
            }
        }
        .task {
            do {
                try await controller.configure()
                // Push whatever the device is doing right now onto the
                // capture connection so the very first shot is right-way-up.
                updateOrientation(initial: true)
                if showLevel {
                    motion.start()
                }
            } catch {
                setupError = (error as? CameraError)?.errorDescription ?? "\(error)"
            }
        }
        .onChange(of: showLevel) { _, on in
            if on { motion.start() } else { motion.stop() }
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onDisappear {
            controller.stop()
            motion.stop()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIDevice.orientationDidChangeNotification
            )
        ) { _ in
            updateOrientation()
        }
        .animation(.easeOut(duration: 0.2), value: focusReticle)
        .animation(.easeInOut(duration: 0.2), value: physicalOrientation)
    }

    // MARK: - Orientation

    /// Pull the latest `UIDevice.current.orientation`, filter out the
    /// face-up/face-down/unknown values, and push the result onto both
    /// the local state (drives the controls layout + glyph rotation) and
    /// the controller (drives the saved-JPEG orientation).
    private func updateOrientation(initial: Bool = false) {
        let o = UIDevice.current.orientation
        let resolved: UIDeviceOrientation
        if o.isPortrait || o.isLandscape {
            resolved = o
        } else if initial {
            // First sample before the user has moved the device:
            // assume portrait so the capture connection has a defined
            // angle. Later orientation events will refine this.
            resolved = .portrait
        } else {
            return
        }
        physicalOrientation = resolved
        controller.captureOrientation = resolved
    }

    /// Rotation applied to individual glyphs (text + SF Symbol icons) so
    /// they read upright from the user's POV. The SwiftUI canvas already
    /// rotates with the device for landscape (iPhone defaults include
    /// both landscape orientations), so glyphs are naturally upright
    /// there. For `.portraitUpsideDown` the iPhone keeps the canvas in
    /// portrait coords, so glyphs need a manual 180° spin to stay
    /// readable for an engineer holding the phone upside-down.
    private var glyphRotation: Angle {
        physicalOrientation == .portraitUpsideDown ? .degrees(180) : .zero
    }

    // MARK: - Layouts

    @ViewBuilder
    private func errorView(_ err: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 56))
            Text("Camera unavailable")
                .font(.headline)
            Text(err)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Close") { onCancel() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .foregroundStyle(.white)
    }

    /// Portrait + upside-down layout: top bar at canvas top, shutter
    /// cluster at canvas bottom. In upside-down the SwiftUI canvas stays
    /// portrait (iPhone default doesn't rotate to upside-down), so the
    /// shutter still sits at the device's hardware-bottom — i.e. the
    /// charger end, exactly under the user's thumb. Glyph rotation is
    /// handled per-element via `glyphRotation`.
    private var portraitControls: some View {
        VStack {
            topBar
            Spacer()
            if controller.configured {
                zoomBar
            }
            bottomBar
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }

    /// Landscape layout: the SwiftUI canvas rotates with the device, so
    /// canvas-top = user's top. The shutter still needs to sit at the
    /// device's charger end — which is on the user's right in
    /// landscape-left (home button on right) and on the user's left in
    /// landscape-right. Glyphs are upright for free since SwiftUI has
    /// rotated the whole UI to match the user's POV.
    private var landscapeControls: some View {
        let shutterTrailing = (physicalOrientation == .landscapeLeft)
        return HStack {
            if shutterTrailing {
                topBar
                Spacer()
                if controller.configured {
                    zoomBar
                }
                bottomBar
            } else {
                bottomBar
                if controller.configured {
                    zoomBar
                }
                Spacer()
                topBar
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack {
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.5), in: Circle())
                    .rotationEffect(glyphRotation)
            }
            Spacer()
            if controller.configured {
                flashBar
            }
            Spacer()
            if controller.configured {
                overlayToggles
            } else {
                // Symmetric placeholder so the flash bar stays centered.
                Color.clear.frame(width: 96, height: 32)
            }
        }
        .padding(.top, 8)
    }

    private var overlayToggles: some View {
        HStack(spacing: 6) {
            overlayToggle(
                icon: "grid",
                isOn: showGrid,
                accessibilityLabel: showGrid ? "Hide grid" : "Show grid"
            ) {
                showGrid.toggle()
                Haptics.tap()
            }
            overlayToggle(
                icon: "level",
                isOn: showLevel,
                accessibilityLabel: showLevel ? "Hide level" : "Show level"
            ) {
                showLevel.toggle()
                Haptics.tap()
            }
            if controller.supports48MP {
                resolutionToggle
            }
        }
    }

    @ViewBuilder
    private func overlayToggle(icon: String,
                                 isOn: Bool,
                                 accessibilityLabel: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.bold())
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    isOn ? Color.yellow : Color.black.opacity(0.5),
                    in: Capsule()
                )
                .foregroundStyle(isOn ? .black : .white)
                .rotationEffect(glyphRotation)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var resolutionToggle: some View {
        Button {
            capture48MP.toggle()
        } label: {
            Text(capture48MP ? "48MP" : "24MP")
                .font(.caption.bold().monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    capture48MP ? Color.yellow : Color.black.opacity(0.5),
                    in: Capsule()
                )
                .foregroundStyle(capture48MP ? .black : .white)
                .rotationEffect(glyphRotation)
        }
    }

    private var flashBar: some View {
        HStack(spacing: 6) {
            ForEach(FlashMode.allCases, id: \.self) { mode in
                Button {
                    controller.flashMode = mode
                } label: {
                    Text(label(for: mode))
                        .font(.caption.bold().monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            controller.flashMode == mode ? Color.white : Color.black.opacity(0.5),
                            in: Capsule()
                        )
                        .foregroundStyle(controller.flashMode == mode ? .black : .white)
                        .rotationEffect(glyphRotation)
                }
            }
        }
    }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            ForEach(controller.availableUserZooms, id: \.self) { z in
                Button {
                    controller.setUserZoom(z)
                } label: {
                    Text(zoomLabel(z))
                        .font(.caption.bold().monospaced())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            controller.userZoom == z ? Color.white : Color.black.opacity(0.5),
                            in: Capsule()
                        )
                        .foregroundStyle(controller.userZoom == z ? .black : .white)
                        .rotationEffect(glyphRotation)
                }
            }
        }
        .padding(.bottom, 12)
    }

    private var bottomBar: some View {
        HStack {
            Color.clear.frame(width: 60, height: 60)
            Spacer()
            Button {
                Task { await capture() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 5).frame(width: 76, height: 76)
                    Circle().fill(.white).frame(width: 60, height: 60)
                }
                .opacity(capturing ? 0.5 : 1)
            }
            .disabled(capturing)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if controller.configured {
                    Text("LENS")
                        .font(.caption2.bold().monospaced())
                        .foregroundStyle(.white.opacity(0.6))
                    Text(controller.lensName.uppercased())
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 80, alignment: .trailing)
            .rotationEffect(glyphRotation)
        }
    }

    private func label(for mode: FlashMode) -> String {
        switch mode {
        case .auto: return "AUTO"
        case .on:   return "ON"
        case .off:  return "OFF"
        }
    }

    private func zoomLabel(_ z: Double) -> String {
        if z == floor(z) { return "\(Int(z))x" }
        return String(format: "%.1fx", z)
    }

    private func handleTap(viewPoint: CGPoint, devicePoint: CGPoint) {
        controller.setFocusAndExposure(at: devicePoint)
        Haptics.tap()
        focusReticle = viewPoint
        focusReticleHideTask?.cancel()
        focusReticleHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            focusReticle = nil
        }
    }

    private func capture() async {
        capturing = true
        defer { capturing = false }
        withAnimation(.easeOut(duration: 0.08)) { flashTrigger = true }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.15)) { flashTrigger = false }
        }
        do {
            let data = try await controller.capture()
            let captured = CapturedPhoto(
                data: data,
                userZoom: controller.userZoom,
                lensName: controller.lensName,
                flashMode: controller.flashMode
            )
            onCapture(captured)
        } catch {
            setupError = (error as? CameraError)?.errorDescription ?? "\(error)"
        }
    }
}

/// Rule-of-thirds grid drawn over the preview. Two horizontal lines at
/// 1/3 and 2/3 of the height, two verticals at 1/3 and 2/3 of the width
/// — the standard photographer's overlay for composition.
private struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                // Horizontals
                path.move(to: CGPoint(x: 0, y: h / 3))
                path.addLine(to: CGPoint(x: w, y: h / 3))
                path.move(to: CGPoint(x: 0, y: 2 * h / 3))
                path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
                // Verticals
                path.move(to: CGPoint(x: w / 3, y: 0))
                path.addLine(to: CGPoint(x: w / 3, y: h))
                path.move(to: CGPoint(x: 2 * w / 3, y: 0))
                path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

/// Horizon-level indicator centred on the preview. Two short horizontal
/// bars — a reference bar fixed to true horizon (vertical centre of the
/// screen) and an indicator bar that tilts with the device. They turn
/// green and snap together when the device is within ~1° of level.
private struct LevelOverlay: View {
    let rollRadians: Double

    private let nearLevelThreshold: Double = 1 * .pi / 180  // 1°

    var body: some View {
        let isLevel = abs(rollRadians) < nearLevelThreshold
        ZStack {
            // Fixed reference bar — always horizontal.
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 70, height: 1.5)
            // Tilting indicator bar — rotates against device roll so it
            // always points to the true horizon from the user's POV.
            Rectangle()
                .fill(isLevel ? Color.green : Color.yellow)
                .frame(width: 140, height: 2)
                .rotationEffect(.radians(-rollRadians))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Animated reticle that briefly appears at the tap point when the
/// engineer focuses on a region. Yellow stroke, scales in then fades
/// out — same visual treatment as the system Camera app.
private struct FocusReticle: View {
    var body: some View {
        Rectangle()
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 78, height: 78)
            .overlay(
                Rectangle()
                    .stroke(Color.yellow.opacity(0.7), lineWidth: 1)
                    .frame(width: 100, height: 100)
            )
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Tap callback. The first arg is the tap location in the view's
    /// own coordinate space (used for the reticle position); the second
    /// is the device-space [0,1] normalised point obtained through the
    /// preview layer, which is what `AVCaptureDevice` expects for
    /// focus/exposure POIs.
    let onTap: (_ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        // Letterbox to the captured aspect rather than crop-fill. With
        // .resizeAspectFill the live preview was showing a tighter crop
        // than the saved JPEG, so what the engineer framed wasn't what
        // they got — switching to .resizeAspect makes preview and capture
        // line up. Black bars fill the unused screen area.
        v.previewLayer.videoGravity = .resizeAspect
        context.coordinator.view = v
        context.coordinator.onTap = onTap
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handleTap(_:)))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var view: PreviewUIView?
        var onTap: ((CGPoint, CGPoint) -> Void)?

        @objc func handleTap(_ sender: UITapGestureRecognizer) {
            guard let view, let onTap else { return }
            let viewPoint = sender.location(in: view)
            let devicePoint = view.previewLayer
                .captureDevicePointConverted(fromLayerPoint: viewPoint)
            onTap(viewPoint, devicePoint)
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
