import Foundation

struct RecordingProcessingProgress {
    let currentPart: Int
    let totalParts: Int
    let transcriptPreview: String
}

struct ProcessedRecording {
    let transcript: String
}

@MainActor
final class RecordingProcessor {
    private let recordingStore: RecordingStore
    private let historyStore: TranscriptHistoryStore
    private let openRouterService: OpenRouterService

    init(
        recordingStore: RecordingStore,
        historyStore: TranscriptHistoryStore,
        openRouterService: OpenRouterService
    ) {
        self.recordingStore = recordingStore
        self.historyStore = historyStore
        self.openRouterService = openRouterService
    }

    func process(
        sessionID: UUID,
        apiKey: String,
        onProgress: (RecordingProcessingProgress) -> Void
    ) async throws -> ProcessedRecording {
        let session = try recordingStore.load(sessionID)
        let finalTranscript: String

        if let cachedFinal = recordingStore.finalTranscript(
            sessionID: sessionID
        ) {
            finalTranscript = cachedFinal
        } else {
            finalTranscript = try await transcribe(
                session: session,
                apiKey: apiKey,
                onProgress: onProgress
            )
            try recordingStore.saveFinalTranscript(
                finalTranscript,
                sessionID: sessionID
            )
        }

        try Task.checkCancellation()
        let historyItem = try historyStore.archive(
            session: session,
            recordingDirectory: recordingStore.directoryURL(for: session.id),
            text: finalTranscript
        )
        try recordingStore.markCompleted(
            sessionID,
            transcriptID: historyItem.id
        )
        try recordingStore.deleteSession(sessionID)

        return ProcessedRecording(transcript: finalTranscript)
    }

    private func transcribe(
        session: RecordingSession,
        apiKey: String,
        onProgress: (RecordingProcessingProgress) -> Void
    ) async throws -> String {
        let chunks = try recordingStore.audioChunks(for: session)
        let context = await transcriptionContext(for: session)
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
            if recordingStore.chunkHadNoSpeech(
                sessionID: session.id,
                chunkID: item.0.id
            ) {
                rawTranscript = nil
            } else if let cached = recordingStore.cachedTranscript(
                sessionID: session.id,
                chunkID: item.0.id,
                cleaned: false
            ) {
                rawTranscript = cached
            } else {
                do {
                    let transcript = try await openRouterService.transcribe(
                        apiKey: apiKey,
                        model: session.resolvedTranscriptionModel,
                        transcriptionContext: context,
                        audio: item.1
                    )
                    try recordingStore.saveTranscript(
                        transcript,
                        sessionID: session.id,
                        chunkID: item.0.id,
                        cleaned: false
                    )
                    rawTranscript = transcript
                } catch OpenRouterServiceError.noSpeechDetected {
                    try recordingStore.markChunkAsNoSpeech(
                        sessionID: session.id,
                        chunkID: item.0.id
                    )
                    rawTranscript = nil
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
            throw OpenRouterServiceError.noSpeechDetected
        }
        return finalTranscript
    }

    private func transcriptionContext(for session: RecordingSession) async -> String? {
        var contextParts: [String] = []
        if let configuredContext = session.resolvedTranscriptionContext {
            contextParts.append(configuredContext)
        }

        let screenshotURL = recordingStore.screenshotURL(for: session)
        if let visibleText = await ScreenshotContextExtractor.extractText(
            from: screenshotURL
        ) {
            contextParts.append(
                "Visible text extracted locally from the attached app screenshot. Use it only to disambiguate words in the audio:\n\(visibleText)"
            )
        }

        let context = contextParts.joined(separator: "\n\n")
        return context.isEmpty ? nil : context
    }
}
