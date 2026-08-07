import AVFoundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class RecordingStoreTests: XCTestCase {
    func testLegacyCleanupOptionsDecodeWithoutEnhancementMode() throws {
        let data = Data(
            #"{"isEnabled":true,"model":"legacy/text-model","prompt":"Clean it"}"#.utf8
        )

        let options = try JSONDecoder().decode(
            PersistedCleanupOptions.self,
            from: data
        )

        XCTAssertFalse(options.usesAudioEnhancement)
        XCTAssertNil(options.mode)
    }

    /// Records a session end to end the way the app does — begin, write AAC,
    /// finish, read back — so a regression in the chunk filename, extension or
    /// mime type fails here instead of at upload time.
    func testChunkRoundTripsAsUploadableM4A() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingStore(rootDirectory: root)
        let session = try store.createSession(
            cleanup: PersistedCleanupOptions(
                isEnabled: false,
                model: "",
                prompt: ""
            )
        )

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
        let session = try store.createSession(
            cleanup: PersistedCleanupOptions(
                isEnabled: false,
                model: "",
                prompt: ""
            )
        )
        _ = try store.beginChunk(in: session.id)

        XCTAssertThrowsError(
            try store.audioChunks(for: store.load(session.id))
        )
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
