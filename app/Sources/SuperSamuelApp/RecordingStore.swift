import Foundation

// ponytail: a session still holds an array of chunks. New recordings always
// write exactly one, but pending recordings already on disk may have several,
// and looping over N covers both without a migration.
struct RecordingChunk: Codable, Identifiable {
    let id: UUID
    let filename: String
    let createdAt: Date
    var duration: TimeInterval?
    var sizeBytes: Int64?
}

struct RecordingSession: Codable, Identifiable {
    enum Status: String, Codable {
        case recording
        case ready
        case processing
        case failed
        case completed
    }

    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var status: Status
    var chunks: [RecordingChunk]
    // Optional so manifests created before transcription models were
    // configurable continue to decode and use the original default.
    var transcriptionModel: String?
    // Optional so older manifests continue to decode. Keeping the context on
    // the session also makes retries reproduce the original request.
    var transcriptionContext: String?
    var screenshotFilename: String?
    var lastError: String?
    var completedTranscriptID: UUID?
    var inputDevice: AudioInputDeviceInfo?

    var resolvedTranscriptionModel: String {
        let model = transcriptionModel?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? OpenRouterService.transcriptionModel : model
    }

    var resolvedTranscriptionContext: String? {
        let context = transcriptionContext?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return context.isEmpty ? nil : context
    }
}

struct PendingRecordingSummary: Identifiable {
    let id: UUID
    let createdAt: Date
    let chunkCount: Int
    let sizeBytes: Int64
    let estimatedDuration: TimeInterval
    let lastError: String?
    let inputDeviceName: String?
}

enum RecordingStoreError: LocalizedError {
    case sessionNotFound
    case noAudio

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "The saved recording could not be found."
        case .noAudio:
            return "The saved recording does not contain usable audio."
        }
    }
}

@MainActor
final class RecordingStore {
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let recordingsDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = rootDirectory ?? applicationSupport
            .appendingPathComponent("SuperSamuel", isDirectory: true)

        self.rootDirectory = root
        self.recordingsDirectory = root
            .appendingPathComponent("Recordings", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func createSession(
        transcriptionModel: String = OpenRouterService.transcriptionModel,
        transcriptionContext: String = ""
    ) throws -> RecordingSession {
        try ensureDirectories()

        let now = Date()
        let session = RecordingSession(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            status: .recording,
            chunks: [],
            transcriptionModel: transcriptionModel,
            transcriptionContext: normalizedTranscriptionContext(
                transcriptionContext
            ),
            screenshotFilename: nil,
            lastError: nil,
            completedTranscriptID: nil,
            inputDevice: nil
        )

        try fileManager.createDirectory(
            at: directory(for: session.id),
            withIntermediateDirectories: true
        )
        try save(session)
        return session
    }

    func beginChunk(in sessionID: UUID) throws -> URL {
        var session = try load(sessionID)
        let chunk = RecordingChunk(
            id: UUID(),
            filename: String(format: "chunk-%04d.m4a", session.chunks.count + 1),
            createdAt: Date(),
            duration: nil,
            sizeBytes: nil
        )

        session.status = .recording
        session.updatedAt = Date()
        session.chunks.append(chunk)
        try save(session)
        return directory(for: sessionID).appendingPathComponent(chunk.filename)
    }

    func finishCurrentChunk(
        in sessionID: UUID,
        duration: TimeInterval
    ) throws {
        var session = try load(sessionID)
        guard let index = session.chunks.indices.last else {
            throw RecordingStoreError.noAudio
        }

        let fileURL = directory(for: sessionID)
            .appendingPathComponent(session.chunks[index].filename)
        session.chunks[index].duration = max(0, duration)
        session.chunks[index].sizeBytes = fileSize(at: fileURL)
        session.updatedAt = Date()
        try save(session)
    }

    func setInputDevice(
        _ device: AudioInputDeviceInfo,
        for sessionID: UUID
    ) throws {
        try update(sessionID) { session in
            session.inputDevice = device
        }
    }

    func prepareForProcessing(
        sessionID: UUID,
        transcriptionModel: String = OpenRouterService.transcriptionModel,
        transcriptionContext: String = "",
        screenshotSourceURL: URL?
    ) throws {
        var session = try load(sessionID)
        session.transcriptionModel = transcriptionModel
        session.transcriptionContext = normalizedTranscriptionContext(
            transcriptionContext
        )
        session.status = .ready
        session.updatedAt = Date()
        session.lastError = nil

        if let screenshotSourceURL {
            let filename = "screenshot.jpg"
            let destination = directory(for: sessionID)
                .appendingPathComponent(filename)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: screenshotSourceURL, to: destination)
            session.screenshotFilename = filename
        }

        try save(session)
    }

    func markProcessing(_ sessionID: UUID) throws {
        try update(sessionID) { session in
            session.status = .processing
            session.lastError = nil
        }
    }

    func markFailed(_ sessionID: UUID, message: String) throws {
        try update(sessionID) { session in
            session.status = .failed
            session.lastError = message
        }
    }

    func markReady(_ sessionID: UUID, message: String? = nil) throws {
        try update(sessionID) { session in
            session.status = .ready
            session.lastError = message
        }
    }

    func markCompleted(_ sessionID: UUID, transcriptID: UUID) throws {
        try update(sessionID) { session in
            session.status = .completed
            session.completedTranscriptID = transcriptID
            session.lastError = nil
        }
    }

    func load(_ sessionID: UUID) throws -> RecordingSession {
        let url = manifestURL(for: sessionID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RecordingStoreError.sessionNotFound
        }
        return try decoder.decode(
            RecordingSession.self,
            from: Data(contentsOf: url)
        )
    }

    func pendingSessions() throws -> [RecordingSession] {
        try ensureDirectories()

        let directories = try fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        var sessions: [RecordingSession] = []
        for directory in directories {
            let isDirectory = try? directory.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory
            guard isDirectory == true else {
                continue
            }

            guard let id = UUID(uuidString: directory.lastPathComponent) else {
                continue
            }

            let session: RecordingSession
            do {
                session = try load(id)
            } catch {
                guard let recovered = try recoverManifest(in: directory, id: id) else {
                    continue
                }
                session = recovered
            }

            if session.status == .completed {
                try? deleteSession(session.id)
                continue
            }

            if session.lastError == "OpenRouter returned an invalid response." {
                var migratedSession = session
                migratedSession.lastError =
                    "No speech was detected in this legacy recording. It was kept so you can retry it or move it to Trash."
                migratedSession.updatedAt = Date()
                try save(migratedSession)
                sessions.append(migratedSession)
            } else {
                sessions.append(session)
            }
        }

        return sessions.sorted { $0.createdAt < $1.createdAt }
    }

    func recoverInterruptedSessions() throws {
        for session in try pendingSessions()
        where session.status == .recording || session.status == .processing {
            try markFailed(
                session.id,
                message: "Recovered after SuperSamuel closed before processing finished."
            )
        }
    }

    func summaries() throws -> [PendingRecordingSummary] {
        try pendingSessions().map(summary(for:))
    }

    func summary(for session: RecordingSession) -> PendingRecordingSummary {
        let totalSize = session.chunks.reduce(Int64(0)) { partial, chunk in
            partial + (chunk.sizeBytes ?? fileSize(at: audioURL(for: session.id, chunk: chunk)))
        }
        let duration = session.chunks.reduce(0) { partial, chunk in
            if let duration = chunk.duration {
                return partial + duration
            }

            let url = audioURL(for: session.id, chunk: chunk)
            let size = chunk.sizeBytes ?? fileSize(at: url)
            return partial + estimatedDuration(
                byteCount: size,
                fileExtension: url.pathExtension
            )
        }

        return PendingRecordingSummary(
            id: session.id,
            createdAt: session.createdAt,
            chunkCount: session.chunks.count,
            sizeBytes: totalSize,
            estimatedDuration: duration,
            lastError: session.lastError,
            inputDeviceName: session.inputDevice?.name
        )
    }

    func audioChunks(for session: RecordingSession) throws -> [(RecordingChunk, RecordedAudio)] {
        let chunks = session.chunks.compactMap { chunk -> (RecordingChunk, RecordedAudio)? in
            let url = audioURL(for: session.id, chunk: chunk)
            guard fileSize(at: url) > 0 else {
                return nil
            }

            let format = url.pathExtension.lowercased()
            return (
                chunk,
                RecordedAudio(
                    fileURL: url,
                    format: format,
                    mimeType: format == "wav" ? "audio/wav" : "audio/mp4"
                )
            )
        }

        guard !chunks.isEmpty else {
            throw RecordingStoreError.noAudio
        }
        return chunks
    }

    func screenshotURL(for session: RecordingSession) -> URL? {
        guard let filename = session.screenshotFilename else {
            return nil
        }

        let url = directory(for: session.id).appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func cachedTranscript(
        sessionID: UUID,
        chunkID: UUID,
        cleaned: Bool
    ) -> String? {
        let url = transcriptURL(
            sessionID: sessionID,
            chunkID: chunkID,
            cleaned: cleaned
        )
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveTranscript(
        _ text: String,
        sessionID: UUID,
        chunkID: UUID,
        cleaned: Bool
    ) throws {
        try text.write(
            to: transcriptURL(
                sessionID: sessionID,
                chunkID: chunkID,
                cleaned: cleaned
            ),
            atomically: true,
            encoding: .utf8
        )
    }

    func chunkHadNoSpeech(
        sessionID: UUID,
        chunkID: UUID
    ) -> Bool {
        fileManager.fileExists(
            atPath: noSpeechMarkerURL(
                sessionID: sessionID,
                chunkID: chunkID
            ).path
        )
    }

    func markChunkAsNoSpeech(
        sessionID: UUID,
        chunkID: UUID
    ) throws {
        try Data().write(
            to: noSpeechMarkerURL(
                sessionID: sessionID,
                chunkID: chunkID
            ),
            options: .atomic
        )
    }

    func finalTranscript(sessionID: UUID) -> String? {
        let url = directory(for: sessionID)
            .appendingPathComponent("final-transcript.txt")
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveFinalTranscript(_ text: String, sessionID: UUID) throws {
        try text.write(
            to: directory(for: sessionID)
                .appendingPathComponent("final-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    func deleteSession(_ sessionID: UUID) throws {
        let url = directory(for: sessionID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func trashSession(_ sessionID: UUID) throws {
        let url = directory(for: sessionID)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        var resultingURL: NSURL?
        try fileManager.trashItem(
            at: url,
            resultingItemURL: &resultingURL
        )
    }

    func directoryURL(for sessionID: UUID) -> URL {
        directory(for: sessionID)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: rootDirectory.path
        )
        try fileManager.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: recordingsDirectory.path
        )
    }

    private func update(
        _ sessionID: UUID,
        mutation: (inout RecordingSession) -> Void
    ) throws {
        var session = try load(sessionID)
        mutation(&session)
        session.updatedAt = Date()
        try save(session)
    }

    private func save(_ session: RecordingSession) throws {
        try ensureDirectories()
        try encoder.encode(session).write(
            to: manifestURL(for: session.id),
            options: .atomic
        )
    }

    private func recoverManifest(
        in directory: URL,
        id: UUID
    ) throws -> RecordingSession? {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        let audioFiles = files
            .filter {
                let fileExtension = $0.pathExtension.lowercased()
                return fileExtension == "m4a" || fileExtension == "wav"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !audioFiles.isEmpty else {
            return nil
        }

        let createdAt = (
            try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate
        ) ?? Date()
        let chunks = audioFiles.map { url in
            RecordingChunk(
                id: UUID(),
                filename: url.lastPathComponent,
                createdAt: createdAt,
                duration: estimatedDuration(
                    byteCount: fileSize(at: url),
                    fileExtension: url.pathExtension
                ),
                sizeBytes: fileSize(at: url)
            )
        }
        let session = RecordingSession(
            id: id,
            createdAt: createdAt,
            updatedAt: Date(),
            status: .failed,
            chunks: chunks,
            transcriptionModel: OpenRouterService.transcriptionModel,
            transcriptionContext: nil,
            screenshotFilename: nil,
            lastError: "Recovered audio whose metadata could not be read.",
            completedTranscriptID: nil,
            inputDevice: nil
        )
        try save(session)
        return session
    }

    private func normalizedTranscriptionContext(_ context: String) -> String? {
        let normalized = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func directory(for sessionID: UUID) -> URL {
        recordingsDirectory
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func manifestURL(for sessionID: UUID) -> URL {
        directory(for: sessionID).appendingPathComponent("manifest.json")
    }

    private func audioURL(for sessionID: UUID, chunk: RecordingChunk) -> URL {
        directory(for: sessionID).appendingPathComponent(chunk.filename)
    }

    private func transcriptURL(
        sessionID: UUID,
        chunkID: UUID,
        cleaned: Bool
    ) -> URL {
        let prefix = cleaned ? "cleaned" : "raw"
        return directory(for: sessionID)
            .appendingPathComponent("\(prefix)-\(chunkID.uuidString).txt")
    }

    private func noSpeechMarkerURL(
        sessionID: UUID,
        chunkID: UUID
    ) -> URL {
        directory(for: sessionID)
            .appendingPathComponent("no-speech-\(chunkID.uuidString).marker")
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func estimatedDuration(
        byteCount: Int64,
        fileExtension: String
    ) -> TimeInterval {
        let bytesPerSecond: Double =
            fileExtension.lowercased() == "wav" ? 32_000 : 4_000
        return Double(max(0, byteCount)) / bytesPerSecond
    }
}
