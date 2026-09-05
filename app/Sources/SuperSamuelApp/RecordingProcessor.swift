import AVFoundation
import Foundation

enum RecordingProcessingError: LocalizedError {
    case incompleteSavedCapture

    var errorDescription: String? {
        "Microphone capture was interrupted. The recorded parts and partial transcript were kept; audio from the interruption could not be recovered."
    }
}

enum RecordingProcessingStage: Equatable {
    case transcribing
    case cleaningUp
}

struct RecordingProcessingProgress {
    let stage: RecordingProcessingStage
    let currentPart: Int
    let totalParts: Int
    let transcriptPreview: String

    init(
        stage: RecordingProcessingStage = .transcribing,
        currentPart: Int,
        totalParts: Int,
        transcriptPreview: String
    ) {
        self.stage = stage
        self.currentPart = currentPart
        self.totalParts = totalParts
        self.transcriptPreview = transcriptPreview
    }
}

struct ProcessedRecording {
    let transcript: String
    let captureWarning: String?
}

protocol RecordingTranscriptionService: Sendable {
    func transcribe(
        apiKey: String, model: String, transcriptionContext: String?, audio: RecordedAudio
    ) async throws -> String
}

protocol TranscriptCleanupService: Sendable {
    func cleanUp(apiKey: String, transcript: String, configuration: TranscriptCleanupConfiguration) async throws -> String
}

@MainActor
final class RecordingProcessor {
    private let recordingStore: RecordingStore
    private let historyStore: TranscriptHistoryStore
    private let openRouterService: any RecordingTranscriptionService
    private let cleanupService: any TranscriptCleanupService

    init(
        recordingStore: RecordingStore,
        historyStore: TranscriptHistoryStore,
        openRouterService: any RecordingTranscriptionService,
        cleanupService: any TranscriptCleanupService = OpenRouterService()
    ) {
        self.recordingStore = recordingStore
        self.historyStore = historyStore
        self.openRouterService = openRouterService
        self.cleanupService = cleanupService
    }

    func process(
        sessionID: UUID,
        apiKey: String,
        preferredTranscript: String? = nil,
        onProgress: (RecordingProcessingProgress) -> Void
    ) async throws -> ProcessedRecording {
        try Task.checkCancellation()
        let session = try recordingStore.load(sessionID)
        let finalTranscript: String

        if (session.transcriptSource != "live" || session.canUseLiveTranscript),
           let cachedFinal = recordingStore.finalTranscript(
            sessionID: sessionID
        ) {
            finalTranscript = cachedFinal
        } else {
            let draftTranscript = try await resolveDraft(
                session: session,
                apiKey: apiKey,
                preferredTranscript: preferredTranscript,
                onProgress: onProgress
            )
            try Task.checkCancellation()
            if let cleanup = session.cleanup {
                onProgress(RecordingProcessingProgress(
                    stage: .cleaningUp, currentPart: 1, totalParts: 1,
                    transcriptPreview: draftTranscript
                ))
                let cleaned = try await cleanupService.cleanUp(
                    apiKey: apiKey, transcript: draftTranscript, configuration: cleanup
                )
                try Task.checkCancellation()
                guard let text = normalized(cleaned) else { throw OpenRouterServiceError.emptyTranscript }
                finalTranscript = text
            } else {
                finalTranscript = draftTranscript
            }

            try recordingStore.saveFinalTranscript(
                finalTranscript,
                sessionID: sessionID
            )
        }

        try Task.checkCancellation()
        let historyItem = try await historyStore.archive(
            session: recordingStore.load(sessionID),
            recordingDirectory: recordingStore.directoryURL(for: session.id),
            text: finalTranscript
        )
        try Task.checkCancellation()
        try recordingStore.markCompleted(
            sessionID,
            transcriptID: historyItem.id
        )
        try recordingStore.deleteSession(sessionID)

        // A capture gap cannot be repaired by retrying transcription. Deliver the saved
        // words and retain the interruption metadata with all source audio in history.
        return ProcessedRecording(
            transcript: finalTranscript,
            captureWarning: session.savedCaptureContinuous == false
                ? "Transcript saved. The microphone changed or stopped during recording; words spoken during the interruption may be missing."
                : nil
        )
    }

    private func resolveDraft(
        session: RecordingSession,
        apiKey: String,
        preferredTranscript: String?,
        onProgress: (RecordingProcessingProgress) -> Void
    ) async throws -> String {
        if session.requiresFreshTranscription != true,
           session.canUseLiveTranscript,
           session.savedCaptureContinuous != false,
           let preferredTranscript = normalized(preferredTranscript) {
            try recordingStore.saveDraftTranscript(
                preferredTranscript,
                sessionID: session.id
            )
            try recordingStore.setTranscriptSource("live", for: session.id)
            return preferredTranscript
        }

        if (session.transcriptSource != "live" || session.canUseLiveTranscript),
           let cachedDraft = recordingStore.draftTranscript(
            sessionID: session.id
        ) {
            return cachedDraft
        }

        let draftTranscript = try await transcribe(
            session: session,
            apiKey: apiKey,
            onProgress: onProgress
        )
        try Task.checkCancellation()

        try recordingStore.saveDraftTranscript(
            draftTranscript,
            sessionID: session.id
        )
        try recordingStore.setTranscriptSource("saved-audio", for: session.id)
        return draftTranscript
    }

    private func normalized(_ transcript: String?) -> String? {
        let transcript = transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return transcript.isEmpty ? nil : transcript
    }

    private func transcribe(
        session: RecordingSession,
        apiKey: String,
        onProgress: (RecordingProcessingProgress) -> Void
    ) async throws -> String {
        let chunks = try recordingStore.audioChunks(for: session)
        let context = await transcriptionContext(for: session)
        try Task.checkCancellation()
        var transcriptParts: [String] = []

        for (index, item) in chunks.enumerated() {
            try Task.checkCancellation()

            let partNumber = index + 1
            onProgress(
                RecordingProcessingProgress(
                    currentPart: partNumber,
                    totalParts: chunks.count,
                    transcriptPreview: transcriptParts.joined(separator: "\n\n")
                )
            )

            let rawTranscript: String?
            if let cached = recordingStore.cachedTranscript(
                sessionID: session.id,
                chunkID: item.0.id,
                cleaned: false
            ) {
                rawTranscript = cached
            } else {
                let signal = await Self.inspectAudioSignal(item.1.fileURL)
                try Task.checkCancellation()
                if signal == .empty && session.savedCaptureContinuous == false {
                    continue
                }
                let isSilent = signal == .silence
                if isSilent && session.requiresFreshTranscription != true {
                    rawTranscript = nil
                } else {
                    do {
                        let transcript = try await openRouterService.transcribe(
                            apiKey: apiKey,
                            model: session.resolvedTranscriptionModel,
                            transcriptionContext: context,
                            audio: item.1
                        )
                        try Task.checkCancellation()
                        try recordingStore.saveTranscript(
                            transcript,
                            sessionID: session.id,
                            chunkID: item.0.id,
                            cleaned: false
                        )
                        rawTranscript = transcript
                    } catch OpenRouterServiceError.emptyTranscript where isSilent {
                        try Task.checkCancellation()
                        rawTranscript = nil
                    }
                }
                if rawTranscript == nil {
                    try recordingStore.markChunkAsNoSpeech(
                        sessionID: session.id, chunkID: item.0.id
                    )
                }
            }

            guard let rawTranscript else {
                onProgress(
                    RecordingProcessingProgress(
                        currentPart: partNumber,
                        totalParts: chunks.count,
                        transcriptPreview: transcriptParts.joined(separator: "\n\n")
                    )
                )
                continue
            }

            transcriptParts.append(rawTranscript)
            onProgress(
                RecordingProcessingProgress(
                    currentPart: partNumber,
                    totalParts: chunks.count,
                    transcriptPreview: transcriptParts.joined(separator: "\n\n")
                )
            )
        }

        let finalTranscript = transcriptParts
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalTranscript.isEmpty else {
            guard session.savedCaptureContinuous != false else {
                throw RecordingProcessingError.incompleteSavedCapture
            }
            throw OpenRouterServiceError.noSpeechDetected
        }
        return finalTranscript
    }

    private func transcriptionContext(for session: RecordingSession) async -> String? {
        var contextParts: [String] = []
        if let configuredContext = session.resolvedTranscriptionContext {
            contextParts.append(configuredContext)
        }
        if let vocabulary = session.vocabulary, !vocabulary.isEmpty {
            contextParts.append(
                "Personal vocabulary:\n" +
                vocabulary.joined(separator: ", ")
            )
        }

        let screenshotURL = recordingStore.screenshotURL(for: session)
        if let visibleText = await ScreenshotContextExtractor.extractText(
            from: screenshotURL
        ) {
            contextParts.append(
                "Screenshot text:\n\(visibleText)"
            )
        }

        let context = contextParts.joined(separator: "\n\n")
        return context.isEmpty ? nil : context
    }

    // Only near-digital silence is conclusive. Background noise, unreadable
    // audio and empty provider responses remain recoverable recordings.
    private enum AudioSignal {
        case silence
        case empty
        case audibleOrUnverified
    }

    private static func inspectAudioSignal(_ url: URL) async -> AudioSignal {
        let inspection = Task.detached(priority: .utility) {
            do {
                let file = try AVAudioFile(forReading: url)
                guard file.length > 0 else { return AudioSignal.empty }
                guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat, frameCapacity: 8_192
                      ) else { return AudioSignal.audibleOrUnverified }
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0,
                          let channels = buffer.floatChannelData else { return AudioSignal.audibleOrUnverified }
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for frame in 0..<Int(buffer.frameLength) {
                            let sample = channels[channel][frame]
                            guard sample.isFinite, abs(sample) <= 0.00001 else { return AudioSignal.audibleOrUnverified }
                        }
                    }
                }
                return AudioSignal.silence
            } catch {
                return AudioSignal.audibleOrUnverified
            }
        }
        return await withTaskCancellationHandler {
            await inspection.value
        } onCancel: {
            inspection.cancel()
        }
    }
}
