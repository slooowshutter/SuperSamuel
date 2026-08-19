import AVFoundation
import Foundation

enum RealtimeAudioCaptureError: LocalizedError {
    case alreadyRunning
    case inputUnavailable
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Realtime audio capture is already running."
        case .inputUnavailable:
            return "The microphone is unavailable for realtime transcription."
        case .unsupportedFormat:
            return "The microphone audio could not be converted for realtime transcription."
        }
    }
}

/// A best-effort PCM sidecar for the Realtime API. The existing
/// `AVAudioRecorder` remains the durable source of truth and continues writing
/// the compact M4A even if this capture path cannot start or later disconnects.
final class RealtimeAudioCaptureService {
    static let sampleRate: Double = 24_000

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var onChunk: (@Sendable (Data) -> Void)?

    var isRunning: Bool {
        engine?.isRunning == true
    }

    func start(onChunk: @escaping @Sendable (Data) -> Void) throws {
        guard engine == nil else {
            throw RealtimeAudioCaptureError.alreadyRunning
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw RealtimeAudioCaptureError.inputUnavailable
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(
            from: inputFormat,
            to: outputFormat
        ) else {
            throw RealtimeAudioCaptureError.unsupportedFormat
        }

        self.engine = engine
        self.converter = converter
        self.outputFormat = outputFormat
        self.onChunk = onChunk

        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.convertAndDeliver(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            self.engine = nil
            self.converter = nil
            self.outputFormat = nil
            self.onChunk = nil
            throw error
        }
    }

    func stop() {
        guard let engine else {
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
        converter = nil
        outputFormat = nil
        onChunk = nil
    }

    private func convertAndDeliver(_ inputBuffer: AVAudioPCMBuffer) {
        guard
            let converter,
            let outputFormat,
            let onChunk
        else {
            return
        }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * ratio)
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            return
        }

        var sourceBuffer: AVAudioPCMBuffer? = inputBuffer
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            if let buffer = sourceBuffer {
                sourceBuffer = nil
                inputStatus.pointee = .haveData
                return buffer
            }

            inputStatus.pointee = .noDataNow
            return nil
        }

        guard
            status != .error,
            conversionError == nil,
            outputBuffer.frameLength > 0,
            let samples = outputBuffer.int16ChannelData?[0]
        else {
            return
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        onChunk(Data(bytes: samples, count: byteCount))
    }
}
