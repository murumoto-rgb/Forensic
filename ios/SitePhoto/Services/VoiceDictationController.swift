import Foundation
import Speech
import AVFoundation
import Observation

/// Thin wrapper around `SFSpeechRecognizer` that drives the microphone
/// buttons on `PhotoTagEditorSheet` (caption / observation overrides) and
/// `LocateSheet` (post-capture quick caption). One controller instance is
/// created per text field so multiple fields can co-exist without state
/// trampling — the SwiftUI views observe `isRecording` and `transcript`
/// to drive the UI.
///
/// Speech recognition runs on-device when the model is available
/// (`requiresOnDeviceRecognition = true`) so dictated forensic
/// observations don't leave the device. If the on-device model isn't
/// installed yet, iOS falls back to the cloud recognizer the first time
/// — subsequent uses will be on-device once the model is downloaded.
@MainActor
@Observable
final class VoiceDictationController {
    /// True while the audio engine is running and partial results are
    /// streaming in. SwiftUI binds the mic icon style to this flag.
    var isRecording: Bool = false
    /// Latest accumulated transcript, including any seed text passed to
    /// `start(seed:)`. Updated on the main actor as partial results come
    /// in so the bound TextField updates live.
    var transcript: String = ""
    /// Human-readable error surfaced into the UI when permissions are
    /// denied or the recognizer is unavailable. Nil while everything is OK.
    var error: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer()
    /// Text already in the bound field when recording started — preserved
    /// so new dictation appends rather than replaces.
    private var seed: String = ""

    func start(seed: String = "") async {
        guard !isRecording else { return }
        self.seed = seed
        self.transcript = seed
        self.error = nil

        let speechAuth = await Self.requestSpeechAuth()
        guard speechAuth == .authorized else {
            error = "Speech recognition isn't authorized. Enable it in Settings → SitePhoto → Speech Recognition."
            return
        }
        let micAuth = await Self.requestMicAuth()
        guard micAuth else {
            error = "Microphone access denied. Enable it in Settings → SitePhoto → Microphone."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognizer is unavailable on this device right now. Try again in a moment."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device when the model is installed; iOS automatically
        // falls back to cloud if the device model isn't ready.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let recognized = result.bestTranscription.formattedString
                let combined: String
                if self.seed.isEmpty {
                    combined = recognized
                } else if recognized.isEmpty {
                    combined = self.seed
                } else {
                    let needsSpace = !self.seed.hasSuffix(" ") && !self.seed.hasSuffix("\n")
                    combined = self.seed + (needsSpace ? " " : "") + recognized
                }
                Task { @MainActor in self.transcript = combined }
                if result.isFinal {
                    Task { @MainActor in self.stop() }
                }
            }
            if error != nil {
                Task { @MainActor in self.stop() }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            self.error = "Couldn't start the audio engine: \(error.localizedDescription)"
            tearDown()
        }
    }

    /// Stop recording and release audio resources. Safe to call multiple
    /// times; idempotent.
    func stop() {
        guard isRecording || recognitionTask != nil else { return }
        tearDown()
        isRecording = false
    }

    private func tearDown() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Permission helpers

    private static func requestSpeechAuth() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private static func requestMicAuth() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
