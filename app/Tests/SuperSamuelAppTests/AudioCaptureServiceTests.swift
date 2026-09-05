import AVFoundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class AudioCaptureServiceTests: XCTestCase {
    func testSilenceKeepsRecorderHealthyButMissingSamplesDoNot() throws {
        var now: TimeInterval = 10
        let recorder = TestAudioRecorder()
        let service = AudioCaptureService(makeRecorder: { recorder.url = $0; return recorder }, clock: { now })
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try service.start(at: url)

        for second in 1...8 {
            now += 1
            recorder.currentTime = TimeInterval(second)
            XCTAssertEqual(service.currentLevel(), 0)
            XCTAssertEqual(service.checkHealth(), .healthy)
        }
        now += 2
        guard case .interrupted = service.checkHealth() else {
            return XCTFail("A recorder that stops producing samples must report an interruption.")
        }
        _ = service.stopIfNeeded()
    }

    func testStoppedRecorderStillFinalizesFileAndRetainsDuration() throws {
        let recorder = TestAudioRecorder()
        let service = AudioCaptureService(makeRecorder: { recorder.url = $0; return recorder })
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try service.start(at: url)
        try writeSilentAAC(to: url, seconds: 0.5)
        recorder.currentTime = 0.4
        XCTAssertEqual(service.checkHealth(), .healthy)
        recorder.isRecording = false
        recorder.currentTime = 0

        XCTAssertFalse(service.isRecording)
        XCTAssertTrue(service.hasActiveRecording)
        guard case .interrupted = service.checkHealth() else {
            return XCTFail("An unexpectedly stopped recorder must report an interruption.")
        }
        let audio = try XCTUnwrap(service.stopIfNeeded())
        XCTAssertEqual(try XCTUnwrap(audio.duration), 0.5, accuracy: 0.01)
        XCTAssertEqual(service.recordedDuration, 0.5, accuracy: 0.01)
        XCTAssertFalse(service.hasActiveRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeviceChangeRequiresNewPartAndCannotOverwritePreviousAudio() throws {
        var device = AudioInputDeviceInfo(name: "Built-in", uniqueID: "built-in")
        let recorder = TestAudioRecorder()
        let service = AudioCaptureService(
            makeRecorder: { recorder.url = $0; return recorder },
            inputDeviceProvider: { device }
        )
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try service.start(at: url)
        try writeSilentAAC(to: url, seconds: 0.5)
        let original = try Data(contentsOf: url)
        device = AudioInputDeviceInfo(name: "USB", uniqueID: "usb")
        guard case .interrupted = service.checkHealth() else {
            return XCTFail("Switching the default microphone must rebuild the local recorder.")
        }
        _ = try service.stop()
        XCTAssertThrowsError(try service.start(at: url))
        XCTAssertEqual(try Data(contentsOf: url), original)

        let nextURL = url.deletingLastPathComponent().appendingPathComponent("part-2.m4a")
        XCTAssertEqual(try service.start(at: nextURL), device)
        XCTAssertEqual(service.inputDevice, device)
        XCTAssertEqual(service.checkHealth(), .healthy)
        _ = service.stopIfNeeded()
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFailedNewStartDoesNotReusePreviousRecordingDuration() throws {
        let recorder = TestAudioRecorder()
        let service = AudioCaptureService(makeRecorder: { recorder.url = $0; return recorder })
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try service.start(at: url)
        try writeSilentAAC(to: url, seconds: 0.5)
        _ = try service.stop()
        XCTAssertEqual(service.recordedDuration, 0.5, accuracy: 0.01)

        recorder.recordSucceeds = false
        let nextURL = url.deletingLastPathComponent().appendingPathComponent("part-2.m4a")
        XCTAssertThrowsError(try service.start(at: nextURL))
        XCTAssertEqual(service.recordedDuration, 0)
        XCTAssertNil(service.inputDevice)
        XCTAssertFalse(service.hasActiveRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedFinalizationRetainsLastObservedRecordedDuration() throws {
        let recorder = TestAudioRecorder()
        let service = AudioCaptureService(makeRecorder: { recorder.url = $0; return recorder })
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try service.start(at: url)
        recorder.currentTime = 1.25
        _ = service.checkHealth()
        recorder.currentTime = 0
        recorder.isRecording = false
        XCTAssertThrowsError(try service.stop())
        XCTAssertEqual(service.recordedDuration, 1.25)
        XCTAssertFalse(service.hasActiveRecording)
    }

    private func temporaryAudioURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("part-1.m4a")
    }

    private func writeSilentAAC(to url: URL, seconds: Double) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        memset(buffer.floatChannelData![0], 0, Int(frames) * MemoryLayout<Float>.size)
        try file.write(from: buffer)
    }
}

private final class TestAudioRecorder: AudioRecording {
    var url = URL(fileURLWithPath: "/unused")
    var delegate: (any AVAudioRecorderDelegate)?
    var isMeteringEnabled = false
    var isRecording = false
    var recordSucceeds = true
    var currentTime: TimeInterval = 0

    func record() -> Bool {
        isRecording = recordSucceeds
        return recordSucceeds
    }

    func stop() {
        isRecording = false
        currentTime = 0
    }

    func updateMeters() {}
    func averagePower(forChannel channelNumber: Int) -> Float { -160 }
}

final class RealtimeSampleMonitorTests: XCTestCase {
    func testSilentSamplesKeepLiveCaptureHealthy() {
        let monitor = RealtimeSampleMonitor(startedAt: 0)
        for second in 1...8 {
            monitor.receivedSamples(frameCount: 24_000, at: TimeInterval(second))
            XCTAssertFalse(monitor.hasDiscontinuity(at: TimeInterval(second)))
        }
    }

    func testMissingSamplesRemainAnInterruptionAfterCaptureResumes() {
        let monitor = RealtimeSampleMonitor(startedAt: 0)
        monitor.receivedSamples(frameCount: 24_000, at: 1)
        monitor.receivedSamples(frameCount: 24_000, at: 4)
        XCTAssertTrue(monitor.hasDiscontinuity(at: 4))
        monitor.receivedSamples(frameCount: 24_000, at: 5)
        XCTAssertTrue(monitor.hasDiscontinuity(at: 5))
    }

    func testSampleTimelineGapInvalidatesEvenBeforeStallTimeout() {
        let monitor = RealtimeSampleMonitor(startedAt: 0)
        monitor.receivedSamples(frameCount: 2_048, sampleTime: 0, at: 0.1)
        monitor.receivedSamples(frameCount: 2_048, sampleTime: 2_048, at: 0.15)
        XCTAssertFalse(monitor.hasDiscontinuity(at: 0.15))
        monitor.receivedSamples(frameCount: 2_048, sampleTime: 6_144, at: 0.2)
        XCTAssertTrue(monitor.hasDiscontinuity(at: 0.2))
    }

    func testEmptyBuffersDoNotCountAsCapturedSamples() {
        let monitor = RealtimeSampleMonitor(startedAt: 0)
        monitor.receivedSamples(frameCount: 0, at: 1)
        XCTAssertTrue(monitor.hasDiscontinuity(at: 2))
    }

    func testConversionErrorInvalidatesLiveCompleteness() {
        let monitor = RealtimeSampleMonitor(startedAt: 0)
        monitor.receivedSamples(frameCount: 24_000, at: 0.5)
        monitor.conversionFailed()
        monitor.receivedSamples(frameCount: 24_000, at: 1)
        XCTAssertTrue(monitor.hasDiscontinuity(at: 1))
    }
}

final class RealtimeAudioDeliveryBufferTests: XCTestCase {
    func testStopDrainsFinalBuffersInOrderAndRejectsLaterAudio() {
        let buffer = RealtimeAudioDeliveryBuffer()
        XCTAssertTrue(buffer.enqueue { Data([1]) })
        XCTAssertFalse(buffer.enqueue { Data([2]) })
        XCTAssertEqual(buffer.drain(), [Data([1]), Data([2])])
        XCTAssertTrue(buffer.enqueue { Data([3]) })
        XCTAssertEqual(buffer.drain(finishing: true), [Data([3])])
        XCTAssertFalse(buffer.enqueue { XCTFail("Stopped capture must not convert additional audio."); return Data([4]) })
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    func testStopIncludesConversionAlreadyInFlight() async {
        let buffer = RealtimeAudioDeliveryBuffer()
        let started = DispatchSemaphore(value: 0)
        let finishConversion = DispatchSemaphore(value: 0)
        let producer = Task.detached {
            buffer.enqueue {
                started.signal()
                finishConversion.wait()
                return Data([1, 2, 3])
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let stopped = Task.detached { buffer.drain(finishing: true) }
        finishConversion.signal()
        _ = await producer.value
        let finalAudio = await stopped.value
        XCTAssertEqual(finalAudio, [Data([1, 2, 3])])
        XCTAssertTrue(buffer.drain().isEmpty)
    }
}
