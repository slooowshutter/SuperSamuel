import Foundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class TranscriptHistoryStoreTests: XCTestCase {
    func testArchiveRecordsTranscriptionContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingStore = RecordingStore(rootDirectory: root)
        let historyStore = TranscriptHistoryStore(rootDirectory: root)
        let session = try recordingStore.createSession(
            transcriptionModel: "openai/gpt-transcribe",
            transcriptionContext: "Expected term: SuperSamuel."
        )

        _ = try historyStore.archive(
            session: session,
            recordingDirectory: recordingStore.directoryURL(for: session.id),
            text: "SuperSamuel"
        )
        let metadata = try XCTUnwrap(historyStore.metadata(id: session.id))

        XCTAssertEqual(metadata.workflow.workflow, .transcriptionOnly)
        XCTAssertEqual(
            metadata.workflow.transcriptionModel,
            "openai/gpt-transcribe"
        )
        XCTAssertEqual(
            metadata.workflow.transcriptionContext,
            "Expected term: SuperSamuel."
        )
    }

    func testArchiveKeepsAudioTranscriptsAndProvenanceTogether() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingStore = RecordingStore(rootDirectory: root)
        let historyStore = TranscriptHistoryStore(rootDirectory: root)
        let original = try recordingStore.createSession(
            transcriptionModel: "openai/gpt-transcribe",
            transcriptionContext: "Preserve product names exactly."
        )
        let audioURL = try recordingStore.beginChunk(in: original.id)
        try Data([0, 1, 2, 3]).write(to: audioURL)
        try recordingStore.finishCurrentChunk(in: original.id, duration: 12.5)
        try recordingStore.setInputDevice(
            AudioInputDeviceInfo(name: "Test Microphone", uniqueID: "test-mic"),
            for: original.id
        )
        try recordingStore.saveFinalTranscript(
            "The final transcript.",
            sessionID: original.id
        )

        let session = try recordingStore.load(original.id)
        let item = try historyStore.archive(
            session: session,
            recordingDirectory: recordingStore.directoryURL(for: session.id),
            text: "The final transcript."
        )
        let directory = try XCTUnwrap(historyStore.artifactURL(for: item.id))
        let metadata = try XCTUnwrap(historyStore.metadata(id: item.id))

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("chunk-0001.m4a").path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("transcript.txt"),
                encoding: .utf8
            ),
            "The final transcript."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("final-transcript.txt").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("manifest.json").path
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archivedSession = try decoder.decode(
            RecordingSession.self,
            from: Data(
                contentsOf: directory.appendingPathComponent("manifest.json")
            )
        )
        XCTAssertEqual(archivedSession.status, .completed)
        XCTAssertEqual(archivedSession.completedTranscriptID, session.id)
        XCTAssertEqual(metadata.schemaVersion, 1)
        XCTAssertEqual(metadata.workflow.workflow, .transcriptionOnly)
        XCTAssertEqual(
            metadata.workflow.transcriptionModel,
            "openai/gpt-transcribe"
        )
        XCTAssertEqual(
            metadata.workflow.transcriptionContext,
            "Preserve product names exactly."
        )
        XCTAssertEqual(metadata.inputDevice?.name, "Test Microphone")
        XCTAssertEqual(metadata.audio.first?.durationSeconds, 12.5)
        XCTAssertEqual(try historyStore.recent().map(\.id), [session.id])
    }

    func testLegacyFlatTranscriptStillLoads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TranscriptHistoryStore(rootDirectory: root)
        let id = UUID()
        _ = try store.save(
            recordingID: id,
            createdAt: Date(timeIntervalSince1970: 100),
            text: "Legacy transcript"
        )

        XCTAssertEqual(try store.item(id: id)?.text, "Legacy transcript")
        XCTAssertEqual(try store.recent().map(\.id), [id])
        XCTAssertEqual(store.artifactURL(for: id)?.pathExtension, "json")
        XCTAssertNil(try store.metadata(id: id))
    }
}
