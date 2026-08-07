import Foundation
import XCTest
@testable import SuperSamuelApp

final class DictationEngineTests: XCTestCase {
    func testGeminiAudioBypassesWhisper() async throws {
        let transport = DictationTransportSpy()
        let engine = DictationEngine(transport: transport)
        let audio = sampleAudio()

        let result = try await engine.process(
            apiKey: "key",
            input: DictationInput(
                audio: audio,
                strategy: .geminiAudio,
                dictationModel: "mistralai/voxtral-small-24b-2507"
            )
        )
        let calls = await transport.recordedCalls()

        XCTAssertEqual(result.text, "gemini result")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].kind, .gemini)
        XCTAssertEqual(calls[0].model, "mistralai/voxtral-small-24b-2507")
        XCTAssertTrue(calls[0].hasAudio)
        XCTAssertNil(calls[0].draftTranscript)
    }

    func testHybridReusesSuppliedDraftAndSendsBothSources() async throws {
        let transport = DictationTransportSpy()
        let engine = DictationEngine(transport: transport)
        let draft = DictationDraft(
            text: "whisper draft",
            metrics: DictationCallMetrics(
                stage: .whisper,
                requestedModel: OpenRouterService.transcriptionModel,
                resolvedModel: nil,
                provider: "Whisper provider",
                durationSeconds: 0.25,
                usage: nil
            )
        )

        let result = try await engine.process(
            apiKey: "key",
            input: DictationInput(
                audio: sampleAudio(),
                strategy: .whisperThenGeminiAudio,
                whisperDraft: draft
            )
        )
        let calls = await transport.recordedCalls()

        XCTAssertEqual(calls.count, 1, "The supplied Whisper draft must not be recomputed")
        XCTAssertEqual(calls[0].kind, .gemini)
        XCTAssertTrue(calls[0].hasAudio)
        XCTAssertEqual(calls[0].draftTranscript, "whisper draft")
        XCTAssertEqual(result.draftTranscript, "whisper draft")
        XCTAssertEqual(result.calls.map(\.stage), [.whisper, .gemini])
    }

    func testTranscriptCleanupOmitsAudio() async throws {
        let transport = DictationTransportSpy()
        let engine = DictationEngine(transport: transport)
        let draft = DictationDraft(
            text: "raw words",
            metrics: DictationCallMetrics(
                stage: .whisper,
                requestedModel: OpenRouterService.transcriptionModel,
                resolvedModel: nil,
                provider: nil,
                durationSeconds: 0.1,
                usage: nil
            )
        )

        _ = try await engine.process(
            apiKey: "key",
            input: DictationInput(
                audio: sampleAudio(),
                strategy: .whisperThenGeminiText,
                whisperDraft: draft
            )
        )
        let calls = await transport.recordedCalls()

        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].hasAudio)
        XCTAssertEqual(calls[0].draftTranscript, "raw words")
    }

    private func sampleAudio() -> RecordedAudio {
        RecordedAudio(
            fileURL: URL(fileURLWithPath: "/tmp/sample.m4a"),
            format: "m4a",
            mimeType: "audio/mp4"
        )
    }
}

private actor DictationTransportSpy: DictationTransport {
    enum Kind: Equatable, Sendable {
        case whisper
        case gemini
    }

    struct Call: Sendable {
        let kind: Kind
        let model: String?
        let hasAudio: Bool
        let draftTranscript: String?
    }

    private var calls: [Call] = []

    func performTranscription(
        apiKey: String,
        audio: RecordedAudio
    ) async throws -> OpenRouterTextResponse {
        calls.append(
            Call(kind: .whisper, model: nil, hasAudio: true, draftTranscript: nil)
        )
        return OpenRouterTextResponse(
            text: "whisper result",
            resolvedModel: OpenRouterService.transcriptionModel,
            provider: "Whisper provider",
            usage: nil
        )
    }

    func performAudioDictation(
        apiKey: String,
        model: String,
        audio: RecordedAudio?,
        draftTranscript: String?,
        rewriteInstruction: String,
        supportingContext: String?,
        screenshotURL: URL?
    ) async throws -> OpenRouterTextResponse {
        calls.append(
            Call(
                kind: .gemini,
                model: model,
                hasAudio: audio != nil,
                draftTranscript: draftTranscript
            )
        )
        return OpenRouterTextResponse(
            text: "gemini result",
            resolvedModel: OpenRouterService.geminiDictationModel,
            provider: "Gemini provider",
            usage: nil
        )
    }

    func recordedCalls() -> [Call] {
        calls
    }
}
