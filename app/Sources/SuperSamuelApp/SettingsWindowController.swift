import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private var window: NSWindow?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func show() {
        let window = ensureWindow()
        let host = NSHostingView(rootView: SettingsView(settings: settings))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = host
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            host.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            host.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        window.contentView = makeLiquidGlassHost(
            content: scrollView,
            cornerRadius: 24
        )
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func ensureWindow() -> NSWindow {
        if let window {
            return window
        }

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "SuperSamuel Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        return window
    }
}

private struct SettingsView: View {
    private let settings: SettingsStore

    @State private var openRouterAPIKey: String
    @State private var openAIAPIKey: String
    @State private var usesLocalCredentials: Bool
    @State private var credentialError: String?
    @State private var realtimeTranscriptionEnabled: Bool
    @State private var transcriptionModel: String
    @State private var transcriptionDelay: TranscriptionDelay
    @State private var dictionaryText: String
    @State private var dictionaryError: String?
    @State private var cleanupEnabled: Bool
    @State private var cleanupModel: String
    @State private var cleanupInstructions: String

    init(settings: SettingsStore) {
        self.settings = settings
        _openRouterAPIKey = State(initialValue: settings.openRouterAPIKey)
        _openAIAPIKey = State(initialValue: settings.openAIAPIKey)
        _usesLocalCredentials = State(initialValue: settings.usesLocalCredentials)
        _realtimeTranscriptionEnabled = State(
            initialValue: settings.realtimeTranscriptionEnabled
        )
        _cleanupEnabled = State(initialValue: settings.cleanupEnabled)
        _cleanupModel = State(initialValue: settings.cleanupModel)
        _cleanupInstructions = State(initialValue: settings.cleanupInstructions)
        _transcriptionModel = State(initialValue: settings.transcriptionModel)
        _transcriptionDelay = State(initialValue: settings.transcriptionDelay)
        _dictionaryText = State(initialValue: settings.personalDictionary.joined(separator: "\n"))
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                settingsContent
            }
        } else {
            settingsContent
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.system(size: 22, weight: .semibold))

            Text("Changes save automatically and apply to the next recording.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            section(title: "API key storage", description: usesLocalCredentials
                    ? "Keys are saved on this Mac and stay available after app updates, without Keychain prompts."
                    : "Keychain protects your keys. Locally rebuilt apps can trigger access prompts after updates.") {
                Text("Local storage uses an unencrypted file restricted to your Mac account. Other apps running under your account can read it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !usesLocalCredentials {
                    Button("Use local key storage") {
                        do {
                            try settings.useLocalCredentialStorage()
                            usesLocalCredentials = settings.usesLocalCredentials
                            openRouterAPIKey = settings.openRouterAPIKey
                            openAIAPIKey = settings.openAIAPIKey
                            credentialError = nil
                        } catch {
                            credentialError = "Could not move keys: " + error.localizedDescription
                        }
                    }
                    Text("Copies your saved keys; macOS may ask for access once. Existing Keychain entries are kept as a backup.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let credentialError {
                    Text(credentialError).font(.system(size: 11)).foregroundStyle(.red)
                }
            }

            section(
                title: "OpenRouter",
                description: "Used for optional text cleanup and saved-audio transcription when live transcription is unavailable."
            ) {
                SecureField("sk-or-v1-...", text: apiKeyBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .liquidGlassSurface(cornerRadius: 11)

                Text(usesLocalCredentials ? "Stored privately on this Mac." : "Stored in your macOS Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            section(
                title: "OpenAI Realtime",
                description: "Streams microphone audio to GPT Live Transcribe and displays text as you speak."
            ) {
                Text("OpenAI API key (separate from OpenRouter)")
                    .font(.system(size: 11, weight: .semibold))

                SecureField("sk-...", text: openAIAPIKeyBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .liquidGlassSurface(cornerRadius: 11)

                Toggle(
                    "Use GPT Live Transcribe",
                    isOn: realtimeTranscriptionEnabledBinding
                )

                Picker("Transcription delay", selection: transcriptionDelayBinding) {
                    ForEach(TranscriptionDelay.allCases, id: \.self) { delay in
                        Text(delay.title).tag(delay)
                    }
                }

                Text("Higher delay gives the model more audio context before showing text. The speech-pause threshold stays at 500 ms for every setting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Label(realtimeStatusText, systemImage: realtimeStatusSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(realtimeStatusColor)

                Text(usesLocalCredentials
                     ? "An OpenRouter key cannot authenticate the direct OpenAI WebSocket. The OpenAI key is stored separately on this Mac."
                     : "An OpenRouter key cannot authenticate the direct OpenAI WebSocket. The OpenAI key is stored separately in your macOS Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            section(
                title: "Text cleanup",
                description: "After transcription, an LLM edits the text using your full instructions. This adds a short wait after Stop; audio is not sent to the cleanup model."
            ) {
                Toggle("Clean up transcript after Stop", isOn: $cleanupEnabled)
                    .onChange(of: cleanupEnabled) { value in
                        settings.cleanupEnabled = value
                    }
                if cleanupEnabled {
                    TextField("google/gemini-3.8-flash", text: $cleanupModel)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(11)
                        .liquidGlassSurface(cornerRadius: 11)
                        .onChange(of: cleanupModel) { settings.cleanupModel = $0 }
                    Text("OpenRouter chat model")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if settings.cleanupModel == "google/gemini-3.8-flash" {
                        Text("Prefers Google AI Studio Priority at its higher rate, with fallback if unavailable.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Editing instructions").font(.headline)
                        Spacer()
                        Button("Restore Default") {
                            cleanupInstructions = OpenRouterService.defaultCleanupInstruction
                            settings.cleanupInstructions = cleanupInstructions
                        }
                        .liquidGlassButton(tint: Color.accentColor.opacity(0.78))
                        .disabled(cleanupInstructions == OpenRouterService.defaultCleanupInstruction)
                    }
                    TextEditor(text: $cleanupInstructions)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8).frame(height: 220)
                        .liquidGlassSurface(cornerRadius: 12)
                        .onChange(of: cleanupInstructions) { settings.cleanupInstructions = $0 }
                    Text("This is the complete cleanup prompt. Edit it here or restore the default. Turn cleanup off to deliver the transcription directly.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            section(
                title: "Saved-audio fallback",
                description: "Choose the OpenRouter model used to transcribe saved audio and retry recordings. Live transcription uses GPT Live Transcribe separately."
            ) {
                TextField(
                    OpenRouterService.transcriptionModel,
                    text: transcriptionModelBinding
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .liquidGlassSurface(cornerRadius: 11)

                Text("This field accepts speech-to-text models, not general chat models such as Gemini. It does not change the live model or add an LLM editing step.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

            }

            section(
                title: "Personal dictionary",
                description: "Add one word or phrase per line to help recognize names, products, and technical vocabulary."
            ) {
                TextEditor(text: dictionaryBinding)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 130)
                    .liquidGlassSurface(cornerRadius: 12)

                if let dictionaryError {
                    Text(dictionaryError + " Your last valid dictionary is still saved.")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Dictionary validation error: " + dictionaryError)
                } else {
                    Text("Saved automatically. Blank lines and duplicate entries are ignored; spelling from the first entry is kept.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 44)
        .padding(.bottom, 20)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { openRouterAPIKey },
            set: { value in
                openRouterAPIKey = value
                settings.openRouterAPIKey = value
                credentialError = settings.credentialSaveError
            }
        )
    }

    private var openAIAPIKeyBinding: Binding<String> {
        Binding(
            get: { openAIAPIKey },
            set: { value in
                openAIAPIKey = value
                settings.openAIAPIKey = value
                credentialError = settings.credentialSaveError
            }
        )
    }

    private var realtimeTranscriptionEnabledBinding: Binding<Bool> {
        Binding(
            get: { realtimeTranscriptionEnabled },
            set: { value in
                realtimeTranscriptionEnabled = value
                settings.realtimeTranscriptionEnabled = value
            }
        )
    }

    private var transcriptionModelBinding: Binding<String> {
        Binding(
            get: { transcriptionModel },
            set: { value in
                transcriptionModel = value
                settings.transcriptionModel = value
            }
        )
    }

    private var transcriptionDelayBinding: Binding<TranscriptionDelay> {
        Binding(
            get: { transcriptionDelay },
            set: { value in
                transcriptionDelay = value
                settings.transcriptionDelay = value
            }
        )
    }

    private var dictionaryBinding: Binding<String> {
        Binding(
            get: { dictionaryText },
            set: { value in
                dictionaryText = value
                do {
                    // Normalize pasted CRLF line endings before validating individual terms.
                    let lines = value.replacingOccurrences(of: "\r\n", with: "\n")
                        .components(separatedBy: "\n")
                    try settings.setPersonalDictionary(lines)
                    dictionaryError = nil
                } catch {
                    dictionaryError = error.localizedDescription
                }
            }
        )
    }

    private var realtimeStatusText: String {
        guard realtimeTranscriptionEnabled else {
            return "Live transcription is disabled."
        }
        guard !openAIAPIKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return "Not active — add an OpenAI API key."
        }
        return "Ready for GPT Live Transcribe."
    }

    private var realtimeStatusSymbol: String {
        realtimeIsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var realtimeStatusColor: Color {
        realtimeIsReady ? .green : .orange
    }

    private var realtimeIsReady: Bool {
        realtimeTranscriptionEnabled &&
            !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            content()
        }
        .padding(14)
        .liquidGlassSurface(cornerRadius: 18)
    }

}
