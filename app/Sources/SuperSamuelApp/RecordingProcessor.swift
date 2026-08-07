import Foundation

struct RecordingProcessingProgress {
    enum Stage {
        case transcribing
        case enhancing
    }

    let stage: Stage
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
            finalTranscript = try await transcribeAndClean(
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
        let historyItem = try historyStore.save(
            recordingID: session.id,
            createdAt: session.createdAt,
            text: finalTranscript
        )
        try recordingStore.markCompleted(
            sessionID,
            transcriptID: historyItem.id
        )
        try recordingStore.deleteSession(sessionID)

        return ProcessedRecording(transcript: finalTranscript)
    }

    private func transcribeAndClean(
        session: RecordingSession,
        apiKey: String,
        onProgress: (RecordingProcessingProgress) -> Void
    ) async throws -> String {
        if session.cleanup.isEnabled && session.cleanup.usesAudioEnhancement {
            return try await enhanceAudio(
                session: session,
                apiKey: apiKey,
                onProgress: onProgress
            )
        }

        return try await transcribeAndOptionallyCleanLegacy(
            session: session,
            apiKey: apiKey,
            onProgress: onProgress
        )
    }

    private func transcribeAndOptionallyCleanLegacy(
        session: RecordingSession,
        apiKey: String,
        onProgress: (RecordingProcessingProgress) -> Void
    ) async throws -> String {
        let chunks = try recordingStore.audioChunks(for: session)
        let screenshotURL = recordingStore.screenshotURL(for: session)
        var transcriptParts: [String] = []

        for (index, item) in chunks.enumerated() {
            try Task.checkCancellation()

            let partNumber = index + 1
            onProgress(
                RecordingProcessingProgress(
                    stage: .transcribing,
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
                        stage: .transcribing,
                        currentPart: partNumber,
                        totalParts: chunks.count,
                        transcriptPreview: transcriptParts.joined(separator: "\n\n")
                    )
                )
                continue
            }

            let transcriptPart: String
            if session.cleanup.isEnabled {
                onProgress(
                    RecordingProcessingProgress(
                        stage: .enhancing,
                        currentPart: partNumber,
                        totalParts: chunks.count,
                        transcriptPreview: transcriptParts.joined(separator: "\n\n")
                    )
                )

                if let cached = recordingStore.cachedTranscript(
                    sessionID: session.id,
                    chunkID: item.0.id,
                    cleaned: true
                ) {
                    transcriptPart = cached
                } else {
                    transcriptPart = try await cleanupTranscript(
                        rawTranscript,
                        cleanup: session.cleanup,
                        screenshotURL: screenshotURL,
                        apiKey: apiKey
                    )
                    try recordingStore.saveTranscript(
                        transcriptPart,
                        sessionID: session.id,
                        chunkID: item.0.id,
                        cleaned: true
                    )
                }
            } else {
                transcriptPart = rawTranscript
            }

            transcriptParts.append(transcriptPart)
            onProgress(
                RecordingProcessingProgress(
                    stage: session.cleanup.isEnabled ? .enhancing : .transcribing,
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

    private func enhanceAudio(
        session: RecordingSession,
        apiKey: String,
        onProgress: (RecordingProcessingProgress) -> Void
    ) async throws -> String {
        let chunks = try recordingStore.audioChunks(for: session)
        let screenshotURL = recordingStore.screenshotURL(for: session)
        let visibleText = await ScreenshotContextExtractor.extractText(
            from: screenshotURL
        )
        let supportingContext = visibleText.map {
            "Visible text extracted locally from the attached app screenshot:\n\($0)"
        }
        var transcriptParts: [String] = []

        for (index, item) in chunks.enumerated() {
            try Task.checkCancellation()
            let partNumber = index + 1

            onProgress(
                RecordingProcessingProgress(
                    stage: .enhancing,
                    currentPart: partNumber,
                    totalParts: chunks.count,
                    transcriptPreview: transcriptParts.joined(separator: "\n\n")
                )
            )

            if recordingStore.chunkHadNoSpeech(
                sessionID: session.id,
                chunkID: item.0.id
            ) {
                continue
            }

            let transcriptPart: String
            if let cached = recordingStore.cachedTranscript(
                sessionID: session.id,
                chunkID: item.0.id,
                cleaned: true
            ) {
                transcriptPart = cached
            } else {
                let preparedAudio = try await AudioModelInputPreparer.prepare(
                    item.1,
                    for: session.cleanup.model
                )
                defer { preparedAudio.removeTemporaryFile() }

                do {
                    transcriptPart = try await enhanceAudioPart(
                        preparedAudio.audio,
                        cleanup: session.cleanup,
                        supportingContext: supportingContext,
                        screenshotURL: screenshotURL,
                        apiKey: apiKey
                    )
                } catch OpenRouterServiceError.noSpeechDetected {
                    try recordingStore.markChunkAsNoSpeech(
                        sessionID: session.id,
                        chunkID: item.0.id
                    )
                    continue
                }

                try recordingStore.saveTranscript(
                    transcriptPart,
                    sessionID: session.id,
                    chunkID: item.0.id,
                    cleaned: true
                )
            }

            transcriptParts.append(transcriptPart)
            onProgress(
                RecordingProcessingProgress(
                    stage: .enhancing,
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

    private func enhanceAudioPart(
        _ audio: RecordedAudio,
        cleanup: PersistedCleanupOptions,
        supportingContext: String?,
        screenshotURL: URL?,
        apiKey: String
    ) async throws -> String {
        do {
            return try await openRouterService.performAudioDictation(
                apiKey: apiKey,
                model: cleanup.model,
                audio: audio,
                draftTranscript: nil,
                rewriteInstruction: cleanup.prompt,
                supportingContext: supportingContext,
                screenshotURL: screenshotURL
            ).text
        } catch {
            guard screenshotURL != nil,
                  OpenRouterService.supportsNativeImageContext(model: cleanup.model),
                  !isCancellation(error)
            else {
                throw error
            }

            return try await openRouterService.performAudioDictation(
                apiKey: apiKey,
                model: cleanup.model,
                audio: audio,
                draftTranscript: nil,
                rewriteInstruction: cleanup.prompt,
                supportingContext: supportingContext,
                screenshotURL: nil
            ).text
        }
    }

    private func cleanupTranscript(
        _ transcript: String,
        cleanup: PersistedCleanupOptions,
        screenshotURL: URL?,
        apiKey: String
    ) async throws -> String {
        do {
            return try await openRouterService.cleanupTranscript(
                apiKey: apiKey,
                model: cleanup.model,
                rewriteInstruction: cleanup.prompt,
                rawTranscript: transcript,
                screenshotURL: screenshotURL
            )
        } catch {
            guard screenshotURL != nil, !isCancellation(error) else {
                throw error
            }

            return try await openRouterService.cleanupTranscript(
                apiKey: apiKey,
                model: cleanup.model,
                rewriteInstruction: cleanup.prompt,
                rawTranscript: transcript
            )
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled || Task.isCancelled
    }
}
