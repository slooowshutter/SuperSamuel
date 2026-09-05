import Foundation

struct TranscriptCleanupConfiguration: Codable, Equatable, Sendable {
    var model: String
    var instructions: String
}

enum TranscriptionDelay: String, CaseIterable, Codable {
    case minimal, low, medium, high, xhigh

    var title: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-high"
        }
    }
}

enum PersonalDictionary {
    static func normalizedEntries(_ entries: [String]) throws -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for (index, entry) in entries.enumerated() {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            let unsupported = CharacterSet(charactersIn: "<>")
                .union(.newlines).union(.controlCharacters)
            guard trimmed.rangeOfCharacter(from: unsupported) == nil
            else {
                throw ValidationError.invalidCharacters(line: index + 1)
            }
            guard !trimmed.isEmpty else { continue }
            let identity = trimmed.precomposedStringWithCanonicalMapping.lowercased()
            if seen.insert(identity).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    enum ValidationError: LocalizedError {
        case invalidCharacters(line: Int)

        var errorDescription: String? {
            switch self {
            case .invalidCharacters(let line):
                return "Line \(line) contains an unsupported character. Use one word or phrase per line, without <, >, tabs, or control characters."
            }
        }
    }
}

enum RealtimeTranscriptionAvailability: Equatable {
    case disabled
    case missingOpenAIAPIKey
    case available
}

@MainActor
final class SettingsStore {
    private enum Keys {
        static let autoPaste = "autoPaste"
        static let restoreClipboard = "restoreClipboard"
        static let realtimeTranscriptionEnabled = "realtimeTranscriptionEnabled"
        static let transcriptionDelay = "realtimeTranscriptionDelay"
        static let personalDictionary = "personalDictionary"
        static let legacyOpenRouterAPIKey = "openRouterAPIKey"
        static let usesLocalCredentials = "usesLocalCredentials"
        static let transcriptionModel = "openRouterTranscriptionModel"
        static let transcriptionContext = "openRouterTranscriptionContext"
        static let legacyCleanupPrompt = "openRouterCleanupPrompt"
        static let cleanupEnabled = "transcriptCleanupEnabled"
        static let cleanupModel = "transcriptCleanupModel"
        static let cleanupInstructions = "transcriptCleanupInstructions"
        static let minimalCleanupPromptInstalled = "minimalCleanupPromptInstalled"
    }

    private let defaults: UserDefaults
    private let openRouterCredentials: CredentialStore
    private let openAICredentials: CredentialStore
    private(set) var credentialSaveError: String?

    init(
        defaults: UserDefaults = .standard,
        credentials: CredentialStore = CredentialStore(),
        openAICredentials: CredentialStore = CredentialStore(
            account: "openai-api-key"
        )
    ) {
        self.defaults = defaults
        self.openRouterCredentials = credentials
        self.openAICredentials = openAICredentials
        replaceLegacyPrompts()
        registerDefaults()
        migrateLegacyAPIKey()
    }

    var autoPaste: Bool {
        get { defaults.bool(forKey: Keys.autoPaste) }
        set { defaults.set(newValue, forKey: Keys.autoPaste) }
    }

    var restoreClipboard: Bool {
        get { defaults.bool(forKey: Keys.restoreClipboard) }
        set { defaults.set(newValue, forKey: Keys.restoreClipboard) }
    }

    var openRouterAPIKey: String {
        get { openRouterCredentials.readAPIKey(useLocalStorage: usesLocalCredentials) ?? "" }
        set {
            do {
                try openRouterCredentials.writeAPIKey(
                    newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    useLocalStorage: usesLocalCredentials
                )
                credentialSaveError = nil
            } catch {
                credentialSaveError = "Could not save OpenRouter API key: \(error.localizedDescription)"
            }
        }
    }

    var openAIAPIKey: String {
        get { openAICredentials.readAPIKey(useLocalStorage: usesLocalCredentials) ?? "" }
        set {
            do {
                try openAICredentials.writeAPIKey(
                    newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    useLocalStorage: usesLocalCredentials
                )
                credentialSaveError = nil
            } catch {
                credentialSaveError = "Could not save OpenAI API key: \(error.localizedDescription)"
            }
        }
    }

    var realtimeTranscriptionEnabled: Bool {
        get { defaults.bool(forKey: Keys.realtimeTranscriptionEnabled) }
        set { defaults.set(newValue, forKey: Keys.realtimeTranscriptionEnabled) }
    }

    var transcriptionDelay: TranscriptionDelay {
        get {
            TranscriptionDelay(rawValue: defaults.string(forKey: Keys.transcriptionDelay) ?? "")
                ?? .xhigh
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.transcriptionDelay) }
    }

    var personalDictionary: [String] {
        defaults.stringArray(forKey: Keys.personalDictionary) ?? []
    }

    func setPersonalDictionary(_ entries: [String]) throws {
        let normalized = try PersonalDictionary.normalizedEntries(entries)
        defaults.set(normalized, forKey: Keys.personalDictionary)
    }

    var transcriptionModel: String {
        get {
            let value = defaults.string(forKey: Keys.transcriptionModel)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? OpenRouterService.transcriptionModel : value
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(
                value.isEmpty ? OpenRouterService.transcriptionModel : value,
                forKey: Keys.transcriptionModel
            )
        }
    }

    var hasOpenRouterAPIKey: Bool {
        !openRouterAPIKey.isEmpty
    }

    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Keys.cleanupEnabled) }
        set { defaults.set(newValue, forKey: Keys.cleanupEnabled) }
    }

    var cleanupModel: String {
        get {
            let value = defaults.string(forKey: Keys.cleanupModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? "google/gemini-3.8-flash" : value
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.cleanupModel) }
    }

    var cleanupInstructions: String {
        get {
            let instructions = defaults.string(forKey: Keys.cleanupInstructions) ?? ""
            return instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? OpenRouterService.defaultCleanupInstruction : instructions
        }
        set { defaults.set(newValue, forKey: Keys.cleanupInstructions) }
    }

    var cleanupConfiguration: TranscriptCleanupConfiguration? {
        cleanupEnabled ? TranscriptCleanupConfiguration(model: cleanupModel, instructions: cleanupInstructions) : nil
    }

    var hasOpenAIAPIKey: Bool {
        !openAIAPIKey.isEmpty
    }

    var canUseRealtimeGPTTranscribe: Bool {
        realtimeTranscriptionAvailability == .available
    }

    var realtimeTranscriptionAvailability: RealtimeTranscriptionAvailability {
        guard realtimeTranscriptionEnabled else {
            return .disabled
        }

        guard hasOpenAIAPIKey else {
            return .missingOpenAIAPIKey
        }

        return .available
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.autoPaste: true,
            Keys.restoreClipboard: true,
            Keys.realtimeTranscriptionEnabled: true,
            Keys.transcriptionDelay: TranscriptionDelay.xhigh.rawValue,
            Keys.personalDictionary: [String](),
            Keys.transcriptionModel: OpenRouterService.transcriptionModel
        ])
    }

    private func replaceLegacyPrompts() {
        guard !defaults.bool(forKey: Keys.minimalCleanupPromptInstalled) else { return }
        defaults.removeObject(forKey: Keys.transcriptionContext)
        defaults.removeObject(forKey: Keys.legacyCleanupPrompt)
        defaults.removeObject(forKey: Keys.cleanupInstructions)
        defaults.set(true, forKey: Keys.minimalCleanupPromptInstalled)
    }

    var usesLocalCredentials: Bool {
        defaults.bool(forKey: Keys.usesLocalCredentials)
    }

    func useLocalCredentialStorage() throws {
        guard !usesLocalCredentials else { return }
        // Read both before writing or switching. A denied Keychain request must
        // never be mistaken for an empty key and discard the saved credentials.
        let routerKey = try openRouterCredentials.readKeychainAPIKey()
        let openAIKey = try openAICredentials.readKeychainAPIKey()
        try openRouterCredentials.writeAPIKey(routerKey ?? "", useLocalStorage: true)
        try openAICredentials.writeAPIKey(openAIKey ?? "", useLocalStorage: true)
        defaults.set(true, forKey: Keys.usesLocalCredentials)
    }

    private func migrateLegacyAPIKey() {
        let legacyKey = defaults.string(forKey: Keys.legacyOpenRouterAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !legacyKey.isEmpty else { return }

        do {
            let existing = usesLocalCredentials
                ? try openRouterCredentials.readLocalAPIKey()
                : try openRouterCredentials.readKeychainAPIKey()
            if existing == nil {
                try openRouterCredentials.writeAPIKey(legacyKey, useLocalStorage: usesLocalCredentials)
            }
            defaults.removeObject(forKey: Keys.legacyOpenRouterAPIKey)
        } catch {
            print("Could not migrate OpenRouter API key: \(error.localizedDescription)")
        }
    }
}
