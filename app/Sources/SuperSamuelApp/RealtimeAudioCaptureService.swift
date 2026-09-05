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

/// The tap writes on the audio thread; health checks read on the main thread. Silent PCM
/// counts as arriving audio, and a gap remains recorded even after samples start arriving again.
final class RealtimeSampleMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSampleAt: TimeInterval
    private var interrupted = false
    private var expectedSampleTime: Int64?

    init(startedAt: TimeInterval) {
        lastSampleAt = startedAt
    }

    func receivedSamples(frameCount: Int, sampleTime: Int64? = nil, at now: TimeInterval) {
        guard frameCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if now - lastSampleAt >= 2 { interrupted = true }
        if let sampleTime {
            if let expectedSampleTime, sampleTime != expectedSampleTime { interrupted = true }
            expectedSampleTime = sampleTime + Int64(frameCount)
        }
        lastSampleAt = now
    }

    func conversionFailed() {
        lock.lock()
        interrupted = true
        lock.unlock()
    }

    func hasDiscontinuity(at now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted || now - lastSampleAt >= 2
    }
}

/// Owns conversion and delivery together so Stop can wait for an in-flight conversion and
/// synchronously deliver its samples before the controller detaches the live session.
final class RealtimeAudioDeliveryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var acceptingAudio = true

    func enqueue(_ makeData: () -> Data?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingAudio, let data = makeData(), !data.isEmpty else { return false }
        let needsDelivery = chunks.isEmpty
        chunks.append(data)
        return needsDelivery
    }

    func drain(finishing: Bool = false) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        if finishing { acceptingAudio = false }
        let result = chunks
        chunks.removeAll(keepingCapacity: false)
        return result
    }
}

/// A PCM sidecar for live transcription. Any restart makes its transcript incomplete;
/// the separate AAC recorder remains the source for the saved-audio fallback.
@MainActor
final class RealtimeAudioCaptureService {
    static let sampleRate: Double = 24_000

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var sampleMonitor: RealtimeSampleMonitor?
    private var onChunk: (@MainActor (Data) -> Void)?
    private var deliveryBuffer: RealtimeAudioDeliveryBuffer?
    private var retryAfter: TimeInterval = 0
    private(set) var hasDiscontinuity = false
    var onDiscontinuity: ((String) -> Void)?

    var isRunning: Bool {
        engine?.isRunning == true
    }

    func start(onChunk: @escaping @MainActor (Data) -> Void) throws {
        guard self.onChunk == nil else {
            throw RealtimeAudioCaptureError.alreadyRunning
        }
        hasDiscontinuity = false
        retryAfter = 0
        self.onChunk = onChunk
        do {
            try startEngine()
        } catch {
            self.onChunk = nil
            throw error
        }
    }

    /// Call while recording to detect an engine that stops or ceases delivering PCM.
    func checkHealth() {
        guard onChunk != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= retryAfter else { return }
        if !isRunning || sampleMonitor?.hasDiscontinuity(at: now) == true {
            rebuildCapturePath(message: "Live microphone audio was interrupted. The saved recording will be used when you stop.")
        }
    }

    func stop() {
        stopEngine()
        onChunk = nil
    }

    private func startEngine() throws {
        guard onChunk != nil else { return }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw RealtimeAudioCaptureError.inputUnavailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RealtimeAudioCaptureError.unsupportedFormat
        }
        let monitor = RealtimeSampleMonitor(startedAt: ProcessInfo.processInfo.systemUptime)
        let delivery = RealtimeAudioDeliveryBuffer()

        // The converter belongs to this tap. Replacing the engine never mutates a converter
        // that an in-flight callback from the old engine might still be using.
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, time in
            let needsDelivery = delivery.enqueue {
                guard let data = Self.convert(
                    buffer, using: converter, outputFormat: outputFormat, monitor: monitor
                ) else { return nil }
                monitor.receivedSamples(
                    frameCount: Int(buffer.frameLength),
                    sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                    at: ProcessInfo.processInfo.systemUptime
                )
                return data
            }
            guard needsDelivery else { return }
            Task { @MainActor [weak self] in
                guard let self, self.deliveryBuffer === delivery else { return }
                for data in delivery.drain() { self.onChunk?(data) }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            throw error
        }
        self.engine = engine
        sampleMonitor = monitor
        deliveryBuffer = delivery
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            monitor.conversionFailed()
            // Apple requires leaving the notification's internal queue before tearing down
            // an engine; synchronous destruction in the observer can deadlock.
            Task { @MainActor [weak self, weak engine] in
                guard let self, let engine, self.engine === engine, self.onChunk != nil else { return }
                self.rebuildCapturePath(message: "The microphone configuration changed. The saved recording will be used when you stop.")
            }
        }
    }

    private func rebuildCapturePath(message: String) {
        hasDiscontinuity = true
        onDiscontinuity?(message)
        stopEngine()
        do {
            try startEngine()
            retryAfter = 0
        } catch {
            retryAfter = ProcessInfo.processInfo.systemUptime + 2
            onDiscontinuity?("Live microphone capture is unavailable. Recording locally while reconnecting: \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        let wasRunning = isRunning
        let monitor = sampleMonitor
        let finalChunks = deliveryBuffer?.drain(finishing: true) ?? []
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        // Closing the delivery queue waits for the final conversion. Inspect its health
        // afterward so a conversion failure racing with Stop cannot look complete.
        if onChunk != nil, !wasRunning || monitor?.hasDiscontinuity(
            at: ProcessInfo.processInfo.systemUptime
        ) == true {
            hasDiscontinuity = true
        }
        engine = nil
        sampleMonitor = nil
        deliveryBuffer = nil
        for data in finalChunks { onChunk?(data) }
    }

    nonisolated private static func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        monitor: RealtimeSampleMonitor
    ) -> Data? {
        guard inputBuffer.frameLength > 0, inputBuffer.format.sampleRate > 0 else { return nil }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            monitor.conversionFailed()
            return nil
        }

        var sourceBuffer: AVAudioPCMBuffer? = inputBuffer
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if let buffer = sourceBuffer {
                sourceBuffer = nil
                inputStatus.pointee = .haveData
                return buffer
            }
            inputStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error, conversionError == nil else {
            monitor.conversionFailed()
            return nil
        }
        guard outputBuffer.frameLength > 0, let samples = outputBuffer.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
    }
}
