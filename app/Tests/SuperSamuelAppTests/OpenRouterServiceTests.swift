import AVFoundation
import Foundation
import XCTest
@testable import SuperSamuelApp

final class OpenRouterServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testTranscriptionUsesBase64JSONRequest() async throws {
        let selectedModel = "custom/transcription-model"
        let audioData = Data("wave-audio".utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try audioData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )

            let body = try XCTUnwrap(try requestBody(request))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(
                payload["model"] as? String,
                selectedModel
            )
            XCTAssertEqual(payload["temperature"] as? Int, 0)

            let inputAudio = try XCTUnwrap(
                payload["input_audio"] as? [String: Any]
            )
            XCTAssertEqual(inputAudio["format"] as? String, "wav")
            XCTAssertEqual(
                inputAudio["data"] as? String,
                audioData.base64EncodedString()
            )

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data(#"{"text":"hello"}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = OpenRouterService(
            urlSession: URLSession(configuration: configuration)
        )

        let transcript = try await service.transcribe(
            apiKey: "test-key",
            model: selectedModel,
            audio: RecordedAudio(
                fileURL: fileURL,
                format: "wav",
                mimeType: "audio/wav"
            )
        )

        XCTAssertEqual(transcript, "hello")
    }

    func testGeminiAudioUsesHighestThroughputRouting() async throws {
        let audioData = Data("audio-to-gemini".utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try audioData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        URLProtocolStub.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://openrouter.ai/api/v1/chat/completions"
            )
            let body = try XCTUnwrap(try requestBody(request))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(
                payload["model"] as? String,
                OpenRouterService.geminiDictationModel
            )
            XCTAssertEqual(
                (payload["provider"] as? [String: Any])?["sort"] as? String,
                "throughput"
            )
            XCTAssertEqual(
                (payload["reasoning"] as? [String: Any])?["effort"] as? String,
                "minimal"
            )
            XCTAssertEqual(
                (payload["reasoning"] as? [String: Any])?["exclude"] as? Bool,
                true
            )

            let content = try userContent(from: payload)
            XCTAssertEqual(content.count, 2)
            XCTAssertFalse(
                try XCTUnwrap(content.first?["text"] as? String)
                    .contains("Whisper draft")
            )
            let inputAudio = try XCTUnwrap(
                content.last?["input_audio"] as? [String: Any]
            )
            XCTAssertEqual(inputAudio["format"] as? String, "m4a")
            XCTAssertEqual(
                inputAudio["data"] as? String,
                audioData.base64EncodedString()
            )

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (
                response,
                Data(
                    #"{"model":"google/gemini-3.5-flash","provider":"Google AI Studio","choices":[{"message":{"content":"Clean dictation."}}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13,"cost":0.001}}"#.utf8
                )
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = OpenRouterService(
            urlSession: URLSession(configuration: configuration)
        )
        let response = try await service.performAudioDictation(
            apiKey: "test-key",
            audio: RecordedAudio(
                fileURL: fileURL,
                format: "m4a",
                mimeType: "audio/mp4"
            ),
            draftTranscript: nil,
            rewriteInstruction: "Preserve meaning."
        )

        XCTAssertEqual(response.text, "Clean dictation.")
        XCTAssertEqual(response.provider, "Google AI Studio")
        XCTAssertEqual(response.usage?.totalTokens, 13)
        XCTAssertEqual(response.usage?.cost, 0.001)
    }

    func testGeminiHybridSendsAudioAndWhisperDraft() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data("hybrid-audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        URLProtocolStub.handler = { request in
            let body = try XCTUnwrap(try requestBody(request))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(
                payload["model"] as? String,
                "mistralai/voxtral-small-24b-2507"
            )
            XCTAssertNil(payload["reasoning"])
            let content = try userContent(from: payload)
            XCTAssertEqual(content.count, 2)
            let prompt = try XCTUnwrap(content.first?["text"] as? String)
            XCTAssertTrue(prompt.contains("The attached audio is the source of truth."))
            XCTAssertTrue(prompt.contains("Whisper draft"))
            XCTAssertTrue(prompt.contains("possible product name"))
            XCTAssertEqual(content.last?["type"] as? String, "input_audio")

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (
                response,
                Data(#"{"choices":[{"message":{"content":"Final text"}}]}"#.utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = OpenRouterService(
            urlSession: URLSession(configuration: configuration)
        )
        let response = try await service.performAudioDictation(
            apiKey: "test-key",
            model: "mistralai/voxtral-small-24b-2507",
            audio: RecordedAudio(
                fileURL: fileURL,
                format: "wav",
                mimeType: "audio/wav"
            ),
            draftTranscript: "possible product name",
            rewriteInstruction: "Preserve meaning."
        )

        XCTAssertEqual(response.text, "Final text")
    }

    func testGPTAudioEnhancementUsesTextContextWithoutUnsupportedImage() async throws {
        let audioData = Data("prepared-wav-audio".utf8)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        let screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try audioData.write(to: audioURL)
        try Data("screenshot".utf8).write(to: screenshotURL)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: screenshotURL)
        }

        URLProtocolStub.handler = { request in
            let body = try XCTUnwrap(try requestBody(request))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(
                payload["model"] as? String,
                OpenRouterService.defaultAudioEnhancementModel
            )

            let content = try userContent(from: payload)
            XCTAssertEqual(content.count, 2, "GPT Audio Mini does not accept image input")
            let prompt = try XCTUnwrap(content.first?["text"] as? String)
            XCTAssertTrue(prompt.contains("Project SuperSamuel"))
            XCTAssertTrue(prompt.contains("use only to disambiguate"))
            XCTAssertFalse(prompt.contains("Whisper draft"))
            XCTAssertEqual(content.last?["type"] as? String, "input_audio")

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (
                response,
                Data(#"{"choices":[{"message":{"content":"Enhanced text"}}]}"#.utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = OpenRouterService(
            urlSession: URLSession(configuration: configuration)
        )
        let response = try await service.performAudioDictation(
            apiKey: "test-key",
            model: OpenRouterService.defaultAudioEnhancementModel,
            audio: RecordedAudio(
                fileURL: audioURL,
                format: "wav",
                mimeType: "audio/wav"
            ),
            draftTranscript: nil,
            rewriteInstruction: "Preserve meaning.",
            supportingContext: "Project SuperSamuel",
            screenshotURL: screenshotURL
        )

        XCTAssertEqual(response.text, "Enhanced text")
    }

    func testGeminiEnhancementIncludesNativeScreenshotContext() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        let screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("audio".utf8).write(to: audioURL)
        let screenshotData = Data("image".utf8)
        try screenshotData.write(to: screenshotURL)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: screenshotURL)
        }

        URLProtocolStub.handler = { request in
            let body = try XCTUnwrap(try requestBody(request))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let content = try userContent(from: payload)
            XCTAssertEqual(content.count, 3)
            XCTAssertEqual(content.last?["type"] as? String, "image_url")
            let image = try XCTUnwrap(
                content.last?["image_url"] as? [String: Any]
            )
            XCTAssertEqual(
                image["url"] as? String,
                "data:image/jpeg;base64,\(screenshotData.base64EncodedString())"
            )

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (
                response,
                Data(#"{"choices":[{"message":{"content":"Gemini text"}}]}"#.utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = OpenRouterService(
            urlSession: URLSession(configuration: configuration)
        )
        _ = try await service.performAudioDictation(
            apiKey: "test-key",
            model: "google/gemini-3.5-flash",
            audio: RecordedAudio(
                fileURL: audioURL,
                format: "wav",
                mimeType: "audio/wav"
            ),
            draftTranscript: nil,
            rewriteInstruction: "Preserve meaning.",
            supportingContext: "Visible project name",
            screenshotURL: screenshotURL
        )
    }

    @MainActor
    func testAudioEnhancementBypassesWhisperAndConvertsM4AToWAV() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingStore = RecordingStore(rootDirectory: root)
        let historyStore = TranscriptHistoryStore(rootDirectory: root)
        let session = try recordingStore.createSession(
            cleanup: PersistedCleanupOptions(
                isEnabled: true,
                model: OpenRouterService.defaultAudioEnhancementModel,
                prompt: "Preserve meaning.",
                mode: .audioEnhancement
            )
        )
        _ = try addAudibleChunk(
            to: recordingStore,
            sessionID: session.id,
            sample: 10_000
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = OpenRouterService(
            urlSession: URLSession(configuration: configuration)
        )
        let processor = RecordingProcessor(
            recordingStore: recordingStore,
            historyStore: historyStore,
            openRouterService: service
        )

        let requestCount = LockedCounter()
        URLProtocolStub.handler = { request in
            XCTAssertEqual(requestCount.increment(), 1)
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://openrouter.ai/api/v1/chat/completions"
            )
            let body = try XCTUnwrap(try requestBody(request))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let content = try userContent(from: payload)
            let inputAudio = try XCTUnwrap(
                content.last?["input_audio"] as? [String: Any]
            )
            XCTAssertEqual(inputAudio["format"] as? String, "wav")
            let encoded = try XCTUnwrap(inputAudio["data"] as? String)
            let converted = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertEqual(String(data: converted.prefix(4), encoding: .ascii), "RIFF")

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (
                response,
                Data(#"{"choices":[{"message":{"content":"Direct enhanced result"}}]}"#.utf8)
            )
        }

        let result = try await processor.process(
            sessionID: session.id,
            apiKey: "test-key",
            onProgress: { _ in }
        )

        XCTAssertEqual(result.transcript, "Direct enhanced result")
        XCTAssertEqual(requestCount.value, 1)
    }

    @MainActor
    func testRetryReusesSuccessfulChunkAfterLaterRequestFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingStore = RecordingStore(rootDirectory: root)
        let historyStore = TranscriptHistoryStore(rootDirectory: root)
        let session = try recordingStore.createSession(
            cleanup: PersistedCleanupOptions(
                isEnabled: false,
                model: "",
                prompt: ""
            )
        )
        let firstChunk = try addAudibleChunk(
            to: recordingStore,
            sessionID: session.id,
            sample: 10_000
        )
        let secondChunk = try addAudibleChunk(
            to: recordingStore,
            sessionID: session.id,
            sample: 12_000
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = OpenRouterService(
            urlSession: URLSession(configuration: configuration)
        )
        let processor = RecordingProcessor(
            recordingStore: recordingStore,
            historyStore: historyStore,
            openRouterService: service
        )

        let firstAttemptCount = LockedCounter()
        URLProtocolStub.handler = { request in
            let requestNumber = firstAttemptCount.increment()
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: requestNumber == 1 ? 200 : 400,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            let data = requestNumber == 1
                ? Data(#"{"text":"first part"}"#.utf8)
                : Data(#"{"error":{"message":"invalid audio"}}"#.utf8)
            return (response, data)
        }

        do {
            _ = try await processor.process(
                sessionID: session.id,
                apiKey: "test-key",
                onProgress: { _ in }
            )
            XCTFail("The second chunk should fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "OpenRouter request failed: HTTP 400: invalid audio"
            )
        }

        XCTAssertEqual(firstAttemptCount.value, 2)
        XCTAssertEqual(
            recordingStore.cachedTranscript(
                sessionID: session.id,
                chunkID: firstChunk.id,
                cleaned: false
            ),
            "first part"
        )
        XCTAssertNil(
            recordingStore.cachedTranscript(
                sessionID: session.id,
                chunkID: secondChunk.id,
                cleaned: false
            )
        )
        XCTAssertNoThrow(try recordingStore.load(session.id))

        let retryCount = LockedCounter()
        URLProtocolStub.handler = { request in
            _ = retryCount.increment()
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data(#"{"text":"second part"}"#.utf8))
        }

        let result = try await processor.process(
            sessionID: session.id,
            apiKey: "test-key",
            onProgress: { _ in }
        )

        XCTAssertEqual(retryCount.value, 1)
        XCTAssertEqual(result.transcript, "first part\n\nsecond part")
        XCTAssertThrowsError(try recordingStore.load(session.id))
        XCTAssertEqual(
            try historyStore.item(id: session.id)?.text,
            "first part\n\nsecond part"
        )
        let archive = try XCTUnwrap(historyStore.artifactURL(for: session.id))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: archive.appendingPathComponent(firstChunk.filename).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: archive.appendingPathComponent(secondChunk.filename).path
            )
        )
        XCTAssertEqual(
            try historyStore.metadata(id: session.id)?.workflow.workflow,
            .whisperOnly
        )
    }

    @MainActor
    private func addAudibleChunk(
        to store: RecordingStore,
        sessionID: UUID,
        sample: Int16
    ) throws -> RecordingChunk {
        let fileURL = try store.beginChunk(in: sessionID)
        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000
                ]
            )
            let format = try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                )
            )
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)
            )
            buffer.frameLength = 1_600
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<Int(buffer.frameLength) {
                samples[index] = Float(sample) / Float(Int16.max)
            }
            try file.write(from: buffer)
        }

        try store.finishCurrentChunk(in: sessionID, duration: 0.1)
        return try XCTUnwrap(store.load(sessionID).chunks.last)
    }
}

private func requestBody(_ request: URLRequest) throws -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? URLError(.cannotDecodeContentData)
        }
        if count == 0 {
            return body
        }
        body.append(buffer, count: count)
    }
}

private func userContent(from payload: [String: Any]) throws -> [[String: Any]] {
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let userMessage = try XCTUnwrap(
        messages.first { $0["role"] as? String == "user" }
    )
    return try XCTUnwrap(userMessage["content"] as? [[String: Any]])
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("URLProtocolStub.handler was not set")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
