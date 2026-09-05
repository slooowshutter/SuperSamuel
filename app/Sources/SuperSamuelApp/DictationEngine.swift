import Foundation

enum DictationStrategy: String, CaseIterable, Codable, Sendable {
    case whisperOnly = "whisper-only"
    case whisperThenGeminiText = "whisper-gemini-text"
    case geminiAudio = "gemini-audio"
    case whisperThenGeminiAudio = "whisper-gemini-audio"

    var displayName: String {
        switch self {
        case .whisperOnly:
            return "Whisper only"
        case .whisperThenGeminiText:
            return "Whisper → Gemini (text)"
        case .geminiAudio:
            return "Gemini (audio)"
        case .whisperThenGeminiAudio:
            return "Whisper → Gemini (audio + draft)"
        }
    }
}

enum DictationCallStage: String, Codable, Sendable {
    case whisper
    case gemini
}

struct OpenRouterUsage: Codable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cost
    }
}

struct OpenRouterTextResponse: Sendable {
    let text: String
    let resolvedModel: String?
    let provider: String?
    let usage: OpenRouterUsage?
}

struct DictationCallMetrics: Codable, Sendable {
    let stage: DictationCallStage
    let requestedModel: String
    let resolvedModel: String?
    let provider: String?
    let durationSeconds: Double
    let usage: OpenRouterUsage?
}

struct DictationDraft: Sendable {
    let text: String
    let metrics: DictationCallMetrics
}

struct DictationInput: Sendable {
    let audio: RecordedAudio
    let strategy: DictationStrategy
    let dictationModel: String
    let rewriteInstruction: String
    let whisperDraft: DictationDraft?

    init(
        audio: RecordedAudio,
        strategy: DictationStrategy,
        dictationModel: String = OpenRouterService.geminiDictationModel,
        rewriteInstruction: String = OpenRouterService.defaultCleanupInstruction,
        whisperDraft: DictationDraft? = nil
    ) {
        self.audio = audio
        self.strategy = strategy
        self.dictationModel = dictationModel
        self.rewriteInstruction = rewriteInstruction
        self.whisperDraft = whisperDraft
    }
}

struct DictationResult: Codable, Sendable {
    let strategy: DictationStrategy
    let text: String
    let draftTranscript: String?
    let calls: [DictationCallMetrics]

    var totalDurationSeconds: Double {
        calls.reduce(0) { $0 + $1.durationSeconds }
    }
}

protocol DictationTransport: Sendable {
    func performTranscription(
        apiKey: String,
        model: String,
        audio: RecordedAudio
    ) async throws -> OpenRouterTextResponse

    func performAudioDictation(
        apiKey: String,
        model: String,
        audio: RecordedAudio?,
        draftTranscript: String?,
        rewriteInstruction: String,
        supportingContext: String?,
        screenshotURL: URL?
    ) async throws -> OpenRouterTextResponse
}

/// Runs every dictation strategy behind one interface. It deliberately knows
/// nothing about paste, history, recording sessions, or UI state.
struct DictationEngine: Sendable {
    static let benchmarkTranscriptionModel = "openai/whisper-large-v3"

    private let transport: any DictationTransport

    init(transport: any DictationTransport) {
        self.transport = transport
    }

    func makeWhisperDraft(
        apiKey: String,
        audio: RecordedAudio
    ) async throws -> DictationDraft {
        let startedAt = Date()
        let response = try await transport.performTranscription(
            apiKey: apiKey,
            model: Self.benchmarkTranscriptionModel,
            audio: audio
        )
        return DictationDraft(
            text: response.text,
            metrics: DictationCallMetrics(
                stage: .whisper,
                requestedModel: Self.benchmarkTranscriptionModel,
                resolvedModel: response.resolvedModel,
                provider: response.provider,
                durationSeconds: Date().timeIntervalSince(startedAt),
                usage: response.usage
            )
        )
    }

    func process(apiKey: String, input: DictationInput) async throws -> DictationResult {
        switch input.strategy {
        case .whisperOnly:
            let draft = try await resolveDraft(apiKey: apiKey, input: input)
            return DictationResult(
                strategy: input.strategy,
                text: draft.text,
                draftTranscript: draft.text,
                calls: [draft.metrics]
            )

        case .whisperThenGeminiText:
            let draft = try await resolveDraft(apiKey: apiKey, input: input)
            let gemini = try await performGemini(
                apiKey: apiKey,
                model: input.dictationModel,
                audio: nil,
                draftTranscript: draft.text,
                rewriteInstruction: input.rewriteInstruction
            )
            return DictationResult(
                strategy: input.strategy,
                text: gemini.response.text,
                draftTranscript: draft.text,
                calls: [draft.metrics, gemini.metrics]
            )

        case .geminiAudio:
            let gemini = try await performGemini(
                apiKey: apiKey,
                model: input.dictationModel,
                audio: input.audio,
                draftTranscript: nil,
                rewriteInstruction: input.rewriteInstruction
            )
            return DictationResult(
                strategy: input.strategy,
                text: gemini.response.text,
                draftTranscript: nil,
                calls: [gemini.metrics]
            )

        case .whisperThenGeminiAudio:
            let draft = try await resolveDraft(apiKey: apiKey, input: input)
            let gemini = try await performGemini(
                apiKey: apiKey,
                model: input.dictationModel,
                audio: input.audio,
                draftTranscript: draft.text,
                rewriteInstruction: input.rewriteInstruction
            )
            return DictationResult(
                strategy: input.strategy,
                text: gemini.response.text,
                draftTranscript: draft.text,
                calls: [draft.metrics, gemini.metrics]
            )
        }
    }

    private func resolveDraft(
        apiKey: String,
        input: DictationInput
    ) async throws -> DictationDraft {
        if let draft = input.whisperDraft {
            return draft
        }
        return try await makeWhisperDraft(apiKey: apiKey, audio: input.audio)
    }

    private func performGemini(
        apiKey: String,
        model: String,
        audio: RecordedAudio?,
        draftTranscript: String?,
        rewriteInstruction: String
    ) async throws -> (response: OpenRouterTextResponse, metrics: DictationCallMetrics) {
        let startedAt = Date()
        let response = try await transport.performAudioDictation(
            apiKey: apiKey,
            model: model,
            audio: audio,
            draftTranscript: draftTranscript,
            rewriteInstruction: rewriteInstruction,
            supportingContext: nil,
            screenshotURL: nil
        )
        return (
            response,
            DictationCallMetrics(
                stage: .gemini,
                requestedModel: model,
                resolvedModel: response.resolvedModel,
                provider: response.provider,
                durationSeconds: Date().timeIntervalSince(startedAt),
                usage: response.usage
            )
        )
    }
}
