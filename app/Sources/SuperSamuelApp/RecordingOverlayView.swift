import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var state: AppState
    var onStop: (() -> Void)?
    var onAttachScreenshot: (() -> Void)?
    var onClearScreenshot: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDelete: (() -> Void)?

    private let panelWidth: CGFloat = 376

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header

            WaveformView(
                samples: state.waveformSamples,
                color: statusColor
            )
            .frame(height: 32)

            controlStrip

            if let attachment = state.attachedScreenshot {
                attachmentRow(attachment)
            }

            Divider()
                .overlay(Color.white.opacity(0.13))

            statusFooter
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 17)
        .frame(width: panelWidth)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 34, height: 34)
            .liquidGlassSurface(cornerRadius: 9)

            VStack(alignment: .leading, spacing: 1) {
                Text("SuperSamuel")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.96))

                Text(statusLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(statusColor.opacity(0.96))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(formattedDuration(state.elapsedSeconds))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.94))
            }

            Button(action: { onStop?() }) {
                Image(systemName: stopSymbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .liquidGlassButton()
            .help(stopHelpText)
        }
    }

    private var controlStrip: some View {
        HStack(spacing: 10) {
            Toggle("Enhance", isOn: $state.enhancementEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.84))
                .disabled(state.phase != .recording)

            Spacer(minLength: 6)

            if state.attachedScreenshot == nil {
                compactButton(
                    title: state.isCapturingScreenshot ? "Capturing" : "Context",
                    symbol: "camera",
                    action: onAttachScreenshot,
                    disabled: !canEditScreenshot || state.isCapturingScreenshot
                )
            } else {
                compactButton(
                    title: "Retake",
                    symbol: "camera.rotate",
                    action: onAttachScreenshot,
                    disabled: !canEditScreenshot || state.isCapturingScreenshot
                )

                Button(action: { onClearScreenshot?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .frame(width: 25, height: 25)
                }
                .liquidGlassButton()
                .foregroundStyle(Color.white.opacity(0.78))
                .disabled(!canEditScreenshot || state.isCapturingScreenshot)
            }
        }
    }

    private func attachmentRow(
        _ attachment: AttachedScreenshot
    ) -> some View {
        HStack(spacing: 9) {
            Image(nsImage: attachment.previewImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 50, height: 34)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Context attached")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))

                Text(attachment.sourceDescription)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(footerText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(
                    state.phase.isError
                        ? Color.orange.opacity(0.96)
                        : Color.white.opacity(0.66)
                )
                .lineLimit(state.phase.isError ? 3 : 1)
                .fixedSize(horizontal: false, vertical: true)

            if state.showsRecoveryActions {
                HStack(spacing: 8) {
                    Button("Retry") {
                        onRetry?()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)

                    Button("Trash…") {
                        onDelete?()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
    }

    private func compactButton(
        title: String,
        symbol: String,
        action: (() -> Void)?,
        disabled: Bool
    ) -> some View {
        Button(action: { action?() }) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))

                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 27)
        }
        .liquidGlassButton()
        .foregroundStyle(
            disabled
                ? Color.white.opacity(0.36)
                : Color.white.opacity(0.86)
        )
        .disabled(disabled)
    }

    private var footerText: String {
        if let screenshotMessage = state.screenshotStatusMessage,
           !screenshotMessage.isEmpty
        {
            return screenshotMessage
        }

        return state.transcriptPreviewLines.last
            ?? "Press Option+Space to start dictation."
    }

    private var statusLabel: String {
        switch state.phase {
        case .idle:
            return "Ready"
        case .recording:
            if let deviceName = state.recordingDeviceName,
               !deviceName.isEmpty
            {
                return "Recording · \(deviceName)"
            }
            return "Recording · System microphone"
        case .transcribing:
            return "Transcribing"
        case .enhancing:
            return "Enhancing"
        case .error:
            return "Needs attention"
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .idle:
            return Color.white.opacity(0.56)
        case .recording:
            return Color(red: 1, green: 0.31, blue: 0.38)
        case .transcribing:
            return Color(red: 0.38, green: 0.72, blue: 1)
        case .enhancing:
            return Color(red: 0.68, green: 0.55, blue: 1)
        case .error:
            return Color.orange
        }
    }

    private var canEditScreenshot: Bool {
        state.phase == .recording
    }

    private var stopSymbol: String {
        switch state.phase {
        case .recording:
            return "stop.fill"
        case .transcribing, .enhancing:
            return "xmark"
        case .idle, .error:
            return "xmark"
        }
    }

    private var stopHelpText: String {
        switch state.phase {
        case .recording:
            return "Stop recording"
        case .transcribing, .enhancing:
            return "Cancel processing"
        case .idle, .error:
            return "Dismiss"
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        let minutes = whole / 60
        let remaining = whole % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }
}

private extension DictationPhase {
    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }
}

private struct WaveformView: View {
    let samples: [CGFloat]
    let color: Color

    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    Capsule(style: .continuous)
                        .fill(color.opacity(0.38 + (sample * 0.58)))
                        .frame(
                            width: barWidth(in: geometry.size.width),
                            height: barHeight(sample)
                        )
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .center
            )
        }
    }

    private func barWidth(in totalWidth: CGFloat) -> CGFloat {
        guard !samples.isEmpty else {
            return 2
        }

        let totalSpacing = CGFloat(samples.count - 1) * spacing
        return max(
            1.2,
            (totalWidth - totalSpacing) / CGFloat(samples.count)
        )
    }

    private func barHeight(_ sample: CGFloat) -> CGFloat {
        2.5 + (26 * pow(max(0, min(sample, 1)), 1.55))
    }
}
