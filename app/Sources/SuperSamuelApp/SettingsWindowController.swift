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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
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
    @State private var transcriptionModel: String
    @State private var transcriptionContext: String

    init(settings: SettingsStore) {
        self.settings = settings
        _openRouterAPIKey = State(initialValue: settings.openRouterAPIKey)
        _transcriptionModel = State(initialValue: settings.transcriptionModel)
        _transcriptionContext = State(initialValue: settings.transcriptionContext)
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
                    description: "Your API key is used for the single transcription request."
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
                    title: "Transcription",
                    description: "One model listens to the recording and returns ready-to-paste text."
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

                        Text("Sent with the audio as GPT Transcribe's free-form context. Use it for minimal cleanup, expected names, technical terms, version numbers, languages, and punctuation style.")
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
        .frame(minWidth: 680, minHeight: 620)
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
