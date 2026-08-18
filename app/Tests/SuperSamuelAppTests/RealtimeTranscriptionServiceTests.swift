import XCTest
@testable import SuperSamuelApp

final class RealtimeTranscriptionServiceTests: XCTestCase {
    @MainActor
    func testWebSocketRequestsATranscriptionSession() throws {
        let components = try XCTUnwrap(
            URLComponents(
                url: RealtimeTranscriptionService.webSocketURL(),
                resolvingAgainstBaseURL: false
            )
        )

        XCTAssertEqual(components.path, "/v1/realtime")
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "intent", value: "transcription")]
        )
    }

    func testAssemblerPreservesTurnOrderWhenCompletionsArriveOutOfOrder() {
        var assembler = RealtimeTranscriptAssembler()
        assembler.registerCommittedItem("first")
        assembler.registerCommittedItem("second")

        assembler.append(delta: "Second draft", itemID: "second")
        assembler.complete(transcript: "Second final.", itemID: "second")
        assembler.append(delta: "First draft", itemID: "first")

        XCTAssertEqual(
            assembler.combinedText,
            "First draft Second final."
        )
        XCTAssertEqual(assembler.pendingItemIDs, ["first"])

        assembler.complete(transcript: "First final.", itemID: "first")
        XCTAssertEqual(
            assembler.combinedText,
            "First final. Second final."
        )
        XCTAssertTrue(assembler.pendingItemIDs.isEmpty)
    }

    @MainActor
    func testSessionUsesGPTTranscribeWithServerVAD() throws {
        let event = RealtimeTranscriptionService.sessionUpdateEvent(
            context: "Expected term: SuperSamuel."
        )
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)

        let transcription = try XCTUnwrap(
            input["transcription"] as? [String: Any]
        )
        XCTAssertEqual(transcription["model"] as? String, "gpt-transcribe")
        XCTAssertEqual(
            transcription["prompt"] as? String,
            "Expected term: SuperSamuel."
        )

        let turnDetection = try XCTUnwrap(
            input["turn_detection"] as? [String: Any]
        )
        XCTAssertEqual(turnDetection["type"] as? String, "server_vad")
        XCTAssertEqual(turnDetection["silence_duration_ms"] as? Int, 500)
    }
}
