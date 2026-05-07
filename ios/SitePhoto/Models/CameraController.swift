import AVFoundation
import Foundation
import Observation

enum CameraError: LocalizedError {
    case denied
    case noBackCamera
    case cannotAddInput
    case cannotAddOutput
    case captureFailed(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Camera permission denied. Open Settings → SitePhoto → Camera to allow."
        case .noBackCamera:
            return "No back camera found on this device."
        case .cannotAddInput:
            return "Could not attach the camera input to the capture session."
        case .cannotAddOutput:
            return "Could not attach the photo output to the capture session."
        case .captureFailed(let msg):
            return "Capture failed: \(msg)"
        case .notConfigured:
            return "Camera is not configured."
        }
    }
}

struct CapturedPhoto {
    let data: Data
    let userZoom: Double
    let lensName: String
    let flashMode: FlashMode
}

@MainActor
@Observable
final class CameraController: NSObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private(set) var currentDevice: AVCaptureDevice?
    private(set) var multiplier: Double = 1.0
    private(set) var availableUserZooms: [Double] = [1.0]
    private(set) var lensName: String = "wide"
    private(set) var configured: Bool = false

    var userZoom: Double = 1.0
    var flashMode: FlashMode = .auto

    private var captureContinuation: CheckedContinuation<Data, Error>?
    private let sessionQueue = DispatchQueue(label: "sitephoto.camera.session")

    /// Configure the capture session and start running.
    func configure() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let ok = await AVCaptureDevice.requestAccess(for: .video)
            if !ok { throw CameraError.denied }
        } else if status == .denied || status == .restricted {
            throw CameraError.denied
        }

        // Pick the best back camera, prefer virtual devices that switch lenses.
        let device: AVCaptureDevice
        if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
            device = triple
            multiplier = 2.0
            availableUserZooms = [0.5, 1, 2, 4, 8]
        } else if let dualWide = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
            device = dualWide
            multiplier = 2.0
            availableUserZooms = [0.5, 1, 2, 4, 8]
        } else if let dual = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
            device = dual
            multiplier = 1.0
            availableUserZooms = [1, 2, 4, 8]
        } else if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            device = wide
            multiplier = 1.0
            availableUserZooms = [1, 2, 4, 8]
        } else {
            throw CameraError.noBackCamera
        }
        currentDevice = device

        // Configure the session.
        let session = self.session
        let photoOutput = self.photoOutput
        session.beginConfiguration()
        session.sessionPreset = .photo

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw CameraError.cannotAddOutput
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let activeFormat = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = activeFormat
        }

        session.commitConfiguration()

        // Apply initial zoom (1x in user-facing terms).
        try applyUserZoom(1.0)

        // Start session on a background queue so the UI thread is not blocked.
        sessionQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
        }

        configured = true
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func setUserZoom(_ z: Double) {
        guard availableUserZooms.contains(z) else { return }
        try? applyUserZoom(z)
    }

    private func applyUserZoom(_ z: Double) throws {
        guard let device = currentDevice else { throw CameraError.notConfigured }
        let target = z * multiplier
        let clamped = max(device.minAvailableVideoZoomFactor,
                          min(device.maxAvailableVideoZoomFactor, target))
        try device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        userZoom = z
        updateLensName(deviceZoom: clamped)
    }

    private func updateLensName(deviceZoom: CGFloat) {
        guard let device = currentDevice else { return }
        let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
        if switchovers.isEmpty {
            lensName = "wide"
        } else if deviceZoom < switchovers[0] {
            lensName = "ultrawide"
        } else if switchovers.count > 1 && deviceZoom >= switchovers[1] {
            lensName = "telephoto"
        } else {
            lensName = "wide"
        }
    }

    /// Capture one photo and return the encoded data (JPEG/HEIC).
    func capture() async throws -> Data {
        guard configured else { throw CameraError.notConfigured }

        let settings = AVCapturePhotoSettings()
        let av = avFlashMode(flashMode)
        if photoOutput.supportedFlashModes.contains(av) {
            settings.flashMode = av
        }
        settings.photoQualityPrioritization = .quality

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            captureContinuation = cont
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func avFlashMode(_ m: FlashMode) -> AVCaptureDevice.FlashMode {
        switch m {
        case .auto: return .auto
        case .on: return .on
        case .off: return .off
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        Task { @MainActor in
            if let error {
                self.captureContinuation?.resume(throwing: error)
                self.captureContinuation = nil
                return
            }
            guard let data = photo.fileDataRepresentation() else {
                self.captureContinuation?.resume(throwing: CameraError.captureFailed("no data"))
                self.captureContinuation = nil
                return
            }
            self.captureContinuation?.resume(returning: data)
            self.captureContinuation = nil
        }
    }
}
