import SwiftUI

/// The values and copy of the Settings window. The sidebar and the page both read it.
@MainActor
final class SettingsModel: ObservableObject {
    private let settings: SettingsStore

    @Published var openRouterAPIKey: String {
        didSet {
            settings.openRouterAPIKey = openRouterAPIKey
            credentialError = settings.credentialSaveError
        }
    }
    @Published var openAIAPIKey: String {
        didSet {
            settings.openAIAPIKey = openAIAPIKey
            credentialError = settings.credentialSaveError
        }
    }
    @Published private(set) var usesLocalCredentials: Bool
    @Published private(set) var credentialError: String?
    @Published var realtimeTranscriptionEnabled: Bool {
        didSet { settings.realtimeTranscriptionEnabled = realtimeTranscriptionEnabled }
    }
    @Published var transcriptionDelay: TranscriptionDelay {
        didSet { settings.transcriptionDelay = transcriptionDelay }
    }
    @Published var cleanupEnabled: Bool {
        didSet { settings.cleanupEnabled = cleanupEnabled }
    }
    @Published var cleanupModel: String {
        didSet { settings.cleanupModel = cleanupModel }
    }
    @Published var cleanupInstructions: String {
        didSet { settings.cleanupInstructions = cleanupInstructions }
    }
    @Published var transcriptionModel: String {
        didSet { settings.transcriptionModel = transcriptionModel }
    }
    @Published var dictionaryText: String {
        didSet {
            do {
                // Normalize pasted CRLF line endings before validating individual terms.
                let lines = dictionaryText.replacingOccurrences(of: "\r\n", with: "\n")
                    .components(separatedBy: "\n")
                try settings.setPersonalDictionary(lines)
                dictionaryError = nil
            } catch {
                dictionaryError = error.localizedDescription
            }
        }
    }
    @Published private(set) var dictionaryError: String?

    // Navigation shared by the sidebar and the detail pane.
    @Published var selection: SettingsSection? = .keys

    init(settings: SettingsStore) {
        self.settings = settings
        openRouterAPIKey = settings.openRouterAPIKey
        openAIAPIKey = settings.openAIAPIKey
        usesLocalCredentials = settings.usesLocalCredentials
        realtimeTranscriptionEnabled = settings.realtimeTranscriptionEnabled
        transcriptionDelay = settings.transcriptionDelay
        cleanupEnabled = settings.cleanupEnabled
        cleanupModel = settings.cleanupModel
        cleanupInstructions = settings.cleanupInstructions
        transcriptionModel = settings.transcriptionModel
        dictionaryText = settings.personalDictionary.joined(separator: "\n")
    }

    func useLocalKeyStorage() {
        do {
            try settings.useLocalCredentialStorage()
            usesLocalCredentials = settings.usesLocalCredentials
            credentialError = nil
        } catch {
            credentialError = "Could not move keys: " + error.localizedDescription
        }
    }

    func restoreDefaultInstructions() {
        cleanupInstructions = OpenRouterService.defaultCleanupInstruction
    }

    var usesDefaultInstructions: Bool {
        cleanupInstructions == OpenRouterService.defaultCleanupInstruction
    }

    var realtimeIsReady: Bool {
        realtimeTranscriptionEnabled &&
            !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var realtimeStatusText: String {
        guard realtimeTranscriptionEnabled else { return "Live transcription is disabled." }
        return realtimeIsReady ? "Ready for GPT Live Transcribe." : "Not active — add an OpenAI API key."
    }

    var realtimeStatusSymbol: String {
        realtimeIsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    var realtimeStatusColor: Color {
        realtimeIsReady ? .green : .orange
    }

    /// Shows enough of a saved key to tell keys apart without revealing it.
    func keyPreview(_ key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count > 20 else { return nil }
        return "Saved key: \(key.prefix(12))…\(key.suffix(4))"
    }

    var cleanupRouteNote: String? {
        switch settings.cleanupModel {
        case OpenRouterService.defaultCleanupModel:
            return "Uses Cerebras with thinking off for faster cleanup. If unavailable, your draft is kept for retry."
        case "google/gemini-3.8-flash":
            return "Prefers Google AI Studio Priority at its higher rate, with fallback if unavailable."
        default:
            return nil
        }
    }

    var keyStorageDescription: String {
        usesLocalCredentials
            ? "Keys are saved on this Mac and stay available after app updates, without Keychain prompts."
            : "Keychain protects your keys. Locally rebuilt apps can trigger access prompts after updates."
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case keys, live, cleanup, fallback, dictionary

    var id: Self { self }

    var title: String {
        switch self {
        case .keys: return "API keys"
        case .live: return "Live transcription"
        case .cleanup: return "Text cleanup"
        case .fallback: return "Saved-audio fallback"
        case .dictionary: return "Personal dictionary"
        }
    }

    var symbol: String {
        switch self {
        case .keys: return "key.fill"
        case .live: return "waveform"
        case .cleanup: return "wand.and.stars"
        case .fallback: return "arrow.clockwise"
        case .dictionary: return "character.book.closed.fill"
        }
    }

    @MainActor
    func summary(_ model: SettingsModel) -> String {
        switch self {
        case .keys:
            return model.keyStorageDescription
        case .live:
            return "Streams microphone audio to GPT Live Transcribe and displays text as you speak."
        case .cleanup:
            return "After transcription, an LLM edits the text using your full instructions. This adds a short wait after Stop; audio is not sent to the cleanup model."
        case .fallback:
            return "Choose the OpenRouter model used to transcribe saved audio and retry recordings. Live transcription uses GPT Live Transcribe separately."
        case .dictionary:
            return "Add one word or phrase per line to help recognize names, products, and technical vocabulary."
        }
    }

    static let saveNote = "Changes save automatically and apply to the next recording."
}
