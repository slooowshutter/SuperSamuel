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
        window.contentView = makeLiquidGlassHost(
            content: host,
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

        let window = NSWindow(
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
    @State private var realtimeTranscriptionEnabled: Bool
    @State private var transcriptionModel: String
    @State private var transcriptionContext: String
    @State private var transcriptionDelay: TranscriptionDelay
    @State private var dictionaryText: String
    @State private var dictionaryError: String?

    init(settings: SettingsStore) {
        self.settings = settings
        _openRouterAPIKey = State(initialValue: settings.openRouterAPIKey)
        _openAIAPIKey = State(initialValue: settings.openAIAPIKey)
        _realtimeTranscriptionEnabled = State(
            initialValue: settings.realtimeTranscriptionEnabled
        )
        _transcriptionModel = State(initialValue: settings.transcriptionModel)
        _transcriptionContext = State(initialValue: settings.transcriptionContext)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold))

                Text("Changes save automatically and apply to the next recording.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                section(
                    title: "OpenRouter",
                    description: "Used as the durable saved-audio fallback if realtime transcription is unavailable."
                ) {
                    SecureField("sk-or-v1-...", text: apiKeyBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .liquidGlassSurface(cornerRadius: 11)

                    Text("Stored in your macOS Keychain.")
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

                    Text("An OpenRouter key cannot authenticate the direct OpenAI WebSocket. The OpenAI key is stored separately in your macOS Keychain.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                section(
                    title: "Transcription",
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

                    Text("Enter any OpenRouter model supported by the audio transcription endpoint. Clear the field to restore the default.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Transcription instructions")
                                .font(.system(size: 13, weight: .semibold))

                            Spacer()

                            Button("Restore Default") {
                                transcriptionContext =
                                    OpenRouterService.defaultTranscriptionInstruction
                                settings.transcriptionContext =
                                    OpenRouterService.defaultTranscriptionInstruction
                            }
                            .liquidGlassButton(
                                tint: Color.accentColor.opacity(0.78)
                            )
                            .disabled(
                                transcriptionContext ==
                                    OpenRouterService.defaultTranscriptionInstruction
                            )
                        }

                        TextEditor(text: transcriptionContextBinding)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 220)
                            .liquidGlassSurface(cornerRadius: 12)

                        Text("Use these instructions for minimal cleanup, languages, and punctuation style. Add names and technical terms to your personal dictionary below. Long instructions are applied in full after Stop while live preview continues.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if !RealtimeTranscriptionService.contextIsValid(transcriptionContext) {
                            Text("Your full instructions are saved. Live preview uses your personal dictionary; the final transcription applies these instructions after Stop.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                section(
                    title: "Personal dictionary",
                    description: "Add one word or phrase per line to help recognize names, products, and technical vocabulary."
                ) {
                    TextEditor(text: dictionaryBinding)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 130)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 680, minHeight: 700)
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { openRouterAPIKey },
            set: { value in
                openRouterAPIKey = value
                settings.openRouterAPIKey = value
            }
        )
    }

    private var openAIAPIKeyBinding: Binding<String> {
        Binding(
            get: { openAIAPIKey },
            set: { value in
                openAIAPIKey = value
                settings.openAIAPIKey = value
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

    private var transcriptionContextBinding: Binding<String> {
        Binding(
            get: { transcriptionContext },
            set: { value in
                transcriptionContext = value
                settings.transcriptionContext = value
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
