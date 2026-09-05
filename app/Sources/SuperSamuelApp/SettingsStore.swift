import Foundation
import Security

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
        static let transcriptionModel = "openRouterTranscriptionModel"
        static let transcriptionContext = "openRouterTranscriptionContext"
        static let legacyCleanupPrompt = "openRouterCleanupPrompt"
    }

    private let defaults: UserDefaults
    private let openRouterCredentials: CredentialStore
    private let openAICredentials: CredentialStore

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
        migrateLegacyCleanupPrompt()
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
        get { openRouterCredentials.readAPIKey() ?? "" }
        set {
            do {
                try openRouterCredentials.writeAPIKey(
                    newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch {
                print("Could not save OpenRouter API key: \(error.localizedDescription)")
            }
        }
    }

    var openAIAPIKey: String {
        get { openAICredentials.readAPIKey() ?? "" }
        set {
            do {
                try openAICredentials.writeAPIKey(
                    newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch {
                print("Could not save OpenAI API key: \(error.localizedDescription)")
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

    var transcriptionContext: String {
        get {
            defaults.string(forKey: Keys.transcriptionContext)
                ?? OpenRouterService.defaultTranscriptionInstruction
        }
        set { defaults.set(newValue, forKey: Keys.transcriptionContext) }
    }

    var hasOpenRouterAPIKey: Bool {
        !openRouterAPIKey.isEmpty
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
            Keys.transcriptionModel: OpenRouterService.transcriptionModel,
            Keys.transcriptionContext: OpenRouterService.defaultTranscriptionInstruction
        ])
    }

    private func migrateLegacyCleanupPrompt() {
        guard let legacyPrompt = defaults.string(
                forKey: Keys.legacyCleanupPrompt
              ),
              !legacyPrompt.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
        else {
            return
        }

        let currentContext = defaults.string(forKey: Keys.transcriptionContext)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard currentContext.isEmpty ||
                currentContext == OpenRouterService.defaultTranscriptionInstruction
        else {
            return
        }

        defaults.set(legacyPrompt, forKey: Keys.transcriptionContext)
    }

    private func migrateLegacyAPIKey() {
        guard openRouterCredentials.readAPIKey() == nil else {
            defaults.removeObject(forKey: Keys.legacyOpenRouterAPIKey)
            return
        }

        let legacyKey = defaults.string(forKey: Keys.legacyOpenRouterAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !legacyKey.isEmpty else {
            return
        }

        do {
            try openRouterCredentials.writeAPIKey(legacyKey)
            defaults.removeObject(forKey: Keys.legacyOpenRouterAPIKey)
        } catch {
            print("Could not migrate OpenRouter API key to Keychain: \(error.localizedDescription)")
        }
    }
}

final class CredentialStore {
    private let service: String
    private let account: String

    init(
        service: String = Bundle.main.bundleIdentifier ?? "com.supersamuel.app",
        account: String = "openrouter-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    func writeAPIKey(_ apiKey: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if apiKey.isEmpty {
            let status = SecItemDelete(lookup as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.keychain(status)
            }
            return
        }

        let data = Data(apiKey.utf8)
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var item = lookup
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }
}

private enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
        }
    }
}
