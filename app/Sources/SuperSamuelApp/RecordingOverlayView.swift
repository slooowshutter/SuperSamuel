import AppKit
import SwiftUI

/// The floating recording window: the timer in a ring, the dictation details with a
/// level grid, and the live transcript where only the newest sentence is bright. It
/// sits on the same Liquid Glass as Settings.
struct RecordingOverlayView: View {
    @ObservedObject var state: AppState
    var onStop: (() -> Void)?
    var onAttachScreenshot: (() -> Void)?
    var onClearScreenshot: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Called while the user drags an edge or a corner, with the dragged edges.
    /// `true` ends the drag.
    var onResize: ((Edge.Set, Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Text(elapsedText)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 84, height: 84)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 2))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(isRecording ? "Dictation" : phaseTitle)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        contextButton(size: 24)
                        stopButton(size: 24)
                    }
                    detailRow("clock", "Today, \(startTimeText)")
                    detailRow("mic", deviceName ?? "Microphone off")
                    if let attachment = state.attachedScreenshot {
                        detailRow("camera", "Context: \(attachment.sourceDescription)")
                    }
                    LevelGrid(samples: state.waveformSamples, isActive: isRecording)
                        .frame(height: 34)
                }
            }

            TranscriptView(state: state)
            notices
            recoveryActions
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            ResizeHandles(onResize: onResize)
        }
        .animation(.easeOut(duration: 0.2), value: state.phase)
        .animation(.easeOut(duration: 0.2), value: state.attachedScreenshot?.id)
        .animation(.easeOut(duration: 0.2), value: state.showsRecoveryActions)
    }
}

// MARK: - State

private extension RecordingOverlayView {
    var isRecording: Bool {
        state.phase == .recording
    }

    var elapsedText: String {
        let whole = Int(state.elapsedSeconds.rounded(.down))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    /// The clock time when this recording started.
    var startTimeText: String {
        Date().addingTimeInterval(-state.elapsedSeconds).formatted(date: .omitted, time: .shortened)
    }

    var phaseTitle: String {
        switch state.phase {
        case .idle: state.captureStatusMessage == nil ? "Ready" : "Transcript saved"
        case .recording: "Recording"
        case .transcribing: state.processingStatusMessage ?? "Transcribing"
        case .error: "Needs attention"
        }
    }

    /// The microphone in use. Only shown while recording.
    var deviceName: String? {
        guard isRecording else {
            return nil
        }
        if let name = state.recordingDeviceName, !name.isEmpty {
            return name
        }
        return "System microphone"
    }

    var stopHelpText: String {
        switch state.phase {
        case .recording: "Stop recording"
        case .transcribing: "Cancel processing"
        case .idle, .error: "Dismiss"
        }
    }

    var hasNotices: Bool {
        state.captureStatusMessage != nil
            || !(state.screenshotStatusMessage ?? "").isEmpty
            || (isRecording && state.liveInstructionsShortened)
    }
}

// MARK: - Controls

private extension RecordingOverlayView {
    func detailRow(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
        .font(.callout)
    }

    /// A round Liquid Glass button with one symbol.
    func iconButton(
        _ symbol: String,
        size: CGFloat,
        help: String,
        action: (() -> Void)?
    ) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Circle(), interactive: true)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Stop while recording, cancel while transcribing, dismiss otherwise.
    func stopButton(size: CGFloat) -> some View {
        iconButton(
            isRecording ? "stop.fill" : "xmark",
            size: size,
            help: stopHelpText,
            action: onStop
        )
    }

    /// The screenshot control: a camera button, or the attached screenshot, which
    /// retakes on click and has a badge to remove it.
    @ViewBuilder
    func contextButton(size: CGFloat) -> some View {
        if let attachment = state.attachedScreenshot {
            Button {
                onAttachScreenshot?()
            } label: {
                Image(nsImage: attachment.previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isRecording)
            .help("Retake the screenshot of \(attachment.sourceDescription)")
            .overlay(alignment: .topTrailing) {
                if isRecording {
                    Button {
                        onClearScreenshot?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.62))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .help("Remove the screenshot")
                    .accessibilityLabel("Remove the screenshot")
                }
            }
        } else if isRecording {
            iconButton(
                state.isCapturingScreenshot ? "camera.badge.ellipsis" : "camera",
                size: size,
                help: "Attach a screenshot of the current window as context",
                action: onAttachScreenshot
            )
        }
    }

    @ViewBuilder
    var recoveryActions: some View {
        if state.showsRecoveryActions {
            HStack(spacing: 8) {
                Button("Retry") { onRetry?() }
                    .liquidGlassButton(prominent: true)
                if state.canCopyRecoveredTranscript {
                    Button("Copy") { onCopy?() }
                        .liquidGlassButton()
                }
                Button("Trash") { onDelete?() }
                    .liquidGlassButton()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    var notices: some View {
        if hasNotices {
            VStack(alignment: .leading, spacing: 4) {
                if let message = state.captureStatusMessage {
                    noticeText(message, color: .orange)
                }
                if let message = state.screenshotStatusMessage, !message.isEmpty {
                    noticeText(message, color: .orange)
                }
                if isRecording && state.liveInstructionsShortened {
                    noticeText(
                        "Live instructions limited to 1,024 characters · No extra transcription",
                        color: .secondary
                    )
                }
            }
        }
    }

    func noticeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Transcript

/// The live transcript in semibold type, kept scrolled to the newest words. Only the
/// newest sentence is bright, like live lyrics. Once the text is taller than the view,
/// the oldest lines fade out at the top instead of being cut.
private struct TranscriptView: View {
    @ObservedObject var state: AppState
    @State private var textHeight: CGFloat = 0

    private static let end = "transcript-end"

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    label
                        .font(.system(size: 17, weight: .semibold))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(
                            GeometryReader { text in
                                Color.clear
                                    .onAppear { textHeight = text.size.height }
                                    .onChange(of: text.size.height) { textHeight = $0 }
                            }
                        )
                        .id(Self.end)
                }
                .onAppear {
                    proxy.scrollTo(Self.end, anchor: .bottom)
                }
                .onChange(of: state.transcriptText) { _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.end, anchor: .bottom)
                    }
                }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: textHeight > viewport.size.height + 1 ? 26 : 0)
                    Color.black
                }
            }
        }
    }

    private var label: Text {
        guard !state.transcriptIsStatus else {
            return Text(state.transcriptText)
                .foregroundColor(state.phase.isError ? .orange : .secondary)
        }
        let sentences = state.transcriptText.sentences
        return sentences.enumerated().reduce(Text("")) { result, item in
            let isLatest = item.offset == sentences.count - 1
            return result + Text((item.offset == 0 ? "" : " ") + item.element)
                .foregroundColor(isLatest ? .primary : Color.primary.opacity(0.3))
        }
    }
}

private extension String {
    var sentences: [String] {
        var result: [String] = []
        enumerateSubstrings(in: startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sentence.isEmpty
            {
                result.append(sentence)
            }
        }
        return result.isEmpty ? [self] : result
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

// MARK: - Resizing

/// Invisible strips along the edges and corners of the borderless window. Dragging
/// one resizes the window from that side.
private struct ResizeHandles: View {
    let onResize: ((Edge.Set, Bool) -> Void)?

    private let edge: CGFloat = 6
    private let corner: CGFloat = 22

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                handle(.top).frame(height: edge).padding(.horizontal, corner)
            }
            .overlay(alignment: .bottom) {
                handle(.bottom).frame(height: edge).padding(.horizontal, corner)
            }
            .overlay(alignment: .leading) {
                handle(.leading).frame(width: edge).padding(.vertical, corner)
            }
            .overlay(alignment: .trailing) {
                handle(.trailing).frame(width: edge).padding(.vertical, corner)
            }
            .overlay(alignment: .topLeading) {
                handle([.top, .leading]).frame(width: corner, height: corner)
            }
            .overlay(alignment: .topTrailing) {
                handle([.top, .trailing]).frame(width: corner, height: corner)
            }
            .overlay(alignment: .bottomLeading) {
                handle([.bottom, .leading]).frame(width: corner, height: corner)
            }
            .overlay(alignment: .bottomTrailing) {
                handle([.bottom, .trailing]).frame(width: corner, height: corner)
            }
    }

    private func handle(_ edges: Edge.Set) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { isInside in
                if isInside {
                    Self.cursor(for: edges).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in onResize?(edges, false) }
                    .onEnded { _ in onResize?(edges, true) }
            )
            .accessibilityHidden(true)
    }

    private static func cursor(for edges: Edge.Set) -> NSCursor {
        guard #available(macOS 15.0, *) else {
            return edges.contains(.leading) || edges.contains(.trailing)
                ? .resizeLeftRight
                : .resizeUpDown
        }
        let position: NSCursor.FrameResizePosition = switch edges {
        case [.top, .leading]: .topLeft
        case [.top, .trailing]: .topRight
        case [.bottom, .leading]: .bottomLeft
        case [.bottom, .trailing]: .bottomRight
        case .top: .top
        case .bottom: .bottom
        case .leading: .left
        default: .right
        }
        return .frameResize(position: position, directions: .all)
    }
}
