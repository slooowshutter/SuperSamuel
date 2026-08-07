import Foundation
import SwiftUI

enum DictationPhase: Equatable {
    case idle
    case recording
    case transcribing
    case enhancing
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var waveformSamples: [CGFloat] = Array(repeating: 0, count: 96)
    @Published var transcriptPreviewLines: [String] = ["Press Option+Space to start dictation."]
    @Published var enhancementEnabled = true
    @Published var attachedScreenshot: AttachedScreenshot?
    @Published var screenshotStatusMessage: String?
    @Published var isCapturingScreenshot = false
    @Published var showsRecoveryActions = false
    @Published var recordingDeviceName: String?

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
            transcriptPreviewLines = ["No speech was detected."]
            return
        }

        let lines = wrappedPreviewLines(from: trimmed, maxCharsPerLine: 56)
        if lines.isEmpty {
            transcriptPreviewLines = [trimmed]
            return
        }

        transcriptPreviewLines = Array(lines.suffix(3))
    }

    func setProgressMessage(_ message: String) {
        transcriptPreviewLines = [message]
    }

    func resetForRecording(deviceName: String) {
        setPhase(.recording)
        setElapsed(seconds: 0)
        waveformSamples = Array(repeating: 0, count: maxWaveSamples)
        transcriptPreviewLines = ["Recording locally..."]
        recordingDeviceName = deviceName
        attachedScreenshot = nil
        screenshotStatusMessage = nil
        isCapturingScreenshot = false
        showsRecoveryActions = false
    }

    private func wrappedPreviewLines(from text: String, maxCharsPerLine: Int) -> [String] {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)

        var result: [String] = []

        for paragraph in paragraphs {
            let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if words.isEmpty {
                continue
            }

            var current = ""
            for word in words {
                if word.count > maxCharsPerLine {
                    if !current.isEmpty {
                        result.append(current)
                        current = ""
                    }

                    var start = word.startIndex
                    while start < word.endIndex {
                        let end = word.index(start, offsetBy: maxCharsPerLine, limitedBy: word.endIndex) ?? word.endIndex
                        result.append(String(word[start..<end]))
                        start = end
                    }
                    continue
                }

                if current.isEmpty {
                    current = word
                } else if current.count + 1 + word.count <= maxCharsPerLine {
                    current += " " + word
                } else {
                    result.append(current)
                    current = word
                }
            }

            if !current.isEmpty {
                result.append(current)
            }
        }

        return result
    }
}
