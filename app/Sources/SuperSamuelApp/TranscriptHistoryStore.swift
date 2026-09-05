import Foundation

struct TranscriptHistoryItem: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let text: String
    var savedCaptureContinuous: Bool?
}

enum TranscriptWorkflow: String, Codable, Equatable {
    case transcriptionOnly = "transcription-only"
    case transcriptionThenCleanup = "transcription-then-cleanup"
    // Retained so metadata archived by older app versions still decodes.
    case whisperOnly = "whisper-only"
    case whisperThenTextLLM = "whisper-then-text-llm"
    case audioLLMOnly = "audio-llm-only"
}

struct TranscriptWorkflowMetadata: Codable {
    let workflow: TranscriptWorkflow
    let transcriptionModel: String?
    let transcriptionContext: String?
    let usedScreenshotContext: Bool
    var vocabulary: [String]?
    var liveTranscriptionModel: String?
    var liveTranscriptionDelay: String?
    var transcriptSource: String?
    var savedAudioTranscriptionModel: String?
    var cleanup: TranscriptCleanupConfiguration?
}

struct TranscriptAudioMetadata: Codable {
    let chunkID: UUID
    let filename: String
    let createdAt: Date
    let durationSeconds: TimeInterval?
    let sizeBytes: Int64?
    let format: String
    let mimeType: String
    var inputDevice: AudioInputDeviceInfo?
}

struct TranscriptHistoryMetadata: Codable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let completedAt: Date
    let text: String
    let transcriptFilename: String
    let workflow: TranscriptWorkflowMetadata
    let audio: [TranscriptAudioMetadata]
    let inputDevice: AudioInputDeviceInfo?
    let screenshotFilename: String?
    let appVersion: String?
    let appBuild: String?
    let operatingSystem: String
    var liveCaptureContinuous: Bool?
    var savedCaptureContinuous: Bool?
}

@MainActor
final class TranscriptHistoryStore {
    private let files: TranscriptHistoryFiles
    private let background: TranscriptHistoryBackground

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        files = TranscriptHistoryFiles(fileManager: fileManager, rootDirectory: rootDirectory)
        background = TranscriptHistoryBackground(fileManager: fileManager, rootDirectory: rootDirectory)
    }

    func archive(
        session: RecordingSession,
        recordingDirectory: URL,
        text: String,
        completedAt: Date = Date()
    ) async throws -> TranscriptHistoryItem {
        try await background.archive(
            session: session, recordingDirectory: recordingDirectory,
            text: text, completedAt: completedAt
        )
    }

    func recent(limit: Int = 30) async throws -> [TranscriptHistoryItem] {
        try await background.recent(limit: limit)
    }

    func clear() async throws { try await background.clear() }

    func save(recordingID: UUID, createdAt: Date, text: String) async throws -> TranscriptHistoryItem {
        try await background.save(recordingID: recordingID, createdAt: createdAt, text: text)
    }

    func item(id: UUID) throws -> TranscriptHistoryItem? { try files.item(id: id) }
    func metadata(id: UUID) throws -> TranscriptHistoryMetadata? { try files.metadata(id: id) }
    func artifactURL(for id: UUID) -> URL? { files.artifactURL(for: id) }
}

// The actor serializes archive publication, deletion and listing on a background
// executor. Directory timestamps catch external additions and removals without
// decoding the archive again on every menu opening.
private actor TranscriptHistoryBackground {
    private let files: TranscriptHistoryFiles
    private var cachedItems: [TranscriptHistoryItem]?
    private var cachedDirectoryModification: Date?

    init(fileManager: FileManager, rootDirectory: URL?) {
        files = TranscriptHistoryFiles(fileManager: fileManager, rootDirectory: rootDirectory)
    }

    func archive(
        session: RecordingSession, recordingDirectory: URL,
        text: String, completedAt: Date
    ) throws -> TranscriptHistoryItem {
        let item = try files.archive(
            session: session, recordingDirectory: recordingDirectory,
            text: text, completedAt: completedAt
        )
        cachedItems = nil
        return item
    }

    func recent(limit: Int) throws -> [TranscriptHistoryItem] {
        if cachedItems == nil || cachedDirectoryModification != files.directoryModificationDate() {
            cachedItems = try files.recent(limit: .max)
            cachedDirectoryModification = files.directoryModificationDate()
        }
        return Array((cachedItems ?? []).prefix(max(0, limit)))
    }

    func clear() throws {
        try files.clear()
        cachedItems = []
        cachedDirectoryModification = files.directoryModificationDate()
    }

    func save(recordingID: UUID, createdAt: Date, text: String) throws -> TranscriptHistoryItem {
        let item = try files.save(recordingID: recordingID, createdAt: createdAt, text: text)
        cachedItems = nil
        return item
    }
}

private final class TranscriptHistoryFiles {
    private let fileManager: FileManager
    private let historyDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    func directoryModificationDate() -> Date? {
        (try? fileManager.attributesOfItem(atPath: historyDirectory.path)[.modificationDate]) as? Date
    }

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = rootDirectory ?? applicationSupport
            .appendingPathComponent("SuperSamuel", isDirectory: true)
        self.historyDirectory = root
            .appendingPathComponent("Transcript History", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Archives the complete durable recording directory alongside a convenient
    /// transcript and a self-contained metadata file. The copy is assembled in
    /// a hidden temporary directory and moved into place only when complete.
    func archive(
        session: RecordingSession,
        recordingDirectory: URL,
        text: String,
        completedAt: Date = Date()
    ) throws -> TranscriptHistoryItem {
        try Task.checkCancellation()
        try ensureDirectory()

        let destination = directoryURL(for: session.id)
        let staging = historyDirectory.appendingPathComponent(
            ".\(session.id.uuidString)-archiving",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.copyItem(at: recordingDirectory, to: staging)
        try text.write(
            to: staging.appendingPathComponent("transcript.txt"),
            atomically: true,
            encoding: .utf8
        )

        let metadata = makeMetadata(
            session: session,
            text: text,
            completedAt: completedAt
        )
        var archivedSession = session
        archivedSession.updatedAt = completedAt
        archivedSession.status = .completed
        archivedSession.lastError = nil
        archivedSession.completedTranscriptID = session.id
        try encoder.encode(archivedSession).write(
            to: staging.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try encoder.encode(metadata).write(
            to: staging.appendingPathComponent("metadata.json"),
            options: .atomic
        )

        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: destination.path
        )

        return TranscriptHistoryItem(
            id: metadata.id,
            createdAt: metadata.createdAt,
            text: metadata.text,
            savedCaptureContinuous: metadata.savedCaptureContinuous
        )
    }

    /// Keeps compatibility for callers and installs that only have the original
    /// flat transcript JSON format.
    func save(
        recordingID: UUID,
        createdAt: Date,
        text: String
    ) throws -> TranscriptHistoryItem {
        try ensureDirectory()

        let item = TranscriptHistoryItem(
            id: recordingID,
            createdAt: createdAt,
            text: text
        )
        try encoder.encode(item).write(
            to: legacyFileURL(for: recordingID),
            options: .atomic
        )
        return item
    }

    func recent(limit: Int = 30) throws -> [TranscriptHistoryItem] {
        try ensureDirectory()

        let urls = try fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let items = urls.compactMap { url -> TranscriptHistoryItem? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                return try? decodeArchivedItem(at: url)
            }
            guard url.pathExtension == "json" else {
                return nil
            }
            return try? decoder.decode(
                TranscriptHistoryItem.self,
                from: Data(contentsOf: url)
            )
        }

        return items
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    func item(id: UUID) throws -> TranscriptHistoryItem? {
        let directory = directoryURL(for: id)
        if fileManager.fileExists(atPath: directory.path) {
            return try decodeArchivedItem(at: directory)
        }

        let url = legacyFileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try decoder.decode(
            TranscriptHistoryItem.self,
            from: Data(contentsOf: url)
        )
    }

    func metadata(id: UUID) throws -> TranscriptHistoryMetadata? {
        let url = directoryURL(for: id).appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try decoder.decode(
            TranscriptHistoryMetadata.self,
            from: Data(contentsOf: url)
        )
    }

    func artifactURL(for id: UUID) -> URL? {
        let directory = directoryURL(for: id)
        if fileManager.fileExists(atPath: directory.path) {
            return directory
        }

        let legacyFile = legacyFileURL(for: id)
        return fileManager.fileExists(atPath: legacyFile.path)
            ? legacyFile
            : nil
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: historyDirectory.path) else {
            return
        }

        let files = try fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files {
            try fileManager.removeItem(at: file)
        }
    }

    private func decodeArchivedItem(at directory: URL) throws -> TranscriptHistoryItem {
        let metadata = try decoder.decode(
            TranscriptHistoryMetadata.self,
            from: Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        )
        return TranscriptHistoryItem(
            id: metadata.id,
            createdAt: metadata.createdAt,
            text: metadata.text,
            savedCaptureContinuous: metadata.savedCaptureContinuous
        )
    }

    private func makeMetadata(
        session: RecordingSession,
        text: String,
        completedAt: Date
    ) -> TranscriptHistoryMetadata {
        let audio = session.chunks.map { chunk in
            let fileExtension = URL(fileURLWithPath: chunk.filename)
                .pathExtension.lowercased()
            return TranscriptAudioMetadata(
                chunkID: chunk.id,
                filename: chunk.filename,
                createdAt: chunk.createdAt,
                durationSeconds: chunk.duration,
                sizeBytes: chunk.sizeBytes,
                format: fileExtension,
                mimeType: fileExtension == "wav" ? "audio/wav" : "audio/mp4",
                inputDevice: chunk.inputDevice
            )
        }
        let info = Bundle.main.infoDictionary

        return TranscriptHistoryMetadata(
            schemaVersion: 1,
            id: session.id,
            createdAt: session.createdAt,
            completedAt: completedAt,
            text: text,
            transcriptFilename: "transcript.txt",
            workflow: TranscriptWorkflowMetadata(
                workflow: session.cleanup == nil ? .transcriptionOnly : .transcriptionThenCleanup,
                transcriptionModel: session.transcriptSource == "live"
                    ? session.liveTranscriptionModel : session.resolvedTranscriptionModel,
                transcriptionContext: session.resolvedTranscriptionContext,
                usedScreenshotContext: session.screenshotFilename != nil,
                vocabulary: session.vocabulary,
                liveTranscriptionModel: session.liveTranscriptionModel,
                liveTranscriptionDelay: session.liveTranscriptionDelay,
                transcriptSource: session.transcriptSource,
                savedAudioTranscriptionModel: session.resolvedTranscriptionModel,
                cleanup: session.cleanup
            ),
            audio: audio,
            inputDevice: session.inputDevice,
            screenshotFilename: session.screenshotFilename,
            appVersion: info?["CFBundleShortVersionString"] as? String,
            appBuild: info?["CFBundleVersion"] as? String,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            liveCaptureContinuous: session.liveCaptureContinuous,
            savedCaptureContinuous: session.savedCaptureContinuous
        )
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: historyDirectory.path
        )
    }

    private func directoryURL(for id: UUID) -> URL {
        historyDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func legacyFileURL(for id: UUID) -> URL {
        historyDirectory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
    }
}
