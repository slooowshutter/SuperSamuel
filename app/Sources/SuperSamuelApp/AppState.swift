import Foundation
import SwiftUI

enum DictationPhase: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var waveformSamples: [CGFloat] = Array(repeating: 0, count: 96)
    @Published var transcriptText = "Press Option+Space to start dictation."
    @Published var attachedScreenshot: AttachedScreenshot?
    @Published var screenshotStatusMessage: String?
    @Published var isCapturingScreenshot = false
    @Published var showsRecoveryActions = false
    @Published var recordingDeviceName: String?
    @Published var captureStatusMessage: String?
    @Published var livePreviewRequiresFinalization = false

    private let maxWaveSamples = 96

    func setPhase(_ phase: DictationPhase) {
        self.phase = phase
    }

    func setElapsed(seconds: TimeInterval) {
        elapsedSeconds = max(0, seconds)
    }

    func pushLevel(_ level: Float) {
        let clamped = CGFloat(min(max(level, 0), 1))
        waveformSamples.append(clamped)
        if waveformSamples.count > maxWaveSamples {
            waveformSamples.removeFirst(waveformSamples.count - maxWaveSamples)
        }
    }

    func setTranscriptPreview(fullText: String) {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcriptText = "No speech was detected."
            return
        }

        transcriptText = trimmed

    }

    func setProgressMessage(_ message: String) {
        transcriptText = message
    }

    func resetForRecording(deviceName: String) {
        setPhase(.recording)
        setElapsed(seconds: 0)
        waveformSamples = Array(repeating: 0, count: maxWaveSamples)
        transcriptText = "Recording locally..."
        recordingDeviceName = deviceName
        captureStatusMessage = nil
        livePreviewRequiresFinalization = false
        attachedScreenshot = nil
        screenshotStatusMessage = nil
        isCapturingScreenshot = false
        showsRecoveryActions = false
    }

}
