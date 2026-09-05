import Foundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class TranscriptHistoryStoreTests: XCTestCase {
    func testArchiveRecordsTranscriptionContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingStore = RecordingStore(rootDirectory: root)
        let historyStore = TranscriptHistoryStore(rootDirectory: root)
        let session = try recordingStore.createSession(
            transcriptionModel: "openai/gpt-transcribe",
            transcriptionContext: "Expected term: SuperSamuel."
        )

        _ = try await historyStore.archive(
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

    func testArchiveKeepsAudioTranscriptsAndProvenanceTogether() async throws {
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
        let item = try await historyStore.archive(
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
        let recent = try await historyStore.recent()
        XCTAssertEqual(recent.map(\.id), [session.id])
    }

    func testLegacyFlatTranscriptStillLoads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TranscriptHistoryStore(rootDirectory: root)
        let id = UUID()
        _ = try await store.save(
            recordingID: id,
            createdAt: Date(timeIntervalSince1970: 100),
            text: "Legacy transcript"
        )

        XCTAssertEqual(try store.item(id: id)?.text, "Legacy transcript")
        let recent = try await store.recent()
        XCTAssertEqual(recent.map(\.id), [id])
        XCTAssertEqual(store.artifactURL(for: id)?.pathExtension, "json")
        XCTAssertNil(try store.metadata(id: id))
    }

    func testArchiveAndListingRunOffMainThreadAndRefreshAfterMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingStore = RecordingStore(rootDirectory: root)
        let manager = HistoryFileManagerSpy()
        let store = TranscriptHistoryStore(fileManager: manager, rootDirectory: root)
        let original = try recordingStore.createSession(
            vocabulary: ["SuperSamuel"], liveTranscriptionModel: "gpt-live-transcribe",
            liveTranscriptionDelay: "xhigh"
        )
        try recordingStore.setCaptureContinuity(live: true, saved: true, for: original.id)
        try recordingStore.setTranscriptSource("live", for: original.id)
        _ = try await store.archive(
            session: recordingStore.load(original.id),
            recordingDirectory: recordingStore.directoryURL(for: original.id), text: "Newest"
        )
        let first = try await store.recent()
        let second = try await store.recent()
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(manager.directoryReads, 1)
        XCTAssertFalse(manager.didHeavyWorkOnMainThread)
        let metadata = try XCTUnwrap(store.metadata(id: original.id))
        XCTAssertEqual(metadata.workflow.transcriptionModel, "gpt-live-transcribe")
        XCTAssertEqual(metadata.workflow.liveTranscriptionDelay, "xhigh")
        XCTAssertEqual(metadata.workflow.vocabulary, ["SuperSamuel"])
        XCTAssertEqual(metadata.liveCaptureContinuous, true)

        try recordingStore.prepareForProcessing(
            sessionID: original.id, transcriptionModel: "openai/whisper-large-v3",
            vocabulary: ["Updated vocabulary"], forceRetranscription: true,
            screenshotSourceURL: nil
        )
        try recordingStore.setTranscriptSource("saved-audio", for: original.id)
        _ = try await store.archive(
            session: recordingStore.load(original.id),
            recordingDirectory: recordingStore.directoryURL(for: original.id), text: "Newest"
        )
        let retriedMetadata = try XCTUnwrap(store.metadata(id: original.id))
        XCTAssertEqual(retriedMetadata.workflow.transcriptionModel, "openai/whisper-large-v3")
        XCTAssertEqual(retriedMetadata.workflow.vocabulary, ["Updated vocabulary"])

        let olderID = UUID()
        _ = try await store.save(recordingID: olderID, createdAt: .distantPast, text: "Older")
        let afterSave = try await store.recent()
        XCTAssertEqual(afterSave.map(\.id), [original.id, olderID])
        try FileManager.default.removeItem(at: XCTUnwrap(store.artifactURL(for: olderID)))
        let afterExternalRemoval = try await store.recent()
        XCTAssertEqual(afterExternalRemoval.map(\.id), [original.id])
        try await store.clear()
        let afterClear = try await store.recent()
        XCTAssertTrue(afterClear.isEmpty)
        XCTAssertNil(try store.item(id: original.id))
    }
}

private final class HistoryFileManagerSpy: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var mainThreadWork = false
    var directoryReads: Int { lock.withLock { reads } }
    var didHeavyWorkOnMainThread: Bool { lock.withLock { mainThreadWork } }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        lock.withLock { mainThreadWork = mainThreadWork || Thread.isMainThread }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        lock.withLock {
            reads += 1
            mainThreadWork = mainThreadWork || Thread.isMainThread
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
