import AVFoundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class RecordingStoreTests: XCTestCase {
    func testChangingCleanupPreservesDraftAndOnlyInvalidatesEditedResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootDirectory: root)
        let cleanup = TranscriptCleanupConfiguration(model: "google/gemini-3.8-flash", instructions: "Keep names")
        let session = try store.createSession(cleanup: cleanup)
        let audio = try store.beginChunk(in: session.id)
        try Data([1, 2, 3]).write(to: audio)
        try store.saveDraftTranscript("Original words", sessionID: session.id)
        try store.saveFinalTranscript("Edited words", sessionID: session.id)
        try store.prepareForProcessing(sessionID: session.id, cleanup: nil, screenshotSourceURL: nil)
        XCTAssertNil(try store.load(session.id).cleanup)
        XCTAssertNil(store.finalTranscript(sessionID: session.id))
        XCTAssertEqual(store.draftTranscript(sessionID: session.id), "Original words")
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
    }

    func testTranscriptionConfigurationPersistsWithSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingStore(rootDirectory: root)
        let session = try store.createSession(
            transcriptionModel: "openai/gpt-transcribe",
            transcriptionContext: "  Expected term: SuperSamuel.  "
        )

        let reloaded = try store.load(session.id)
        XCTAssertEqual(
            reloaded.resolvedTranscriptionModel,
            "openai/gpt-transcribe"
        )
        XCTAssertEqual(
            reloaded.resolvedTranscriptionContext,
            "Expected term: SuperSamuel."
        )
    }

    /// Records a session end to end the way the app does — begin, write AAC,
    /// finish, read back — so a regression in the chunk filename, extension or
    /// mime type fails here instead of at upload time.
    func testChunkRoundTripsAsUploadableM4A() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingStore(rootDirectory: root)
        let session = try store.createSession()

        let fileURL = try store.beginChunk(in: session.id)
        XCTAssertEqual(fileURL.pathExtension, "m4a")
        try writeSilentAAC(to: fileURL, seconds: 0.5)
        try store.finishCurrentChunk(in: session.id, duration: 0.5)

        let chunks = try store.audioChunks(for: store.load(session.id))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].1.format, "m4a")
        XCTAssertEqual(chunks[0].1.mimeType, "audio/mp4")
        XCTAssertGreaterThan(chunks[0].0.sizeBytes ?? 0, 0)
        XCTAssertNoThrow(try AVAudioFile(forReading: chunks[0].1.fileURL))
    }

    func testAudioChunksRejectsSessionWithNoAudioOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingStore(rootDirectory: root)
        let session = try store.createSession()
        _ = try store.beginChunk(in: session.id)

        XCTAssertThrowsError(
            try store.audioChunks(for: store.load(session.id))
        )
    }

    func testRetryAndChangedConfigurationInvalidateEveryDerivedResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootDirectory: root)

        for change in ["explicit", "model", "context", "vocabulary"] {
            let session = try store.createSession(transcriptionContext: "Original", vocabulary: ["Samuel"])
            let audioURL = try store.beginChunk(in: session.id)
            try Data([1, 2, 3]).write(to: audioURL)
            let chunk = try XCTUnwrap(store.load(session.id).chunks.first)
            try store.saveDraftTranscript("Old draft", sessionID: session.id)
            try store.saveFinalTranscript("Old final", sessionID: session.id)
            try store.saveLivePartialTranscript("Old live fragment", sessionID: session.id)
            try store.saveTranscript("Old raw", sessionID: session.id, chunkID: chunk.id, cleaned: false)
            try store.saveTranscript("Old cleanup", sessionID: session.id, chunkID: chunk.id, cleaned: true)
            try store.markChunkAsNoSpeech(sessionID: session.id, chunkID: chunk.id)

            try store.prepareForProcessing(
                sessionID: session.id,
                transcriptionModel: change == "model" ? "openai/whisper-large-v3" : OpenRouterService.transcriptionModel,
                transcriptionContext: change == "context" ? "Updated" : "Original",
                vocabulary: change == "vocabulary" ? ["SuperSamuel"] : ["Samuel"],
                forceRetranscription: change == "explicit",
                screenshotSourceURL: nil
            )

            XCTAssertNil(store.draftTranscript(sessionID: session.id), change)
            XCTAssertNil(store.finalTranscript(sessionID: session.id), change)
            XCTAssertNil(store.livePartialTranscript(sessionID: session.id), change)
            XCTAssertNil(store.cachedTranscript(sessionID: session.id, chunkID: chunk.id, cleaned: false), change)
            XCTAssertNil(store.cachedTranscript(sessionID: session.id, chunkID: chunk.id, cleaned: true), change)
            XCTAssertFalse(store.chunkHadNoSpeech(sessionID: session.id, chunkID: chunk.id), change)
            XCTAssertEqual(try Data(contentsOf: audioURL), Data([1, 2, 3]), change)
        }
    }

    func testCompatibleResumeKeepsResultsAndLegacyAudioOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootDirectory: root)
        let session = try store.createSession(transcriptionContext: "Context", vocabulary: ["SuperSamuel"])
        for _ in 0..<2 {
            try Data([1, 2, 3]).write(to: store.beginChunk(in: session.id))
        }
        var legacy = try store.load(session.id)
        legacy.chunks.reverse()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: store.directoryURL(for: session.id).appendingPathComponent("manifest.json"))
        try store.saveDraftTranscript("Saved draft", sessionID: session.id)
        try store.prepareForProcessing(
            sessionID: session.id, transcriptionContext: "Context",
            vocabulary: ["SuperSamuel"], screenshotSourceURL: nil
        )
        XCTAssertEqual(store.draftTranscript(sessionID: session.id), "Saved draft")
        XCTAssertEqual(try store.audioChunks(for: store.load(session.id)).map { $0.0.id }, legacy.chunks.map(\.id))
    }

    private func writeSilentAAC(to url: URL, seconds: Double) throws {
        let file = try AVAudioFile(
            forWriting: url,
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
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}
