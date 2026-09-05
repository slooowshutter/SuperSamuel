import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    var onToggleRecording: (() -> Void)?
    var onCopyLastTranscript: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onMenuWillOpen: (() -> Void)?
    var onSendPendingRecording: ((UUID) -> Void)?
    var onDeletePendingRecording: ((UUID) -> Void)?
    var onRevealPendingRecording: ((UUID) -> Void)?
    var onCopyHistoryTranscript: ((UUID) -> Void)?
    var onRevealHistoryTranscript: ((UUID) -> Void)?
    var onClearTranscriptHistory: (() -> Void)?

    private let statusItem: NSStatusItem
    private let settings: SettingsStore

    private let toggleRecordingItem = NSMenuItem(
        title: "Start Recording (Option+Space)",
        action: nil,
        keyEquivalent: ""
    )
    private let pendingRecordingsItem = NSMenuItem(
        title: "Unsent Recordings",
        action: nil,
        keyEquivalent: ""
    )
    private let copyItem = NSMenuItem(
        title: "Copy Last Transcript",
        action: nil,
        keyEquivalent: ""
    )
    private let historyItem = NSMenuItem(
        title: "Transcript History",
        action: nil,
        keyEquivalent: ""
    )
    private let autoPasteItem = NSMenuItem(
        title: "Auto Paste Result",
        action: nil,
        keyEquivalent: ""
    )
    private let restoreClipboardItem = NSMenuItem(
        title: "Restore Clipboard",
        action: nil,
        keyEquivalent: ""
    )
    private let openSettingsItem = NSMenuItem(
        title: "Settings...",
        action: nil,
        keyEquivalent: ","
    )
    private let openAccessibilityItem = NSMenuItem(
        title: "Open Accessibility Settings",
        action: nil,
        keyEquivalent: ""
    )
    private let quitItem = NSMenuItem(
        title: "Quit SuperSamuel",
        action: nil,
        keyEquivalent: "q"
    )

    private var pendingRecordings: [PendingRecordingSummary] = []
    private var transcriptHistory: [TranscriptHistoryItem] = []

    init(settings: SettingsStore) {
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()
        configureMenu()
        updateStatusTitle(for: .idle)
    }

    func updateStatusTitle(for phase: DictationPhase) {
        guard let button = statusItem.button else {
            return
        }

        switch phase {
        case .idle:
            button.title = "SS"
            toggleRecordingItem.title = "Start Recording (Option+Space)"
        case .recording:
            button.title = "SS REC"
            toggleRecordingItem.title = "Stop Recording (Option+Space)"
        case .transcribing:
            button.title = "SS ..."
            toggleRecordingItem.title = "Cancel Transcription (Option+Space)"
        case .error:
            button.title = "SS ERR"
            toggleRecordingItem.title = "Start Recording (Option+Space)"
        }
    }

    func updatePendingRecordings(_ recordings: [PendingRecordingSummary]) {
        pendingRecordings = recordings
        rebuildPendingRecordingsMenu()
    }

    func updateTranscriptHistory(_ history: [TranscriptHistoryItem]) {
        transcriptHistory = history
        rebuildTranscriptHistoryMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
        refreshCheckmarks()
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self

        toggleRecordingItem.target = self
        toggleRecordingItem.action = #selector(handleToggleRecording)

        copyItem.target = self
        copyItem.action = #selector(handleCopyLastTranscript)

        autoPasteItem.target = self
        autoPasteItem.action = #selector(handleToggleAutoPaste)

        restoreClipboardItem.target = self
        restoreClipboardItem.action = #selector(handleToggleRestoreClipboard)

        openSettingsItem.target = self
        openSettingsItem.action = #selector(handleOpenSettings)

        openAccessibilityItem.target = self
        openAccessibilityItem.action = #selector(handleOpenAccessibility)

        quitItem.target = self
        quitItem.action = #selector(handleQuit)

        menu.addItem(toggleRecordingItem)
        menu.addItem(pendingRecordingsItem)
        menu.addItem(copyItem)
        menu.addItem(historyItem)
        menu.addItem(.separator())
        menu.addItem(autoPasteItem)
        menu.addItem(restoreClipboardItem)
        menu.addItem(.separator())
        menu.addItem(openSettingsItem)
        menu.addItem(openAccessibilityItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshCheckmarks()
        rebuildPendingRecordingsMenu()
        rebuildTranscriptHistoryMenu()
    }

    private func rebuildPendingRecordingsMenu() {
        pendingRecordingsItem.isHidden = pendingRecordings.isEmpty
        pendingRecordingsItem.title =
            "Unsent Recordings (\(pendingRecordings.count))"

        let menu = NSMenu()
        for recording in pendingRecordings {
            let recordingItem = NSMenuItem(
                title: pendingRecordingTitle(recording),
                action: nil,
                keyEquivalent: ""
            )
            let actions = NSMenu()

            if let error = recording.lastError, !error.isEmpty {
                let errorItem = NSMenuItem(
                    title: shortened(error, maximumLength: 80),
                    action: nil,
                    keyEquivalent: ""
                )
                errorItem.isEnabled = false
                actions.addItem(errorItem)
                actions.addItem(.separator())
            }

            let sendItem = NSMenuItem(
                title: "Send Recording",
                action: #selector(handleSendPendingRecording(_:)),
                keyEquivalent: ""
            )
            sendItem.target = self
            sendItem.representedObject = recording.id.uuidString
            actions.addItem(sendItem)

            let revealItem = NSMenuItem(
                title: "Reveal in Finder",
                action: #selector(handleRevealPendingRecording(_:)),
                keyEquivalent: ""
            )
            revealItem.target = self
            revealItem.representedObject = recording.id.uuidString
            actions.addItem(revealItem)

            let deleteItem = NSMenuItem(
                title: "Move Recording to Trash",
                action: #selector(handleDeletePendingRecording(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = recording.id.uuidString
            actions.addItem(deleteItem)

            recordingItem.submenu = actions
            menu.addItem(recordingItem)
        }

        pendingRecordingsItem.submenu = menu
    }

    private func rebuildTranscriptHistoryMenu() {
        let menu = NSMenu()

        if transcriptHistory.isEmpty {
            let emptyItem = NSMenuItem(
                title: "No saved transcripts",
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for transcript in transcriptHistory {
                let item = NSMenuItem(
                    title: transcriptTitle(transcript),
                    action: nil,
                    keyEquivalent: ""
                )
                item.toolTip = transcript.text
                let actions = NSMenu()

                let copyItem = NSMenuItem(
                    title: "Copy Transcript",
                    action: #selector(handleCopyHistoryTranscript(_:)),
                    keyEquivalent: ""
                )
                copyItem.target = self
                copyItem.representedObject = transcript.id.uuidString
                actions.addItem(copyItem)

                let revealItem = NSMenuItem(
                    title: "Reveal Recording and Transcript in Finder",
                    action: #selector(handleRevealHistoryTranscript(_:)),
                    keyEquivalent: ""
                )
                revealItem.target = self
                revealItem.representedObject = transcript.id.uuidString
                actions.addItem(revealItem)

                item.submenu = actions
                menu.addItem(item)
            }

            menu.addItem(.separator())
            let clearItem = NSMenuItem(
                title: "Clear Transcript History...",
                action: #selector(handleClearTranscriptHistory),
                keyEquivalent: ""
            )
            clearItem.target = self
            menu.addItem(clearItem)
        }

        historyItem.submenu = menu
    }

    private func refreshCheckmarks() {
        autoPasteItem.state = settings.autoPaste ? .on : .off
        restoreClipboardItem.state = settings.restoreClipboard ? .on : .off
        restoreClipboardItem.isEnabled = settings.autoPaste
    }

    private func pendingRecordingTitle(
        _ recording: PendingRecordingSummary
    ) -> String {
        let date = Self.dateFormatter.string(from: recording.createdAt)
        let duration = Self.durationFormatter.string(
            from: recording.estimatedDuration
        ) ?? "0:00"
        let size = ByteCountFormatter.string(
            fromByteCount: recording.sizeBytes,
            countStyle: .file
        )
        return "\(date) • \(duration) • \(recording.chunkCount) parts • \(size)"
    }

    private func transcriptTitle(_ transcript: TranscriptHistoryItem) -> String {
        let date = Self.dateFormatter.string(from: transcript.createdAt)
        let singleLine = transcript.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(date) — \(shortened(singleLine, maximumLength: 70))"
    }

    private func shortened(_ text: String, maximumLength: Int) -> String {
        guard text.count > maximumLength else {
            return text
        }
        return String(text.prefix(maximumLength - 1)) + "…"
    }

    @objc
    private func handleToggleRecording() {
        onToggleRecording?()
    }

    @objc
    private func handleCopyLastTranscript() {
        onCopyLastTranscript?()
    }

    @objc
    private func handleToggleAutoPaste() {
        settings.autoPaste.toggle()
        refreshCheckmarks()
    }

    @objc
    private func handleToggleRestoreClipboard() {
        settings.restoreClipboard.toggle()
        refreshCheckmarks()
    }

    @objc
    private func handleOpenSettings() {
        onOpenSettings?()
    }

    @objc
    private func handleOpenAccessibility() {
        onOpenAccessibilitySettings?()
    }

    @objc
    private func handleSendPendingRecording(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID)
        else {
            return
        }
        onSendPendingRecording?(id)
    }

    @objc
    private func handleDeletePendingRecording(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID)
        else {
            return
        }
        onDeletePendingRecording?(id)
    }

    @objc
    private func handleRevealPendingRecording(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID)
        else {
            return
        }
        onRevealPendingRecording?(id)
    }

    @objc
    private func handleCopyHistoryTranscript(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID)
        else {
            return
        }
        onCopyHistoryTranscript?(id)
    }

    @objc
    private func handleRevealHistoryTranscript(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID)
        else {
            return
        }
        onRevealHistoryTranscript?(id)
    }

    @objc
    private func handleClearTranscriptHistory() {
        onClearTranscriptHistory?()
    }

    @objc
    private func handleQuit() {
        NSApp.terminate(nil)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}
