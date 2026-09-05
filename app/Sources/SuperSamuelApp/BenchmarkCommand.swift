import CryptoKit
import Foundation

enum BenchmarkCommand {
    static let usage = """
    Usage:
      SuperSamuel benchmark --input <corpus-directory> [--output <directory>]
                            [--strategies <comma-separated-strategies>]
                            [--models <comma-separated-model-ids>]

    Strategies:
      whisper-only
      whisper-gemini-text
      gemini-audio
      whisper-gemini-audio

    Corpus convention:
      clip.m4a                  Audio to evaluate
      clip.reference.txt        Optional human reference transcript
      clip.instruction.txt      Optional rewrite instruction for this clip

    OPENROUTER_API_KEY is used when set. Otherwise the command reads the same
    credential storage as the app (Keychain or opted-in local files). Results are written to a new run directory.
    Non-Whisper strategies run once for every model supplied to --models.
    """

    static func run(arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }

        do {
            let options = try BenchmarkOptions(arguments: arguments)
            let apiKey = try loadAPIKey()
            let runner = DictationBenchmarkRunner(
                engine: DictationEngine(transport: OpenRouterService())
            )
            let output = try await runner.run(options: options, apiKey: apiKey)
            print("\nBenchmark complete")
            print("JSONL: \(output.jsonlURL.path)")
            print("Report: \(output.reportURL.path)")
            return 0
        } catch {
            fputs("Benchmark failed: \(error.localizedDescription)\n\n", stderr)
            fputs("\(usage)\n", stderr)
            return 1
        }
    }

    private static func loadAPIKey() throws -> String {
        let environmentKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !environmentKey.isEmpty {
            return environmentKey
        }

        let savedKey = CredentialStore().readAPIKey(
            useLocalStorage: UserDefaults.standard.bool(forKey: "usesLocalCredentials")
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !savedKey.isEmpty else {
            throw BenchmarkError.missingAPIKey
        }
        return savedKey
    }
}

private struct BenchmarkOptions {
    let inputDirectory: URL
    let outputDirectory: URL
    let strategies: [DictationStrategy]
    let models: [String]

    init(arguments: [String]) throws {
        var inputPath: String?
        var outputPath: String?
        var strategies = DictationStrategy.allCases
        var models = [OpenRouterService.geminiDictationModel]
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--input":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError.missingValue("--input")
                }
                inputPath = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError.missingValue("--output")
                }
                outputPath = arguments[index]
            case "--strategies":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError.missingValue("--strategies")
                }
                strategies = try Self.parseStrategies(arguments[index])
            case "--models":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError.missingValue("--models")
                }
                models = try Self.parseModels(arguments[index])
            default:
                throw BenchmarkError.unknownArgument(argument)
            }
            index += 1
        }

        guard let inputPath else {
            throw BenchmarkError.missingInput
        }

        let fileManager = FileManager.default
        inputDirectory = URL(
            fileURLWithPath: inputPath,
            relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath)
        ).standardizedFileURL

        if let outputPath {
            outputDirectory = URL(
                fileURLWithPath: outputPath,
                relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath)
            ).standardizedFileURL
        } else {
            outputDirectory = inputDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("results", isDirectory: true)
        }
        self.strategies = strategies
        self.models = models
    }

    private static func parseStrategies(_ value: String) throws -> [DictationStrategy] {
        let requested = value.split(separator: ",").map(String.init)
        guard !requested.isEmpty else {
            throw BenchmarkError.noStrategies
        }

        var result: [DictationStrategy] = []
        for name in requested {
            guard let strategy = DictationStrategy(rawValue: name) else {
                throw BenchmarkError.unknownStrategy(name)
            }
            if !result.contains(strategy) {
                result.append(strategy)
            }
        }
        return result
    }

    private static func parseModels(_ value: String) throws -> [String] {
        let requested = value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !requested.isEmpty else {
            throw BenchmarkError.noModels
        }

        var result: [String] = []
        for model in requested where !result.contains(model) {
            result.append(model)
        }
        return result
    }
}

private struct BenchmarkRunOutput {
    let jsonlURL: URL
    let reportURL: URL
}

private struct BenchmarkRecord: Codable {
    let runID: String
    let recordedAt: String
    let clip: String
    let audioSHA256: String
    let reference: String?
    let rewriteInstruction: String
    let strategy: DictationStrategy
    let dictationModel: String?
    let result: String?
    let error: String?
    let wordErrorRate: Double?
    let totalDurationSeconds: Double?
    let calls: [DictationCallMetrics]
}

private struct DictationBenchmarkRunner {
    private static let audioFormats: [String: String] = [
        "aac": "audio/aac",
        "aif": "audio/aiff",
        "aiff": "audio/aiff",
        "flac": "audio/flac",
        "m4a": "audio/mp4",
        "mp3": "audio/mpeg",
        "ogg": "audio/ogg",
        "wav": "audio/wav"
    ]

    let engine: DictationEngine
    private let fileManager = FileManager.default

    func run(options: BenchmarkOptions, apiKey: String) async throws -> BenchmarkRunOutput {
        let audioFiles = try loadAudioFiles(from: options.inputDirectory)
        guard !audioFiles.isEmpty else {
            throw BenchmarkError.emptyCorpus(options.inputDirectory.path)
        }

        let runID = UUID().uuidString.lowercased()
        let recordedAt = ISO8601DateFormatter().string(from: Date())
        let runDirectory = options.outputDirectory.appendingPathComponent(
            "run-\(fileSafeTimestamp())-\(runID.prefix(8))",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )

        var records: [BenchmarkRecord] = []
        for (clipIndex, audioURL) in audioFiles.enumerated() {
            let clipName = audioURL.lastPathComponent
            let audioSHA256 = try sha256(of: audioURL)
            let reference = try readSidecar(audioURL: audioURL, suffix: "reference")
            let instruction = try readSidecar(audioURL: audioURL, suffix: "instruction")
                ?? OpenRouterService.defaultCleanupInstruction
            let audio = try recordedAudio(from: audioURL)
            let needsWhisper = options.strategies.contains {
                $0 != .geminiAudio
            }

            print("[\(clipIndex + 1)/\(audioFiles.count)] \(clipName)")

            let draftOutcome: Result<DictationDraft, Error>? = if needsWhisper {
                await Result {
                    try await engine.makeWhisperDraft(apiKey: apiKey, audio: audio)
                }
            } else {
                nil
            }

            for strategy in options.strategies {
                let models: [String?] = strategy == .whisperOnly
                    ? [nil]
                    : options.models.map(Optional.some)

                for model in models {
                    let modelLabel = model.map { " [\($0)]" } ?? ""
                    print("  \(strategy.displayName)\(modelLabel)…", terminator: "")
                    fflush(stdout)

                    if strategy != .geminiAudio,
                       case .failure(let error) = draftOutcome
                    {
                        let record = failureRecord(
                            runID: runID,
                            recordedAt: recordedAt,
                            clip: clipName,
                            audioSHA256: audioSHA256,
                            reference: reference,
                            rewriteInstruction: instruction,
                            strategy: strategy,
                            dictationModel: model,
                            error: error
                        )
                        records.append(record)
                        print(" failed: \(error.localizedDescription)")
                        continue
                    }

                    let draft = try? draftOutcome?.get()
                    do {
                        let result = try await engine.process(
                            apiKey: apiKey,
                            input: DictationInput(
                                audio: audio,
                                strategy: strategy,
                                dictationModel: model ?? OpenRouterService.geminiDictationModel,
                                rewriteInstruction: instruction,
                                whisperDraft: draft
                            )
                        )
                        let record = successRecord(
                            runID: runID,
                            recordedAt: recordedAt,
                            clip: clipName,
                            audioSHA256: audioSHA256,
                            reference: reference,
                            rewriteInstruction: instruction,
                            dictationModel: model,
                            result: result
                        )
                        records.append(record)
                        print(String(format: " %.2fs", result.totalDurationSeconds))
                    } catch {
                        records.append(
                            failureRecord(
                                runID: runID,
                                recordedAt: recordedAt,
                                clip: clipName,
                                audioSHA256: audioSHA256,
                                reference: reference,
                                rewriteInstruction: instruction,
                                strategy: strategy,
                                dictationModel: model,
                                error: error
                            )
                        )
                        print(" failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        let jsonlURL = runDirectory.appendingPathComponent("results.jsonl")
        let reportURL = runDirectory.appendingPathComponent("report.md")
        try writeJSONL(records, to: jsonlURL)
        try report(records: records, runID: runID, recordedAt: recordedAt)
            .write(to: reportURL, atomically: true, encoding: .utf8)
        return BenchmarkRunOutput(jsonlURL: jsonlURL, reportURL: reportURL)
    }

    private func loadAudioFiles(from directory: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BenchmarkError.invalidCorpus(directory.path)
        }

        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { Self.audioFormats[$0.pathExtension.lowercased()] != nil }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func recordedAudio(from url: URL) throws -> RecordedAudio {
        let format = url.pathExtension.lowercased()
        guard let mimeType = Self.audioFormats[format] else {
            throw BenchmarkError.unsupportedAudio(url.lastPathComponent)
        }
        return RecordedAudio(fileURL: url, format: format, mimeType: mimeType)
    }

    private func readSidecar(audioURL: URL, suffix: String) throws -> String? {
        let sidecar = audioURL.deletingPathExtension()
            .appendingPathExtension(suffix)
            .appendingPathExtension("txt")
        guard fileManager.fileExists(atPath: sidecar.path) else {
            return nil
        }
        let value = try String(contentsOf: sidecar, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func successRecord(
        runID: String,
        recordedAt: String,
        clip: String,
        audioSHA256: String,
        reference: String?,
        rewriteInstruction: String,
        dictationModel: String?,
        result: DictationResult
    ) -> BenchmarkRecord {
        BenchmarkRecord(
            runID: runID,
            recordedAt: recordedAt,
            clip: clip,
            audioSHA256: audioSHA256,
            reference: reference,
            rewriteInstruction: rewriteInstruction,
            strategy: result.strategy,
            dictationModel: dictationModel,
            result: result.text,
            error: nil,
            wordErrorRate: reference.map { wordErrorRate(reference: $0, hypothesis: result.text) },
            totalDurationSeconds: result.totalDurationSeconds,
            calls: result.calls
        )
    }

    private func failureRecord(
        runID: String,
        recordedAt: String,
        clip: String,
        audioSHA256: String,
        reference: String?,
        rewriteInstruction: String,
        strategy: DictationStrategy,
        dictationModel: String?,
        error: Error
    ) -> BenchmarkRecord {
        BenchmarkRecord(
            runID: runID,
            recordedAt: recordedAt,
            clip: clip,
            audioSHA256: audioSHA256,
            reference: reference,
            rewriteInstruction: rewriteInstruction,
            strategy: strategy,
            dictationModel: dictationModel,
            result: nil,
            error: error.localizedDescription,
            wordErrorRate: nil,
            totalDurationSeconds: nil,
            calls: []
        )
    }

    private func writeJSONL(_ records: [BenchmarkRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func report(records: [BenchmarkRecord], runID: String, recordedAt: String) -> String {
        var lines = [
            "# Dictation benchmark",
            "",
            "- Run: `\(runID)`",
            "- Recorded: \(recordedAt)",
            "- Whisper draft model: `\(DictationEngine.benchmarkTranscriptionModel)`",
            "- Audio-model routing: highest advertised throughput (`provider.sort = throughput`)",
            "- Gemini 3 reasoning: minimal and excluded; Gemini 2.5 reasoning: disabled",
            "",
            "WER is shown only when a `.reference.txt` sidecar exists. For cleaned",
            "dictation, review meaning and formatting alongside WER because intentional",
            "filler removal can increase literal word distance."
        ]

        for (index, record) in records.enumerated() {
            let seconds = record.totalDurationSeconds.map { String(format: "%.2fs", $0) } ?? "—"
            let wer = record.wordErrorRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
            let geminiCall = record.calls.first { $0.stage == .gemini }
            let provider = (geminiCall ?? record.calls.first)?.provider ?? "—"
            let tokenRate: String
            if let tokens = geminiCall?.usage?.completionTokens,
               let duration = geminiCall?.durationSeconds,
               duration > 0
            {
                tokenRate = String(format: "%.1f", Double(tokens) / duration)
            } else {
                tokenRate = "—"
            }
            let value = record.result ?? "ERROR: \(record.error ?? "Unknown error")"
            lines.append(contentsOf: [
                "",
                "## \(index + 1). \(record.strategy.displayName)",
                "",
                "- Clip: `\(record.clip)`",
                "- Model: `\(record.dictationModel ?? DictationEngine.benchmarkTranscriptionModel)`",
                "- Total time: **\(seconds)**",
                "- WER: \(wer)",
                "- Provider: \(provider)",
                "- Observed completion tokens/second: \(tokenRate)",
                "",
                "### Result",
                "",
                markdownQuote(value)
            ])
            for call in record.calls {
                lines.append("- \(call.stage.rawValue): requested `\(call.requestedModel)`, resolved `\(call.resolvedModel ?? "not reported")`")
            }
        }

        lines.append("")
        lines.append("Completion tok/s is completion tokens divided by the whole Gemini request duration; it includes time-to-first-token and network latency.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func markdownQuote(_ value: String) -> String {
        "> " + value.replacingOccurrences(of: "\n", with: "\n> ")
    }

    private func fileSafeTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let referenceWords = normalizedWords(reference)
        let hypothesisWords = normalizedWords(hypothesis)
        guard !referenceWords.isEmpty else {
            return hypothesisWords.isEmpty ? 0 : 1
        }

        var previous = Array(0...hypothesisWords.count)
        for (referenceIndex, referenceWord) in referenceWords.enumerated() {
            var current = [referenceIndex + 1]
            for (hypothesisIndex, hypothesisWord) in hypothesisWords.enumerated() {
                current.append(
                    min(
                        current[hypothesisIndex] + 1,
                        previous[hypothesisIndex + 1] + 1,
                        previous[hypothesisIndex] + (referenceWord == hypothesisWord ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return Double(previous[hypothesisWords.count]) / Double(referenceWords.count)
    }

    private func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

private enum BenchmarkError: LocalizedError {
    case missingAPIKey
    case missingInput
    case missingValue(String)
    case unknownArgument(String)
    case unknownStrategy(String)
    case noStrategies
    case noModels
    case invalidCorpus(String)
    case emptyCorpus(String)
    case unsupportedAudio(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Set OPENROUTER_API_KEY or save an OpenRouter key in SuperSamuel Settings."
        case .missingInput:
            return "--input is required."
        case .missingValue(let argument):
            return "\(argument) requires a value."
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .unknownStrategy(let strategy):
            return "Unknown strategy: \(strategy)"
        case .noStrategies:
            return "Select at least one strategy."
        case .noModels:
            return "Select at least one audio model."
        case .invalidCorpus(let path):
            return "The corpus directory does not exist: \(path)"
        case .emptyCorpus(let path):
            return "No supported audio files were found in: \(path)"
        case .unsupportedAudio(let filename):
            return "Unsupported audio format: \(filename)"
        }
    }
}
