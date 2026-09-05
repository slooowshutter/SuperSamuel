import AVFoundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class DictationControllerTests: XCTestCase {
    func testKeptRecordingDoesNotBlockStartingAnotherRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SuperSamuelRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = CredentialStore(service: suite)
        let openAICredentials = CredentialStore(service: suite, account: "openai")
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            try? credentials.writeAPIKey("")
        }
        let settings = SettingsStore(defaults: defaults, credentials: credentials, openAICredentials: openAICredentials)
        settings.openRouterAPIKey = "test-key"
        settings.realtimeTranscriptionEnabled = false
        let store = RecordingStore(rootDirectory: root)
        let kept = try store.createSession()
        let oldAudio = try store.beginChunk(in: kept.id)
        try Data([1, 2, 3]).write(to: oldAudio)
        try store.finishCurrentChunk(in: kept.id, duration: 1)
        try store.markReady(kept.id, message: "Kept for later")
        let capture = AudioCaptureService(makeRecorder: { RecoveryTestRecorder(url: $0) })
        var permissionRequests = 0
        let controller = DictationController(
            settings: settings,
            recordingStore: store,
            historyStore: TranscriptHistoryStore(rootDirectory: root),
            audioCapture: capture,
            microphonePermission: { permissionRequests += 1 }
        )
        defer { controller.shutdown() }

        await controller.startRecording()

        XCTAssertEqual(permissionRequests, 1)
        XCTAssertTrue(capture.isRecording)
        XCTAssertEqual(try store.pendingSessions().count, 2)
        XCTAssertEqual(try store.load(kept.id).status, .ready)
        XCTAssertEqual(try Data(contentsOf: oldAudio), Data([1, 2, 3]))

        // An immediate Stop is harmless and preserves its file, then another start works.
        controller.stopAndProcessRecording()
        XCTAssertFalse(capture.hasActiveRecording)
        XCTAssertEqual(try store.pendingSessions().count, 2)
        await controller.startRecording()
        XCTAssertEqual(permissionRequests, 2)
        XCTAssertTrue(capture.isRecording)
        XCTAssertEqual(try store.pendingSessions().count, 3)
    }
}

private final class RecoveryTestRecorder: AudioRecording {
    let url: URL
    var isRecording = false
    var currentTime: TimeInterval = 0
    var isMeteringEnabled = false
    var delegate: AVAudioRecorderDelegate?

    init(url: URL) { self.url = url }
    func record() -> Bool {
        try? Data([4, 5, 6]).write(to: url)
        isRecording = true
        return true
    }
    func stop() { isRecording = false }
    func updateMeters() {}
    func averagePower(forChannel channelNumber: Int) -> Float { -160 }
}
