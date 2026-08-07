import AVFoundation
import Foundation

enum AudioModelInputPreparationError: LocalizedError {
    case conversionUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .conversionUnavailable:
            return "The recording could not be converted for the selected audio model."
        case .conversionFailed(let message):
            return "Audio conversion failed: \(message)"
        }
    }
}

struct PreparedAudioModelInput: Sendable {
    let audio: RecordedAudio
    let temporaryFileURL: URL?

    func removeTemporaryFile() {
        guard let temporaryFileURL else {
            return
        }
        try? FileManager.default.removeItem(at: temporaryFileURL)
    }
}

/// Keeps durable recordings compact as AAC, but gives chat-audio providers the
/// broadly supported PCM WAV input used by the benchmark.
enum AudioModelInputPreparer {
    static func prepare(
        _ audio: RecordedAudio,
        for model: String
    ) async throws -> PreparedAudioModelInput {
        guard requiresWAV(model: model), audio.format.lowercased() != "wav" else {
            return PreparedAudioModelInput(audio: audio, temporaryFileURL: nil)
        }

        return try await Task.detached(priority: .utility) {
            try convertToWAV(audio)
        }.value
    }

    private static func requiresWAV(model: String) -> Bool {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.hasPrefix("openai/gpt-audio") ||
            model.hasPrefix("mistralai/voxtral")
    }

    private static func convertToWAV(
        _ audio: RecordedAudio
    ) throws -> PreparedAudioModelInput {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SuperSamuel/AudioModelInput", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try? fileManager.removeItem(at: outputURL)

        do {
            let inputFile: AVAudioFile
            do {
                inputFile = try AVAudioFile(forReading: audio.fileURL)
            } catch {
                throw detailedFailure(stage: "opening input", error: error)
            }
            guard
                let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                ),
                let converter = AVAudioConverter(
                    from: inputFile.processingFormat,
                    to: outputFormat
                )
            else {
                throw AudioModelInputPreparationError.conversionUnavailable
            }

            let outputFile: AVAudioFile
            do {
                outputFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: outputFormat.settings,
                    commonFormat: .pcmFormatInt16,
                    interleaved: false
                )
            } catch {
                throw detailedFailure(stage: "creating WAV", error: error)
            }
            let outputFrameCapacity: AVAudioFrameCount = 4_096
            var reachedEnd = false
            var inputReadError: Error?
            var lastRequestedFrames: AVAudioFrameCount = 0

            while true {
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: outputFrameCapacity
                ) else {
                    throw AudioModelInputPreparationError.conversionUnavailable
                }

                var conversionError: NSError?
                let status = converter.convert(
                    to: outputBuffer,
                    error: &conversionError
                ) { requestedFrames, inputStatus in
                    lastRequestedFrames = requestedFrames
                    if reachedEnd {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }

                    let remainingFrames = inputFile.length - inputFile.framePosition
                    guard remainingFrames > 0 else {
                        reachedEnd = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    let framesToRead = AVAudioFrameCount(
                        min(AVAudioFramePosition(requestedFrames), remainingFrames)
                    )

                    guard let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: inputFile.processingFormat,
                        frameCapacity: framesToRead
                    ) else {
                        inputStatus.pointee = .noDataNow
                        inputReadError = AudioModelInputPreparationError.conversionUnavailable
                        return nil
                    }

                    do {
                        try inputFile.read(into: inputBuffer, frameCount: framesToRead)
                    } catch {
                        inputStatus.pointee = .noDataNow
                        inputReadError = error
                        return nil
                    }

                    guard inputBuffer.frameLength > 0 else {
                        reachedEnd = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }

                    inputStatus.pointee = .haveData
                    return inputBuffer
                }

                if let inputReadError {
                    throw detailedFailure(
                        stage: "reading \(lastRequestedFrames) input frames",
                        error: inputReadError
                    )
                }
                if let conversionError {
                    throw detailedFailure(stage: "converting samples", error: conversionError)
                }
                if outputBuffer.frameLength > 0 {
                    do {
                        try outputFile.write(from: outputBuffer)
                    } catch {
                        throw detailedFailure(stage: "writing WAV", error: error)
                    }
                }

                if status == .endOfStream || (reachedEnd && outputBuffer.frameLength == 0) {
                    break
                }
                if status == .error {
                    throw AudioModelInputPreparationError.conversionUnavailable
                }
            }

            return PreparedAudioModelInput(
                audio: RecordedAudio(
                    fileURL: outputURL,
                    format: "wav",
                    mimeType: "audio/wav"
                ),
                temporaryFileURL: outputURL
            )
        } catch {
            try? fileManager.removeItem(at: outputURL)
            if let error = error as? AudioModelInputPreparationError {
                throw error
            }
            let error = error as NSError
            throw AudioModelInputPreparationError.conversionFailed(
                "\(error.domain) \(error.code): \(error.localizedDescription)"
            )
        }
    }

    private static func detailedFailure(
        stage: String,
        error: Error
    ) -> AudioModelInputPreparationError {
        let error = error as NSError
        return .conversionFailed(
            "\(stage): \(error.domain) \(error.code): \(error.localizedDescription)"
        )
    }
}
