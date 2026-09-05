import Foundation
import AVFoundation
import XCTest
@testable import SuperSamuelApp

final class RealtimeTranscriptionServiceTests: XCTestCase {
    @MainActor
    func testLiveAPIWithGeneratedSpeechWhenExplicitlyEnabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUPERSAMUEL_LIVE_TEST_AUDIO"] else {
            throw XCTSkip("Set SUPERSAMUEL_LIVE_TEST_AUDIO to explicitly enable the paid live API check.")
        }
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        guard !apiKey.isEmpty else {
            throw XCTSkip("Set OPENAI_API_KEY explicitly; test runners must not prompt for the app's Keychain credential.")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 24_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        var audio = Data()
        for index in 0..<Int(buffer.frameLength) {
            let sample = Int16(max(-32_768, min(32_767, Int(samples[index] * 32_767))))
            let bits = UInt16(bitPattern: sample)
            audio.append(UInt8(bits & 0xff))
            audio.append(UInt8(bits >> 8))
        }
        audio.append(Data(repeating: 0, count: 24_000))
        let usesLongContext = ProcessInfo.processInfo.environment["SUPERSAMUEL_LIVE_TEST_LONG_CONTEXT"] == "1"
        let context = usesLongContext
            ? String(repeating: "Transcribe the speaker accurately. Preserve product names. ", count: 30)
            : "Transcribe the speaker accurately. Preserve product names."
        for delay in TranscriptionDelay.allCases {
            var firstTextAt: Date?
            let service = RealtimeTranscriptionService { text in
                if !text.isEmpty, firstTextAt == nil { firstTextAt = Date() }
            }
            defer { service.cancel() }
            try await service.start(
                apiKey: apiKey,
                transcriptionContext: context,
                delay: delay, keywords: ["SuperSamuel", "OpenRouter", "Marc"]
            )
            XCTAssertEqual(service.configuration.context, context)
            XCTAssertEqual(service.requiresSavedAudioFinalization, usesLongContext)
            let started = Date()
            for start in stride(from: 0, to: audio.count, by: 9_600) {
                let end = min(start + 9_600, audio.count)
                service.appendAudio(audio.subdata(in: start..<end))
                try await Task.sleep(nanoseconds: UInt64(Double(end - start) / 48_000 * 1_000_000_000))
            }
            let stopped = Date()
            XCTAssertNotNil(firstTextAt, "Generated speech must produce live text before Stop")
            do {
                let transcript = try await service.finish()
                let result: [String: Any] = [
                    "delay": delay.rawValue, "transcript": transcript,
                    "context_characters": context.unicodeScalars.count,
                    "requires_saved_audio_finalization": service.requiresSavedAudioFinalization,
                    "audio_seconds": Double(audio.count) / 48_000,
                    "first_text_seconds": firstTextAt?.timeIntervalSince(started) ?? -1,
                    "stop_to_finish_seconds": Date().timeIntervalSince(stopped)
                ]
                let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print("LIVE_PROBE " + String(decoding: json, as: UTF8.self))
                XCTAssertFalse(transcript.isEmpty)
            } catch {
                print("LIVE_PROBE delay=\(delay.rawValue) error=\(error.localizedDescription)")
                throw error
            }
        }

        let silentService = RealtimeTranscriptionService { _ in }
        defer { silentService.cancel() }
        try await silentService.start(apiKey: apiKey, transcriptionContext: "", delay: .xhigh)
        silentService.appendAudio(Data(repeating: 0, count: 57_600))
        do {
            _ = try await silentService.finish()
            XCTFail("Synthetic silence should not produce a transcript")
        } catch RealtimeTranscriptionError.noSpeechDetected {
            print("LIVE_PROBE silence=no_speech_detected")
        }
    }

    @MainActor
    func testWebSocketRequestsATranscriptionSession() throws {
        let components = try XCTUnwrap(URLComponents(
            url: RealtimeTranscriptionService.webSocketURL(), resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(components.path, "/v1/realtime")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "intent", value: "transcription")])
    }

    func testAssemblerPreservesTurnOrderWhenCompletionsArriveOutOfOrder() {
        var assembler = RealtimeTranscriptAssembler()
        assembler.append(delta: "Second draft", itemID: "second")
        assembler.complete(transcript: "Second final.", itemID: "second")
        assembler.registerCommittedItem("first")
        assembler.registerCommittedItem("second", previousItemID: "first")
        assembler.append(delta: "First draft", itemID: "first")
        XCTAssertEqual(assembler.combinedText, "First draft Second final.")
        XCTAssertEqual(assembler.pendingItemIDs, ["first"])
        assembler.complete(transcript: "First final.", itemID: "first")
        assembler.append(delta: "stale delta", itemID: "first")
        assembler.registerCommittedItem("first")
        XCTAssertEqual(assembler.combinedText, "First final. Second final.")
        XCTAssertTrue(assembler.pendingItemIDs.isEmpty)
    }

    @MainActor
    func testSessionUsesEveryLiveDelayWithClientPauseDetection() throws {
        for delay in TranscriptionDelay.allCases {
            let event = RealtimeTranscriptionService.sessionUpdateEvent(
                context: "Expected term: SuperSamuel.", delay: delay, keywords: ["SuperSamuel"]
            )
            let session = try XCTUnwrap(event["session"] as? [String: Any])
            XCTAssertEqual(session["type"] as? String, "transcription")
            let audio = try XCTUnwrap(session["audio"] as? [String: Any])
            let input = try XCTUnwrap(audio["input"] as? [String: Any])
            let format = try XCTUnwrap(input["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "audio/pcm")
            XCTAssertEqual(format["rate"] as? Int, 24_000)
            let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
            XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
            XCTAssertEqual(transcription["prompt"] as? String, "Expected term: SuperSamuel.")
            XCTAssertEqual(transcription["delay"] as? String, delay.rawValue)
            XCTAssertEqual(transcription["keywords"] as? [String], ["SuperSamuel"])
            XCTAssertNil(transcription["language"])
            XCTAssertTrue(input["turn_detection"] is NSNull)
        }
        XCTAssertEqual(RealtimeTranscriptionService.silenceDurationMilliseconds, 500)
    }

    func testPauseDetectorRequiresSpeechThenExactly500MillisecondsOfSilence() {
        var detector = RealtimeSpeechPauseDetector()
        XCTAssertTrue(detector.boundaries(in: pcm(milliseconds: 1000, amplitude: 0)).isEmpty)
        XCTAssertTrue(detector.boundaries(in: pcm(milliseconds: 100, amplitude: 0.1)).isEmpty)
        XCTAssertTrue(detector.boundaries(in: pcm(milliseconds: 490, amplitude: 0)).isEmpty)
        XCTAssertEqual(detector.boundaries(in: pcm(milliseconds: 10, amplitude: 0)), [480])
        XCTAssertTrue(detector.boundaries(in: pcm(milliseconds: 1000, amplitude: 0)).isEmpty)
    }

    func testPauseDetectorKeepsQuietSpeechAndIsIndependentOfChunkBoundaries() {
        let audio = pcm(milliseconds: 100, amplitude: 0.01)
            + pcm(milliseconds: 1000, amplitude: 0.0015)
            + pcm(milliseconds: 500, amplitude: 0)
        var detector = RealtimeSpeechPauseDetector()
        XCTAssertEqual(detector.boundaries(in: audio), [audio.count])
        var splitDetector = RealtimeSpeechPauseDetector()
        var positions: [Int] = []
        for start in stride(from: 0, to: audio.count, by: 317) {
            let chunk = audio.subdata(in: start..<min(start + 317, audio.count))
            positions += splitDetector.boundaries(in: chunk).map { $0 + start }
        }
        XCTAssertEqual(positions, [audio.count])
    }

    @MainActor
    func testLongInstructionsKeepLiveTranscriptionAvailable() async throws {
        let context = String(repeating: "Preserve all dictated content. ", count: 60)
        let keywords = ["SuperSamuel", "AC-42"]
        let socket = FakeRealtimeSocket()
        var snapshots: [String] = []
        let service = RealtimeTranscriptionService(makeSocket: { _ in socket }) { snapshots.append($0) }
        defer { service.cancel() }

        try await service.start(
            apiKey: "test", transcriptionContext: context, delay: .medium, keywords: keywords
        )

        XCTAssertEqual(service.configuration.context, context)
        XCTAssertTrue(service.requiresSavedAudioFinalization)
        XCTAssertNil(service.failureMessage)
        let session = try XCTUnwrap(socket.events.first?["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        let prompt = try XCTUnwrap(transcription["prompt"] as? String)
        XCTAssertFalse(prompt.isEmpty)
        XCTAssertLessThanOrEqual(prompt.unicodeScalars.count, 1_024)
        XCTAssertFalse(context.hasPrefix(prompt), "Live preview must not silently truncate full instructions")
        XCTAssertEqual(transcription["delay"] as? String, "medium")
        XCTAssertEqual(transcription["keywords"] as? [String], keywords)

        service.appendAudio(pcm(milliseconds: 100, amplitude: 0.1) + pcm(milliseconds: 500, amplitude: 0))
        try await waitUntil { socket.commits.count == 1 }
        socket.push(["type": "input_audio_buffer.committed", "item_id": "first"])
        socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "first", "delta": "Live words"])
        try await waitUntil { snapshots.contains("Live words") }
        XCTAssertEqual(service.currentTranscript, "Live words")
        XCTAssertNil(service.failureMessage)
    }

    @MainActor
    func testContextUpdatePreservesDictionaryAndDelaySnapshot() async throws {
        let socket = FakeRealtimeSocket()
        let service = RealtimeTranscriptionService(makeSocket: { _ in socket }) { _ in }
        defer { service.cancel() }
        try await service.start(apiKey: "test", transcriptionContext: "Instructions", delay: .low, keywords: ["SuperSamuel", "AC-42"])
        XCTAssertFalse(service.requiresSavedAudioFinalization)
        service.updateTranscriptionContext("Instructions\nScreenshot: project AC-42")
        try await waitUntil { socket.events.filter { $0["type"] as? String == "session.update" }.count == 2 }
        let session = try XCTUnwrap(socket.events.last?["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["delay"] as? String, "low")
        XCTAssertEqual(transcription["keywords"] as? [String], ["SuperSamuel", "AC-42"])
        XCTAssertEqual(transcription["prompt"] as? String, "Instructions\nScreenshot: project AC-42")
        XCTAssertFalse(service.requiresSavedAudioFinalization)
        let oversizedContext = String(repeating: "a", count: 1_025)
        service.updateTranscriptionContext(oversizedContext)
        try await waitUntil { socket.events.filter { $0["type"] as? String == "session.update" }.count == 3 }
        XCTAssertEqual(service.configuration.context, oversizedContext)
        XCTAssertTrue(service.requiresSavedAudioFinalization)
        XCTAssertNil(service.failureMessage)
        let updatedSession = try XCTUnwrap(socket.events.last?["session"] as? [String: Any])
        let updatedAudio = try XCTUnwrap(updatedSession["audio"] as? [String: Any])
        let updatedInput = try XCTUnwrap(updatedAudio["input"] as? [String: Any])
        let updatedTranscription = try XCTUnwrap(updatedInput["transcription"] as? [String: Any])
        let updatedPrompt = try XCTUnwrap(updatedTranscription["prompt"] as? String)
        XCTAssertLessThanOrEqual(updatedPrompt.unicodeScalars.count, 1_024)
        XCTAssertEqual(updatedTranscription["delay"] as? String, "low")
        XCTAssertEqual(updatedTranscription["keywords"] as? [String], ["SuperSamuel", "AC-42"])
        service.appendAudio(pcm(milliseconds: 100, amplitude: 0.1) + pcm(milliseconds: 500, amplitude: 0))
        try await waitUntil { socket.commits.count == 1 }
        socket.push(["type": "input_audio_buffer.committed", "item_id": "first"])
        socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "first", "delta": "Still live"])
        try await waitUntil { service.currentTranscript == "Still live" }
        service.updateTranscriptionContext("")
        try await waitUntil { socket.events.filter { $0["type"] as? String == "session.update" }.count == 4 }
        XCTAssertEqual(service.configuration.context, "")
        XCTAssertTrue(service.requiresSavedAudioFinalization, "Clearing context cannot apply full instructions to earlier preview audio")
        XCTAssertNil(service.failureMessage)
        XCTAssertTrue(RealtimeTranscriptionService.contextIsValid(String(repeating: "a", count: 1_024)))
        XCTAssertFalse(RealtimeTranscriptionService.contextIsValid(oversizedContext))
    }

    @MainActor
    func testStopWaitsForBothTurnCompletionsEvenWhenLastCompletesFirst() async throws {
        let socket = FakeRealtimeSocket()
        let service = RealtimeTranscriptionService(makeSocket: { _ in socket }) { _ in }
        defer { service.cancel() }
        try await service.start(apiKey: "test", transcriptionContext: "")
        service.appendAudio(pcm(milliseconds: 100, amplitude: 0.1) + pcm(milliseconds: 500, amplitude: 0))
        service.appendAudio(pcm(milliseconds: 200, amplitude: 0.1))
        var finished = false
        let result = Task { @MainActor in
            defer { finished = true }
            return try await service.finish()
        }
        try await waitUntil { socket.commits.count == 2 }
        // A completion can race its commit acknowledgement without becoming pending again.
        socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "second", "transcript": "Second."])
        socket.push(["type": "input_audio_buffer.committed", "item_id": "first"])
        socket.push(["type": "input_audio_buffer.committed", "item_id": "second", "previous_item_id": "first"])
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(finished)
        socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "first", "transcript": "First."])
        let transcript = try await result.value
        XCTAssertEqual(transcript, "First. Second.")
        XCTAssertTrue(socket.cancelled)
    }

    @MainActor
    func testPendingTurnFailureCannotReturnEarlierCompletedFragment() async throws {
        let socket = FakeRealtimeSocket()
        let service = RealtimeTranscriptionService(makeSocket: { _ in socket }) { _ in }
        defer { service.cancel() }
        try await service.start(apiKey: "test", transcriptionContext: "")
        service.appendAudio(pcm(milliseconds: 100, amplitude: 0.1) + pcm(milliseconds: 500, amplitude: 0))
        service.appendAudio(pcm(milliseconds: 200, amplitude: 0.1))
        let result = Task { try await service.finish() }
        try await waitUntil { socket.commits.count == 2 }
        socket.push(["type": "input_audio_buffer.committed", "item_id": "first"])
        socket.push(["type": "input_audio_buffer.committed", "item_id": "second"])
        socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "first", "transcript": "Useful partial."])
        socket.push(["type": "conversation.item.input_audio_transcription.failed", "item_id": "second", "error": ["message": "Recognition failed"]])
        do {
            _ = try await result.value
            XCTFail("A failed turn must force saved-audio fallback")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Recognition failed"))
        }
        XCTAssertEqual(service.currentTranscript, "Useful partial.")
        XCTAssertNotNil(service.failureMessage)
    }

    @MainActor
    func testEmptyStopCommitOnlyResolvesMatchingEmptyBufferError() async throws {
        let socket = FakeRealtimeSocket()
        let service = RealtimeTranscriptionService(makeSocket: { _ in socket }) { _ in }
        defer { service.cancel() }
        try await service.start(apiKey: "test", transcriptionContext: "")
        service.appendAudio(pcm(milliseconds: 100, amplitude: 0.1) + pcm(milliseconds: 500, amplitude: 0))
        let result = Task { try await service.finish() }
        try await waitUntil { socket.commits.count == 2 }
        socket.push(["type": "input_audio_buffer.committed", "item_id": "first"])
        socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "first", "transcript": "Finished."])
        socket.push(["type": "error", "error": ["event_id": socket.commits[1]["event_id"]!, "code": "input_audio_buffer_commit_empty", "message": "buffer too small"]])
        let transcript = try await result.value
        XCTAssertEqual(transcript, "Finished.")
    }

    @MainActor
    func testShortResidualSpeechErrorPreservesFallbackInsteadOfReturningPartial() async throws {
        let socket = FakeRealtimeSocket()
        let service = RealtimeTranscriptionService(makeSocket: { _ in socket }) { _ in }
        defer { service.cancel() }
        try await service.start(apiKey: "test", transcriptionContext: "")
        service.appendAudio(pcm(milliseconds: 30, amplitude: 0.1))
        let result = Task { try await service.finish() }
        try await waitUntil { socket.commits.count == 1 }
        let audioBytes = socket.events.compactMap { $0["audio"] as? String }
            .compactMap { Data(base64Encoded: $0) }.reduce(0) { $0 + $1.count }
        XCTAssertEqual(audioBytes, 4_800, "Short residual audio is padded to the API's 100 ms minimum")
        socket.push(["type": "error", "error": ["event_id": socket.commits[0]["event_id"]!, "code": "input_audio_buffer_commit_empty", "message": "buffer too small"]])
        do {
            _ = try await result.value
            XCTFail("Residual audio must not be silently ignored")
        } catch {
            XCTAssertNotNil(service.failureMessage)
        }
    }

    private func pcm(milliseconds: Int, amplitude: Double) -> Data {
        var data = Data()
        for sample in 0..<(milliseconds * 24) {
            let value = Int16(sin(Double(sample) * .pi / 12) * amplitude * 32_767)
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(bits & 0xff))
            data.append(UInt8(bits >> 8))
        }
        return data
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for asynchronous socket events")
        throw RealtimeTranscriptionError.connectionTimedOut
    }
}

@MainActor
private final class FakeRealtimeSocket: RealtimeWebSocketConnection {
    private(set) var events: [[String: Any]] = []
    private(set) var cancelled = false
    private var queue: [URLSessionWebSocketTask.Message] = []
    private var continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    var commits: [[String: Any]] { events.filter { $0["type"] as? String == "input_audio_buffer.commit" } }

    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { return }
        let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        events.append(event)
        if event["type"] as? String == "session.update" { push(["type": "session.updated"]) }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !queue.isEmpty { return queue.removeFirst() }
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
    func push(_ event: [String: Any]) {
        let message = URLSessionWebSocketTask.Message.data(try! JSONSerialization.data(withJSONObject: event))
        if let waiting = continuation {
            continuation = nil
            waiting.resume(returning: message)
        } else { queue.append(message) }
    }
}
