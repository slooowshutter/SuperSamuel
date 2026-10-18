import SwiftUI

/// The controls of one settings section.
struct SettingsSectionFields: View {
    let section: SettingsSection
    @ObservedObject var model: SettingsModel

    var body: some View {
        switch section {
        case .keys: keys
        case .live: live
        case .cleanup: cleanup
        case .fallback: fallback
        case .dictionary: dictionary
        }
    }

    @ViewBuilder
    private var keys: some View {
        SettingsCodeField(label: "OpenRouter key", text: $model.openRouterAPIKey, prompt: "sk-or-v1-...", secure: true)
        SettingsCaption(
            preview: model.keyPreview(model.openRouterAPIKey),
            text: (model.usesLocalCredentials ? "Stored privately on this Mac. " : "Stored in your macOS Keychain. ") +
                "Used for optional text cleanup and saved-audio transcription when live transcription is unavailable."
        )
        SettingsCodeField(label: "OpenAI key", text: $model.openAIAPIKey, prompt: "sk-...", secure: true)
        SettingsCaption(
            preview: model.keyPreview(model.openAIAPIKey),
            text: model.usesLocalCredentials
                ? "An OpenRouter key cannot authenticate the direct OpenAI WebSocket. The OpenAI key is stored separately on this Mac."
                : "An OpenRouter key cannot authenticate the direct OpenAI WebSocket. The OpenAI key is stored separately in your macOS Keychain."
        )
        LabeledContent("Key storage") {
            if model.usesLocalCredentials {
                Text("This Mac")
            } else {
                Button("Use local key storage") { model.useLocalKeyStorage() }
            }
        }
        SettingsCaption(
            text: "Local storage uses an unencrypted file restricted to your Mac account. Other apps running under your account can read it." +
                (model.usesLocalCredentials ? "" : " Copies your saved keys; macOS may ask for access once. Existing Keychain entries are kept as a backup.")
        )
        if let error = model.credentialError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var live: some View {
        Toggle("Use GPT Live Transcribe", isOn: $model.realtimeTranscriptionEnabled)
        LabeledContent("Transcription delay") {
            Picker("Transcription delay", selection: $model.transcriptionDelay) {
                ForEach(TranscriptionDelay.allCases, id: \.self) { delay in
                    Text(delay.title).tag(delay)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        SettingsCaption(
            text: "Higher delay gives the model more audio context before showing text. The speech-pause threshold stays at 500 ms for every setting."
        )
        Label(model.realtimeStatusText, systemImage: model.realtimeStatusSymbol)
            .foregroundStyle(model.realtimeStatusColor)
    }

    @ViewBuilder
    private var cleanup: some View {
        Toggle("Clean up transcript after Stop", isOn: $model.cleanupEnabled)
        if model.cleanupEnabled {
            SettingsCodeField(label: "OpenRouter chat model", text: $model.cleanupModel, prompt: OpenRouterService.defaultCleanupModel)
            if let note = model.cleanupRouteNote {
                SettingsCaption(text: note)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Editing instructions")
                    Spacer()
                    Button("Restore Default") { model.restoreDefaultInstructions() }
                        .disabled(model.usesDefaultInstructions)
                }
                SettingsTextEditor(text: $model.cleanupInstructions, minHeight: 220)
                SettingsCaption(
                    text: "This is the complete cleanup prompt. Edit it here or restore the default. Turn cleanup off to deliver the transcription directly."
                )
            }
        }
    }

    @ViewBuilder
    private var fallback: some View {
        SettingsCodeField(label: "Transcription model", text: $model.transcriptionModel, prompt: OpenRouterService.transcriptionModel)
        SettingsCaption(
            text: "This field accepts speech-to-text models, not general chat models such as Gemini. It does not change the live model or add an LLM editing step."
        )
    }

    @ViewBuilder
    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsTextEditor(text: $model.dictionaryText, minHeight: 160)
            if let error = model.dictionaryError {
                Text(error + " Your last valid dictionary is still saved.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Dictionary validation error: " + error)
            } else {
                SettingsCaption(
                    text: "Saved automatically. Blank lines and duplicate entries are ignored; spelling from the first entry is kept."
                )
            }
        }
    }
}

/// A labeled field whose value, not its label, uses the monospaced font.
struct SettingsCodeField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var secure = false

    var body: some View {
        LabeledContent(label) {
            Group {
                if secure {
                    SecureField(label, text: $text, prompt: Text(prompt))
                } else {
                    TextField(label, text: $text, prompt: Text(prompt))
                }
            }
            .labelsHidden()
            .font(.system(.body, design: .monospaced))
        }
    }
}

struct SettingsCaption: View {
    var preview: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let preview {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A text box that lets the window glass show through, faintly, behind the text.
struct SettingsTextEditor: View {
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.45),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
    }
}
