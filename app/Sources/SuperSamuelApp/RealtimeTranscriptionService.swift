import Foundation

enum RealtimeTranscriptionError: LocalizedError {
    case missingAPIKey
    case connectionTimedOut
    case completionTimedOut
    case invalidEvent
    case noSpeechDetected
    case serverError(String)
    case socketClosed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenAI API key in Settings to use realtime transcription."
        case .connectionTimedOut:
            return "The realtime transcription connection timed out."
        case .completionTimedOut:
            return "Realtime transcription did not finish in time."
        case .invalidEvent:
            return "OpenAI returned an invalid realtime transcription event."
        case .noSpeechDetected:
            return "Realtime transcription did not detect speech."
        case .serverError(let message):
            return "OpenAI realtime transcription failed: \(message)"
        case .socketClosed:
            return "The realtime transcription connection closed unexpectedly."
        }
    }
}

struct RealtimeTranscriptAssembler {
    private(set) var itemOrder: [String] = []
    private(set) var pendingItemIDs: Set<String> = []
    private var partialText: [String: String] = [:]
    private var finalText: [String: String] = [:]

    mutating func registerCommittedItem(_ itemID: String) {
        guard !itemID.isEmpty else {
            return
        }
        if !itemOrder.contains(itemID) {
            itemOrder.append(itemID)
        }
        pendingItemIDs.insert(itemID)
    }

    mutating func append(delta: String, itemID: String) {
        registerIfNeeded(itemID)
        partialText[itemID, default: ""] += delta
    }

    mutating func complete(transcript: String, itemID: String) {
        registerIfNeeded(itemID)
        finalText[itemID] = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        partialText[itemID] = nil
        pendingItemIDs.remove(itemID)
    }

    var combinedText: String {
        itemOrder
            .compactMap { itemID -> String? in
                let text = finalText[itemID] ?? partialText[itemID] ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func registerIfNeeded(_ itemID: String) {
        guard !itemOrder.contains(itemID) else {
            return
        }
        itemOrder.append(itemID)
    }
}

/// Streams PCM to a dedicated Realtime transcription session. GPT Transcribe
/// still works on committed turns; Server VAD creates those turn boundaries
/// during pauses and `finish()` commits any residual audio at hotkey release.
@MainActor
final class RealtimeTranscriptionService {
    static let transcriptionModel = "gpt-transcribe"
    static let silenceDurationMilliseconds = 500

    private enum State {
        case idle
        case connecting
        case ready
        case finishing
        case completed
        case cancelled
    }

    private static let maximumBufferedAudioBytes = 2 * 1_024 * 1_024

    private let urlSession: URLSession
    private let onSnapshot: (String) -> Void
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pendingSendTask: Task<Void, Never>?
    private var state: State = .idle
    private var terminalError: Error?
    private var latestContext = ""
    private var bufferedAudio: [Data] = []
    private var bufferedAudioByteCount = 0
    private var hasAudioSinceLastBoundary = false

    private var assembler = RealtimeTranscriptAssembler()
    private var activeSpeechItemID: String?
    private var serverCommitPendingItemIDs: Set<String> = []
    private var finishCommitEventID: String?
    private var finishExpectedItemID: String?
    private var finishCommitResolved = false

    init(
        urlSession: URLSession = .shared,
        onSnapshot: @escaping (String) -> Void
    ) {
        self.urlSession = urlSession
        self.onSnapshot = onSnapshot
    }

    var currentTranscript: String {
        assembler.combinedText
    }

    func start(apiKey: String, transcriptionContext: String) async throws {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw RealtimeTranscriptionError.missingAPIKey
        }
        guard state == .idle else {
            return
        }

        latestContext = transcriptionContext
        state = .connecting

        var request = URLRequest(url: Self.webSocketURL())
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let socketTask = urlSession.webSocketTask(with: request)
        self.socketTask = socketTask
        socketTask.resume()
        startReceiveLoop(socketTask)

        enqueueEvent(Self.sessionUpdateEvent(context: latestContext))
        try await waitForReady()
    }

    func appendAudio(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        guard terminalError == nil else {
            return
        }

        hasAudioSinceLastBoundary = true
        if state == .ready || state == .finishing {
            enqueueEvent([
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString()
            ])
            return
        }

        guard state == .idle || state == .connecting else {
            return
        }
        guard bufferedAudioByteCount + data.count <= Self.maximumBufferedAudioBytes else {
            markTerminalError(
                RealtimeTranscriptionError.serverError(
                    "The connection did not become ready before the local audio buffer filled."
                )
            )
            return
        }

        bufferedAudio.append(data)
        bufferedAudioByteCount += data.count
    }

    func updateTranscriptionContext(_ context: String) {
        latestContext = context
        guard state == .connecting || state == .ready else {
            return
        }
        enqueueEvent(Self.sessionUpdateEvent(context: context))
    }

    func finish() async throws -> String {
        try await waitForReady()
        guard terminalError == nil else {
            throw terminalError!
        }

        state = .finishing
        _ = await pendingSendTask?.result
        if let terminalError {
            throw terminalError
        }

        if hasAudioSinceLastBoundary {
            let eventID = "finish_\(UUID().uuidString)"
            finishCommitEventID = eventID
            finishExpectedItemID = activeSpeechItemID
            finishCommitResolved = false
            enqueueEvent([
                "event_id": eventID,
                "type": "input_audio_buffer.commit"
            ])
            _ = await pendingSendTask?.result
        } else {
            finishCommitResolved = true
        }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let terminalError {
                throw terminalError
            }

            if finishCommitResolved,
               serverCommitPendingItemIDs.isEmpty,
               assembler.pendingItemIDs.isEmpty
            {
                let transcript = assembler.combinedText
                guard !transcript.isEmpty else {
                    throw RealtimeTranscriptionError.noSpeechDetected
                }
                closeNormally()
                return transcript
            }

            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        throw RealtimeTranscriptionError.completionTimedOut
    }

    func cancel() {
        guard state != .completed, state != .cancelled else {
            return
        }
        state = .cancelled
        receiveTask?.cancel()
        receiveTask = nil
        pendingSendTask?.cancel()
        pendingSendTask = nil
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        bufferedAudio.removeAll()
        bufferedAudioByteCount = 0
    }

    static func sessionUpdateEvent(context: String) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": transcriptionModel
        ]
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            transcription["prompt"] = context
        }

        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(RealtimeAudioCaptureService.sampleRate)
                        ],
                        "transcription": transcription,
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": silenceDurationMilliseconds
                        ]
                    ]
                ]
            ]
        ]
    }

    static func webSocketURL() -> URL {
        var components = URLComponents(
            string: "wss://api.openai.com/v1/realtime"
        )!
        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription")
        ]
        return components.url!
    }

    private func waitForReady() async throws {
        if state == .ready || state == .finishing {
            return
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if state == .ready || state == .finishing {
                return
            }
            if let terminalError {
                throw terminalError
            }
            if state == .cancelled {
                throw CancellationError()
            }

            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let error = RealtimeTranscriptionError.connectionTimedOut
        markTerminalError(error)
        throw error
    }

    private func startReceiveLoop(_ socketTask: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socketTask.receive()
                    try self?.handle(message)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.markTerminalError(error)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            throw RealtimeTranscriptionError.invalidEvent
        }

        guard
            let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = event["type"] as? String
        else {
            throw RealtimeTranscriptionError.invalidEvent
        }

        switch type {
        case "session.updated":
            guard state == .connecting else {
                return
            }
            state = .ready
            flushBufferedAudio()

        case "input_audio_buffer.speech_started":
            activeSpeechItemID = event["item_id"] as? String

        case "input_audio_buffer.speech_stopped":
            if let itemID = event["item_id"] as? String {
                activeSpeechItemID = nil
                serverCommitPendingItemIDs.insert(itemID)
            }

        case "input_audio_buffer.committed":
            guard let itemID = event["item_id"] as? String else {
                throw RealtimeTranscriptionError.invalidEvent
            }
            hasAudioSinceLastBoundary = false
            activeSpeechItemID = nil
            serverCommitPendingItemIDs.remove(itemID)
            assembler.registerCommittedItem(itemID)
            if finishCommitEventID != nil,
               finishExpectedItemID == nil || finishExpectedItemID == itemID
            {
                finishCommitResolved = true
            }

        case "conversation.item.input_audio_transcription.delta":
            guard
                let itemID = event["item_id"] as? String,
                let delta = event["delta"] as? String
            else {
                throw RealtimeTranscriptionError.invalidEvent
            }
            assembler.append(delta: delta, itemID: itemID)
            publishSnapshot()

        case "conversation.item.input_audio_transcription.completed":
            guard
                let itemID = event["item_id"] as? String,
                let transcript = event["transcript"] as? String
            else {
                throw RealtimeTranscriptionError.invalidEvent
            }
            assembler.complete(transcript: transcript, itemID: itemID)
            publishSnapshot()

        case "conversation.item.input_audio_transcription.failed":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String
                ?? "A committed audio turn could not be transcribed."
            markTerminalError(RealtimeTranscriptionError.serverError(message))

        case "error":
            handleServerError(event)

        default:
            break
        }
    }

    private func handleServerError(_ event: [String: Any]) {
        let error = event["error"] as? [String: Any]
        let clientEventID = error?["event_id"] as? String
        let code = error?["code"] as? String ?? ""
        let message = error?["message"] as? String ?? "Unknown server error"

        if clientEventID == finishCommitEventID,
           code.localizedCaseInsensitiveContains("empty") ||
            message.localizedCaseInsensitiveContains("empty") ||
            message.localizedCaseInsensitiveContains("too small")
        {
            finishCommitResolved = true
            return
        }

        markTerminalError(RealtimeTranscriptionError.serverError(message))
    }

    private func flushBufferedAudio() {
        let chunks = bufferedAudio
        bufferedAudio.removeAll(keepingCapacity: false)
        bufferedAudioByteCount = 0
        for chunk in chunks {
            enqueueEvent([
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString()
            ])
        }
    }

    private func publishSnapshot() {
        let transcript = assembler.combinedText
        guard !transcript.isEmpty else {
            return
        }
        onSnapshot(transcript)
    }

    private func enqueueEvent(_ event: [String: Any]) {
        guard let socketTask, terminalError == nil else {
            return
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: event)
        } catch {
            markTerminalError(error)
            return
        }
        guard let json = String(data: data, encoding: .utf8) else {
            markTerminalError(RealtimeTranscriptionError.invalidEvent)
            return
        }

        let previousSend = pendingSendTask
        pendingSendTask = Task { @MainActor [weak self] in
            _ = await previousSend?.result
            guard !Task.isCancelled else {
                return
            }

            do {
                try await socketTask.send(.string(json))
            } catch {
                self?.markTerminalError(error)
            }
        }
    }

    private func markTerminalError(_ error: Error) {
        guard state != .completed, state != .cancelled else {
            return
        }
        if terminalError == nil {
            terminalError = error
        }
    }

    private func closeNormally() {
        state = .completed
        receiveTask?.cancel()
        receiveTask = nil
        pendingSendTask = nil
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
    }
}
