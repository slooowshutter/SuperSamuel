import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDeviceInfo: Codable, Equatable, Sendable {
    let name: String
    let uniqueID: String
}

struct RecordedAudio: Sendable {
    let fileURL: URL
    let format: String
    let mimeType: String
    var duration: TimeInterval? = nil
}

enum AudioCaptureError: LocalizedError {
    case alreadyRecording
    case inputUnavailable
    case emptyRecording
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "An audio recording is already active."
        case .inputUnavailable:
            return "The microphone could not be started. Check your input device and try again."
        case .emptyRecording:
            return "The recording did not contain any audio."
        case .recordingFailed(let message):
            return "Audio recording failed: \(message)"
        }
    }
}

enum AudioCaptureHealth: Equatable {
    case healthy
    case interrupted(String)
}

/// Sample positions progress even through silence; meter levels cannot detect a stalled input.
struct AudioCaptureProgress {
    private var lastProgressAt: TimeInterval
    private(set) var duration: TimeInterval = 0

    init(startedAt: TimeInterval) {
        lastProgressAt = startedAt
    }

    mutating func observe(position: TimeInterval, at now: TimeInterval) {
        guard position > duration else { return }
        duration = position
        lastProgressAt = now
    }

    func isStalled(at now: TimeInterval, timeout: TimeInterval = 2) -> Bool {
        now - lastProgressAt >= timeout
    }
}

protocol AudioRecording: AnyObject {
    var url: URL { get }
    var delegate: (any AVAudioRecorderDelegate)? { get set }
    var isMeteringEnabled: Bool { get set }
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    func record() -> Bool
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: AudioRecording {}

/// Records each microphone segment to its own AAC file. A failed recorder stays owned until
/// Stop finalizes it, so recovery can preserve that file before starting a new segment.
@MainActor
final class AudioCaptureService: NSObject, AVAudioRecorderDelegate {
    private let fileManager: FileManager
    private let makeRecorder: (URL) throws -> any AudioRecording
    private let inputDeviceProvider: () -> AudioInputDeviceInfo
    private let clock: () -> TimeInterval
    private var recorder: (any AudioRecording)?
    private var recordingActivity: NSObjectProtocol?
    private var displayedLevel: Float = 0
    private var progress = AudioCaptureProgress(startedAt: 0)
    private var recorderError: String?
    private(set) var inputDevice: AudioInputDeviceInfo?
    private(set) var recordedDuration: TimeInterval = 0

    init(
        fileManager: FileManager = .default,
        makeRecorder: @escaping (URL) throws -> any AudioRecording = { url in
            try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000
                ]
            )
        },
        inputDeviceProvider: @escaping () -> AudioInputDeviceInfo = {
            AudioCaptureService.defaultInputDeviceInfo()
        },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.fileManager = fileManager
        self.makeRecorder = makeRecorder
        self.inputDeviceProvider = inputDeviceProvider
        self.clock = clock
        super.init()
    }

    deinit {
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
        }
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    var hasActiveRecording: Bool {
        recorder != nil
    }

    func currentInputDeviceInfo() -> AudioInputDeviceInfo {
        inputDeviceProvider()
    }

    @discardableResult
    func start(at fileURL: URL) throws -> AudioInputDeviceInfo {
        guard recorder == nil else {
            throw AudioCaptureError.alreadyRecording
        }
        recordedDuration = 0
        progress = AudioCaptureProgress(startedAt: clock())
        inputDevice = nil
        recorderError = nil
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            throw AudioCaptureError.recordingFailed("The destination already contains audio. Start a new recording part to preserve it.")
        }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let device = currentInputDeviceInfo()
        let recorder = try makeRecorder(fileURL)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        guard recorder.record() else {
            recorder.delegate = nil
            recorder.stop()
            throw AudioCaptureError.inputUnavailable
        }

        self.recorder = recorder
        inputDevice = device
        progress = AudioCaptureProgress(startedAt: clock())
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "SuperSamuel is recording audio"
        )
        displayedLevel = 0
        return device
    }

    /// Call while recording. An interruption requires a new file, never reusing the current path.
    func checkHealth() -> AudioCaptureHealth {
        guard let recorder else { return .healthy }
        observeProgress(recorder)
        if let recorderError { return .interrupted(recorderError) }
        guard recorder.isRecording else {
            return .interrupted("The local microphone recorder stopped unexpectedly.")
        }
        if currentInputDeviceInfo().uniqueID != inputDevice?.uniqueID {
            return .interrupted("The microphone changed; audio capture is restarting in a new recording part.")
        }
        if progress.isStalled(at: clock()) {
            return .interrupted("The local microphone recorder stopped receiving audio samples.")
        }
        return .healthy
    }

    func stop() throws -> RecordedAudio {
        guard let recorder else {
            throw AudioCaptureError.recordingFailed("No recording is active.")
        }
        defer { endRecordingActivity() }
        observeProgress(recorder)
        let fileURL = recorder.url
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        displayedLevel = 0

        // A stopped AVAudioRecorder reports currentTime == 0. Read the finalized file when
        // possible, retaining the last observed position if an interrupted file is unreadable.
        if let file = try? AVAudioFile(forReading: fileURL), file.processingFormat.sampleRate > 0 {
            recordedDuration = Double(file.length) / file.processingFormat.sampleRate
        }
        guard recordedDuration > 0.1, fileSize(at: fileURL) > 0 else {
            throw AudioCaptureError.emptyRecording
        }
        return RecordedAudio(
            fileURL: fileURL,
            format: "m4a",
            mimeType: "audio/mp4",
            duration: recordedDuration
        )
    }

    func stopIfNeeded() -> RecordedAudio? {
        guard hasActiveRecording else { return nil }
        return try? stop()
    }

    func currentLevel() -> Float {
        guard let recorder, recorder.isRecording else { return 0 }
        observeProgress(recorder)
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        let target = pow(min(max((decibels + 50) / 50, 0), 1), 1.5)
        displayedLevel += (target - displayedLevel) *
            (target > displayedLevel ? 0.55 : 0.22)
        return displayedLevel
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "The microphone audio could not be saved."
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.recorderError = message
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.recorderError = flag
                ? "The local microphone recorder stopped unexpectedly."
                : "The local microphone recorder failed while saving audio."
        }
    }

    private func observeProgress(_ recorder: any AudioRecording) {
        progress.observe(position: recorder.currentTime, at: clock())
        recordedDuration = max(recordedDuration, progress.duration)
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func endRecordingActivity() {
        guard let recordingActivity else { return }
        ProcessInfo.processInfo.endActivity(recordingActivity)
        self.recordingActivity = nil
    }

    nonisolated static func defaultInputDeviceInfo() -> AudioInputDeviceInfo {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return AudioInputDeviceInfo(name: "Unavailable Microphone", uniqueID: "unavailable")
        }
        func stringProperty(_ selector: AudioObjectPropertySelector) -> String? {
            var property = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &property, 0, nil, &size, &value) == noErr,
                  let value else {
                return nil
            }
            return value.takeRetainedValue() as String
        }
        return AudioInputDeviceInfo(
            name: stringProperty(kAudioObjectPropertyName) ?? "System Default Microphone",
            uniqueID: stringProperty(kAudioDevicePropertyDeviceUID) ?? "core-audio-\(deviceID)"
        )
    }
}
