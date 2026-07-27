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
                OpenRouterService.transcriptionModel
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
            audio: RecordedAudio(
                fileURL: fileURL,
                format: "wav",
                mimeType: "audio/wav"
            )
        )

        XCTAssertEqual(transcript, "hello")
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
    }

    @MainActor
    private func addAudibleChunk(
        to store: RecordingStore,
        sessionID: UUID,
        sample: Int16
    ) throws -> RecordingChunk {
        let fileURL = try store.beginChunk(in: sessionID)
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
