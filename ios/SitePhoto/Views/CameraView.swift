import AVFoundation
import SwiftUI

struct CameraView: View {
    let onCapture: (CapturedPhoto) -> Void
    let onCancel: () -> Void

    @State private var controller = CameraController()
    @State private var setupError: String?
    @State private var capturing = false
    @State private var flashTrigger = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let err = setupError {
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
            } else {
                CameraPreviewView(session: controller.session)
                    .ignoresSafeArea()

                if flashTrigger {
                    Color.white
                        .ignoresSafeArea()
                        .opacity(0.6)
                        .transition(.opacity)
                }

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
        }
        .task {
            do {
                try await controller.configure()
            } catch {
                setupError = (error as? CameraError)?.errorDescription ?? "\(error)"
            }
        }
        .onDisappear { controller.stop() }
    }

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
            }
            Spacer()
            if controller.configured {
                flashBar
            }
            Spacer()
            // symmetric placeholder
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.top, 8)
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
        }
    }

    private func label(for mode: FlashMode) -> String {
        switch mode {
        case .auto: return "AUTO"
        case .on: return "ON"
        case .off: return "OFF"
        }
    }

    private func zoomLabel(_ z: Double) -> String {
        if z == floor(z) { return "\(Int(z))x" }
        return String(format: "%.1fx", z)
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

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
