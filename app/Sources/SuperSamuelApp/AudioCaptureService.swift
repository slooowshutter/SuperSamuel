import AVFoundation
import Foundation

struct AudioInputDeviceInfo: Codable, Equatable {
    let name: String
    let uniqueID: String
}

struct RecordedAudio {
    let fileURL: URL
    let format: String
    let mimeType: String
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

/// Records the default microphone straight to an AAC `.m4a` file.
///
/// ponytail: `AVAudioRecorder` owns the device, the encoder and the file, so
/// there is no tap, no format converter, no WAV header bookkeeping and no
/// watchdog. A *fresh* recorder per recording is what makes this survive
/// sleep/lock: the previous long-lived `AVAudioEngine` cached the hardware
/// input format and threw -10868 once the HAL reconfigured on wake.
final class AudioCaptureService {
    private let fileManager: FileManager
    private var recorder: AVAudioRecorder?
    private var displayedLevel: Float = 0

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var isRecording: Bool {
        recorder != nil
    }

    func currentInputDeviceInfo() -> AudioInputDeviceInfo {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            return AudioInputDeviceInfo(
                name: "System Default Microphone",
                uniqueID: "system-default"
            )
        }

        return AudioInputDeviceInfo(
            name: device.localizedName,
            uniqueID: device.uniqueID
        )
    }

    @discardableResult
    func start(at fileURL: URL) throws -> AudioInputDeviceInfo {
        guard recorder == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: fileURL)

        // 16 kHz mono AAC: speech-grade, ~14 MB/hour, one upload for any
        // realistic dictation length.
        let recorder = try AVAudioRecorder(
            url: fileURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ]
        )
        recorder.isMeteringEnabled = true

        guard recorder.record() else {
            throw AudioCaptureError.inputUnavailable
        }

        self.recorder = recorder
        displayedLevel = 0
        return currentInputDeviceInfo()
    }

    func stop() throws -> RecordedAudio {
        guard let recorder else {
            throw AudioCaptureError.recordingFailed("No recording is active.")
        }

        let fileURL = recorder.url
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        displayedLevel = 0

        guard duration > 0.1, fileSize(at: fileURL) > 0 else {
            throw AudioCaptureError.emptyRecording
        }

        return RecordedAudio(
            fileURL: fileURL,
            format: "m4a",
            mimeType: "audio/mp4"
        )
    }

    func stopIfNeeded() -> RecordedAudio? {
        guard isRecording else {
            return nil
        }
        return try? stop()
    }

    func currentLevel() -> Float {
        guard let recorder else {
            return 0
        }

        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        let target = pow(min(max((decibels + 50) / 50, 0), 1), 1.5)
        displayedLevel += (target - displayedLevel) *
            (target > displayedLevel ? 0.55 : 0.22)
        return displayedLevel
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
