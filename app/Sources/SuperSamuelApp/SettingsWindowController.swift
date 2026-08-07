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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
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
    @State private var enhancementModel: String
    @State private var enhancementPrompt: String
    @State private var enhancementEnabledByDefault: Bool

    private static let customModelSelection = "__custom__"
    private static let suggestedModels = [
        EnhancementModelPreset(
            id: "openai/gpt-audio-mini",
            label: "GPT Audio Mini — Best quality"
        ),
        EnhancementModelPreset(
            id: "mistralai/voxtral-small-24b-2507",
            label: "Voxtral Small 24B — Balanced"
        ),
        EnhancementModelPreset(
            id: "google/gemini-3.5-flash",
            label: "Gemini 3.5 Flash — Fast"
        )
    ]

    init(settings: SettingsStore) {
        self.settings = settings
        _openRouterAPIKey = State(initialValue: settings.openRouterAPIKey)
        _enhancementModel = State(initialValue: settings.enhancementModel)
        _enhancementPrompt = State(initialValue: settings.enhancementPrompt)
        _enhancementEnabledByDefault = State(initialValue: settings.enhancementEnabledByDefault)
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
                    description: "The same API key is used for fast Whisper transcription and optional audio enhancement."
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
                    description: "With Enhance off, recordings use the fast, literal transcription path."
                ) {
                    labeledValue(
                        label: "Model",
                        value: OpenRouterService.transcriptionModel
                    )
                }

                section(
                    title: "Audio Enhancement",
                    description: "With Enhance on, the selected audio model listens directly to the recording and returns clean, ready-to-paste text. Whisper is not run first."
                ) {
                    Toggle(
                        "Enable enhancement by default",
                        isOn: enhancementEnabledByDefaultBinding
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Audio model")
                            .font(.system(size: 13, weight: .semibold))

                        Picker("Suggested model", selection: enhancementPresetBinding) {
                            ForEach(Self.suggestedModels) { preset in
                                Text(preset.label).tag(preset.id)
                            }
                            Divider()
                            Text("Custom OpenRouter model…")
                                .tag(Self.customModelSelection)
                        }
                        .pickerStyle(.menu)

                        Text("Choose a suggestion or enter any OpenRouter chat model that accepts audio input.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        TextField("openai/gpt-audio-mini", text: enhancementModelBinding)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .liquidGlassSurface(cornerRadius: 11)

                        Text("Screenshot text is extracted locally for every model. Gemini models also receive the screenshot image.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Enhancement instructions")
                                .font(.system(size: 13, weight: .semibold))

                            Spacer()

                            Button("Restore Default") {
                                enhancementPrompt = OpenRouterService.defaultCleanupInstruction
                                settings.enhancementPrompt = OpenRouterService.defaultCleanupInstruction
                            }
                            .liquidGlassButton(
                                tint: Color.accentColor.opacity(0.78)
                            )
                            .disabled(enhancementPrompt == OpenRouterService.defaultCleanupInstruction)
                        }

                        TextEditor(text: enhancementPromptBinding)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 170)
                            .liquidGlassSurface(cornerRadius: 12)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 680, minHeight: 720)
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

    private var enhancementModelBinding: Binding<String> {
        Binding(
            get: { enhancementModel },
            set: { value in
                enhancementModel = value
                settings.enhancementModel = value
            }
        )
    }

    private var enhancementPromptBinding: Binding<String> {
        Binding(
            get: { enhancementPrompt },
            set: { value in
                enhancementPrompt = value
                settings.enhancementPrompt = value
            }
        )
    }

    private var enhancementEnabledByDefaultBinding: Binding<Bool> {
        Binding(
            get: { enhancementEnabledByDefault },
            set: { value in
                enhancementEnabledByDefault = value
                settings.enhancementEnabledByDefault = value
            }
        )
    }

    private var enhancementPresetBinding: Binding<String> {
        Binding(
            get: {
                Self.suggestedModels.contains { $0.id == enhancementModel }
                    ? enhancementModel
                    : Self.customModelSelection
            },
            set: { selection in
                guard selection != Self.customModelSelection else {
                    return
                }
                enhancementModel = selection
                settings.enhancementModel = selection
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

    private func labeledValue(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlassSurface(cornerRadius: 11)
    }
}

private struct EnhancementModelPreset: Identifiable {
    let id: String
    let label: String
}
