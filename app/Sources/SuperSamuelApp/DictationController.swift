import AppKit
import Foundation

private struct DeliveryOptions {
    let targetApplication: NSRunningApplication?
    let autoPaste: Bool
    let restoreClipboard: Bool
}

@MainActor
final class DictationController {
    private let appState = AppState()
    private let settings = SettingsStore()
    private let permissions = PermissionsService()
    private let hotkeyService = HotkeyService()
    private let audioCapture = AudioCaptureService()
    private let clipboard = ClipboardService()
    private let openRouterService = OpenRouterService()
    private let screenshotCapture = ScreenshotCaptureService()
    private let recordingStore = RecordingStore()
    private let historyStore = TranscriptHistoryStore()
    private lazy var textInsertion = TextInsertionService(clipboard: clipboard)
    private lazy var recordingProcessor = RecordingProcessor(
        recordingStore: recordingStore,
        historyStore: historyStore,
        openRouterService: openRouterService
    )

    private var overlayController: OverlayWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var menuBarController: MenuBarController?

    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var isStartingRecording = false
    private var hasDetectedMicrophoneSignal = false
    private var isShowingMicrophoneWarning = false
    private var lastTranscript = ""
    private var targetApplication: NSRunningApplication?
    private var activeRecordingID: UUID?
    private var activeInputDevice: AudioInputDeviceInfo?

    private var processingTask: Task<Void, Never>?
    private var processingSessionID: UUID?
    private var activeOperationID: UUID?
    private var errorResetTask: Task<Void, Never>?
    private var isRecoveryPromptVisible = false
    private var recoverySessionID: UUID?

    func start() {
        configureOverlay()
        configureMenuBar()
        removeRecordingCopiesAlreadyInHistory()
        try? recordingStore.recoverInterruptedSessions()

        if !hotkeyService.start(onTrigger: { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggleRecording()
            }
        }) {
            print("Failed to register global hotkey")
        }

        refreshPersistentMenus()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.presentOldestPendingRecording()
        }
    }

    func shutdown() {
        errorResetTask?.cancel()
        processingTask?.cancel()

        if let processingSessionID {
            try? recordingStore.markReady(
                processingSessionID,
                message: "Processing stopped because SuperSamuel quit."
            )
        }

        preserveActiveRecording(
            message: "Recording saved because SuperSamuel quit."
        )
        hotkeyService.stop()
        clearAttachedScreenshot()
    }

    private func configureOverlay() {
        let overlayController = OverlayWindowController(state: appState)
        overlayController.onStop = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleOverlayPrimaryAction()
            }
        }
        overlayController.onAttachScreenshot = { [weak self] in
            Task { @MainActor [weak self] in
                self?.captureScreenshot()
            }
        }
        overlayController.onClearScreenshot = { [weak self] in
            Task { @MainActor [weak self] in
                self?.clearAttachedScreenshot()
            }
        }
        overlayController.onRetry = { [weak self] in
            Task { @MainActor [weak self] in
                self?.retryRecoverableRecording()
            }
        }
        overlayController.onDelete = { [weak self] in
            Task { @MainActor [weak self] in
                self?.deleteRecoverableRecording()
            }
        }
        self.overlayController = overlayController
    }

    private func handleOverlayPrimaryAction() {
        if case .error = appState.phase {
            resetToIdle()
            return
        }

        toggleRecording()
    }

    private func configureMenuBar() {
        let menuBarController = MenuBarController(settings: settings)
        menuBarController.onToggleRecording = { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggleRecording()
            }
        }
        menuBarController.onCopyLastTranscript = { [weak self] in
            Task { @MainActor [weak self] in
                self?.copyLastTranscript()
            }
        }
        menuBarController.onOpenSettings = { [weak self] in
            Task { @MainActor [weak self] in
                self?.openSettings()
            }
        }
        menuBarController.onOpenAccessibilitySettings = { [weak self] in
            Task { @MainActor [weak self] in
                self?.openAccessibilitySettings()
            }
        }
        menuBarController.onMenuWillOpen = { [weak self] in
            self?.refreshPersistentMenus()
        }
        menuBarController.onSendPendingRecording = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.sendPendingRecording(id)
            }
        }
        menuBarController.onDeletePendingRecording = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.confirmAndDeletePendingRecording(id)
            }
        }
        menuBarController.onRevealPendingRecording = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.revealPendingRecording(id)
            }
        }
        menuBarController.onCopyHistoryTranscript = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.copyHistoryTranscript(id)
            }
        }
        menuBarController.onRevealHistoryTranscript = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.revealHistoryTranscript(id)
            }
        }
        menuBarController.onClearTranscriptHistory = { [weak self] in
            Task { @MainActor [weak self] in
                self?.confirmAndClearTranscriptHistory()
            }
        }
        self.menuBarController = menuBarController
    }

    private func toggleRecording() {
        switch appState.phase {
        case .idle, .error:
            if hasPendingRecordings() {
                presentOldestPendingRecording()
            } else {
                Task { await startRecording() }
            }
        case .recording:
            stopAndProcessRecording()
        case .transcribing, .enhancing:
            cancelProcessing()
        }
    }

    private func startRecording() async {
        guard
            !isStartingRecording,
            activeRecordingID == nil,
            processingTask == nil
        else {
            return
        }

        if hasPendingRecordings() {
            presentOldestPendingRecording()
            return
        }

        isStartingRecording = true
        errorResetTask?.cancel()
        errorResetTask = nil
        defer { isStartingRecording = false }

        do {
            guard settings.hasOpenRouterAPIKey else {
                throw OpenRouterServiceError.missingAPIKey
            }

            targetApplication = NSWorkspace.shared.frontmostApplication
            try await permissions.ensureMicrophonePermission()

            clearAttachedScreenshot()
            appState.enhancementEnabled = settings.enhancementEnabledByDefault

            let session = try recordingStore.createSession(
                cleanup: currentEnhancementOptions(),
                transcriptionModel: settings.transcriptionModel
            )
            let chunkURL = try recordingStore.beginChunk(in: session.id)

            do {
                let inputDevice = try audioCapture.start(at: chunkURL)
                try recordingStore.setInputDevice(
                    inputDevice,
                    for: session.id
                )
                activeInputDevice = inputDevice
            } catch {
                _ = audioCapture.stopIfNeeded()
                try? recordingStore.deleteSession(session.id)
                refreshPersistentMenus()
                throw error
            }

            activeRecordingID = session.id
            startedAt = Date()
            hasDetectedMicrophoneSignal = false
            isShowingMicrophoneWarning = false
            startElapsedTimer()
            appState.resetForRecording(
                deviceName: activeInputDevice?.name ??
                    "System Default Microphone"
            )
            overlayController?.show()
            menuBarController?.updateStatusTitle(for: .recording)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func stopAndProcessRecording() {
        guard let sessionID = activeRecordingID else {
            return
        }

        let pasteTarget = currentPasteTarget()
        do {
            try finishCurrentChunk(sessionID: sessionID)
            try recordingStore.prepareForProcessing(
                sessionID: sessionID,
                cleanup: currentEnhancementOptions(),
                transcriptionModel: settings.transcriptionModel,
                screenshotSourceURL: appState.attachedScreenshot?.fileURL
            )
        } catch {
            try? recordingStore.markFailed(
                sessionID,
                message: error.localizedDescription
            )
            activeRecordingID = nil
            stopElapsedTimer()
            clearAttachedScreenshot()
            refreshPersistentMenus()
            recoverySessionID = sessionID
            showError(
                error.localizedDescription,
                recoverable: true
            )
            return
        }

        activeRecordingID = nil
        stopElapsedTimer()
        clearAttachedScreenshot()
        refreshPersistentMenus()

        processSavedRecording(
            sessionID,
            delivery: DeliveryOptions(
                targetApplication: pasteTarget,
                autoPaste: settings.autoPaste,
                restoreClipboard: settings.restoreClipboard
            )
        )
    }

    private func finishCurrentChunk(sessionID: UUID) throws {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        _ = try audioCapture.stop()
        try recordingStore.finishCurrentChunk(
            in: sessionID,
            duration: duration
        )
    }

    private func preserveActiveRecording(message: String) {
        guard let sessionID = activeRecordingID else {
            stopElapsedTimer()
            return
        }

        if audioCapture.isRecording {
            do {
                try finishCurrentChunk(sessionID: sessionID)
            } catch {
                print("Could not finalize saved recording: \(error.localizedDescription)")
            }
        }

        do {
            try recordingStore.prepareForProcessing(
                sessionID: sessionID,
                cleanup: currentEnhancementOptions(),
                transcriptionModel: settings.transcriptionModel,
                screenshotSourceURL: appState.attachedScreenshot?.fileURL
            )
            try recordingStore.markFailed(sessionID, message: message)
        } catch {
            print("Could not update saved recording metadata: \(error.localizedDescription)")
        }

        activeRecordingID = nil
        stopElapsedTimer()
        refreshPersistentMenus()
    }

    private func processSavedRecording(
        _ sessionID: UUID,
        delivery: DeliveryOptions
    ) {
        guard processingTask == nil, activeRecordingID == nil else {
            return
        }

        do {
            guard settings.hasOpenRouterAPIKey else {
                throw OpenRouterServiceError.missingAPIKey
            }
            try recordingStore.markProcessing(sessionID)
        } catch {
            try? recordingStore.markFailed(
                sessionID,
                message: error.localizedDescription
            )
            refreshPersistentMenus()
            showError(error.localizedDescription)
            return
        }

        let operationID = UUID()
        activeOperationID = operationID
        processingSessionID = sessionID
        appState.setPhase(.transcribing)
        appState.setProgressMessage("Preparing saved recording...")
        overlayController?.show()
        menuBarController?.updateStatusTitle(for: .transcribing)
        refreshPersistentMenus()

        processingTask = Task { [weak self] in
            await self?.process(
                sessionID: sessionID,
                delivery: delivery,
                operationID: operationID
            )
        }
    }

    private func process(
        sessionID: UUID,
        delivery: DeliveryOptions,
        operationID: UUID
    ) async {
        do {
            let result = try await recordingProcessor.process(
                sessionID: sessionID,
                apiKey: settings.openRouterAPIKey
            ) { [weak self] progress in
                self?.showProcessingProgress(progress)
            }

            try Task.checkCancellation()
            guard isCurrentOperation(operationID) else {
                return
            }

            completeOperation(
                transcript: result.transcript,
                delivery: delivery
            )
        } catch {
            guard isCurrentOperation(operationID) else {
                return
            }

            let message: String
            if isCancellation(error) {
                message = "Processing cancelled. The recording was kept."
                try? recordingStore.markReady(sessionID, message: message)
                resetToIdle()
            } else {
                message = error.localizedDescription
                try? recordingStore.markFailed(sessionID, message: message)
                recoverySessionID = sessionID
                showError(message, recoverable: true)
            }

            activeOperationID = nil
            processingTask = nil
            processingSessionID = nil
            refreshPersistentMenus()
        }
    }

    private func showProcessingProgress(
        _ progress: RecordingProcessingProgress
    ) {
        let phase: DictationPhase
        let action: String
        switch progress.stage {
        case .transcribing:
            phase = .transcribing
            action = "Transcribing"
        case .enhancing:
            phase = .enhancing
            action = "Enhancing"
        }

        appState.setPhase(phase)
        appState.setProgressMessage(
            "\(action) part \(progress.currentPart) of \(progress.totalParts)..."
        )
        if !progress.transcriptPreview.isEmpty {
            appState.setTranscriptPreview(fullText: progress.transcriptPreview)
        }
        menuBarController?.updateStatusTitle(for: phase)
    }

    private func completeOperation(
        transcript: String,
        delivery: DeliveryOptions
    ) {
        activeOperationID = nil
        processingTask = nil
        processingSessionID = nil
        targetApplication = nil
        lastTranscript = transcript
        appState.setTranscriptPreview(fullText: transcript)
        overlayController?.hide()

        let canAutoPaste = delivery.autoPaste &&
            permissions.hasAccessibilityPermission(prompt: false)
        textInsertion.deliver(
            text: transcript,
            targetApplication: delivery.targetApplication,
            autoPaste: canAutoPaste,
            restoreClipboard: delivery.restoreClipboard
        )

        appState.setPhase(.idle)
        appState.setElapsed(seconds: 0)
        menuBarController?.updateStatusTitle(for: .idle)
        refreshPersistentMenus()
    }

    private func cancelProcessing() {
        let sessionID = processingSessionID
        activeOperationID = nil
        processingTask?.cancel()
        processingTask = nil
        processingSessionID = nil

        if let sessionID {
            try? recordingStore.markReady(
                sessionID,
                message: "Processing cancelled. The recording was kept."
            )
        }

        refreshPersistentMenus()
        resetToIdle()
    }

    private func retryRecoverableRecording() {
        guard let recoverySessionID else {
            return
        }

        self.recoverySessionID = nil
        appState.showsRecoveryActions = false
        resetToIdle()
        sendPendingRecording(recoverySessionID)
    }

    private func deleteRecoverableRecording() {
        guard let recoverySessionID else {
            return
        }
        confirmAndDeletePendingRecording(recoverySessionID)
    }

    private func sendPendingRecording(
        _ sessionID: UUID,
        targetApplication: NSRunningApplication? = nil
    ) {
        guard appState.phase == .idle || isErrorPhase else {
            return
        }

        errorResetTask?.cancel()
        resetToIdle()
        processSavedRecording(
            sessionID,
            delivery: DeliveryOptions(
                targetApplication: targetApplication ?? currentPasteTarget(),
                autoPaste: settings.autoPaste,
                restoreClipboard: settings.restoreClipboard
            )
        )
    }

    private func confirmAndDeletePendingRecording(_ sessionID: UUID) {
        guard processingSessionID != sessionID else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Move this saved recording to Trash?"
        alert.informativeText =
            "The audio and any cached partial transcript can be recovered from Trash until it is emptied."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            try recordingStore.trashSession(sessionID)
            refreshPersistentMenus()
            resetToIdle()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func revealPendingRecording(_ sessionID: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([
            recordingStore.directoryURL(for: sessionID)
        ])
    }

    private func removeRecordingCopiesAlreadyInHistory() {
        guard let sessions = try? recordingStore.pendingSessions() else {
            return
        }

        for session in sessions {
            guard (try? historyStore.item(id: session.id)) != nil else {
                continue
            }
            try? recordingStore.deleteSession(session.id)
        }
    }

    private func presentOldestPendingRecording() {
        guard
            !isRecoveryPromptVisible,
            activeRecordingID == nil,
            processingTask == nil
        else {
            return
        }

        let summaries: [PendingRecordingSummary]
        do {
            summaries = try recordingStore.summaries()
        } catch {
            showError(error.localizedDescription)
            return
        }

        guard let recording = summaries.first else {
            return
        }

        isRecoveryPromptVisible = true
        defer { isRecoveryPromptVisible = false }

        let alert = NSAlert()
        alert.messageText = "Unsent recording found"
        alert.informativeText = recoveryDescription(recording)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Send Recording")
        alert.addButton(withTitle: "Keep for Later")
        alert.addButton(withTitle: "Move to Trash")
        alert.buttons.last?.hasDestructiveAction = true

        let pasteTarget = currentPasteTarget()
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            sendPendingRecording(
                recording.id,
                targetApplication: pasteTarget
            )
        case .alertThirdButtonReturn:
            confirmAndDeletePendingRecording(recording.id)
        default:
            break
        }
    }

    private func recoveryDescription(
        _ recording: PendingRecordingSummary
    ) -> String {
        let date = DateFormatter.localizedString(
            from: recording.createdAt,
            dateStyle: .medium,
            timeStyle: .short
        )
        let size = ByteCountFormatter.string(
            fromByteCount: recording.sizeBytes,
            countStyle: .file
        )
        let duration = formattedDuration(recording.estimatedDuration)
        let error = recording.lastError.map { "\n\nLast error: \($0)" } ?? ""
        let input = recording.inputDeviceName.map {
            "\nInput: \($0)"
        } ?? ""

        return """
        Recorded \(date)
        Duration: \(duration)
        Audio: \(recording.chunkCount) saved parts, \(size)\(input)

        New recordings are blocked until saved recordings are sent or deleted.\(error)
        """
    }

    private func copyHistoryTranscript(_ id: UUID) {
        do {
            guard let item = try historyStore.item(id: id) else {
                return
            }
            clipboard.setString(item.text)
            lastTranscript = item.text
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func revealHistoryTranscript(_ id: UUID) {
        guard let url = historyStore.artifactURL(for: id) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func confirmAndClearTranscriptHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear transcript history?"
        alert.informativeText =
            "This permanently deletes every archived recording, transcript, " +
            "and metadata file. Pending unsent recordings are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            try historyStore.clear()
            lastTranscript = ""
            refreshPersistentMenus()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func refreshPersistentMenus() {
        do {
            let pending = try recordingStore.summaries()
            let history = try historyStore.recent()
            let hiddenIDs = Set(
                [activeRecordingID, processingSessionID].compactMap { $0 }
            )
            menuBarController?.updatePendingRecordings(
                pending.filter { !hiddenIDs.contains($0.id) }
            )
            menuBarController?.updateTranscriptHistory(history)

            if lastTranscript.isEmpty, let mostRecent = history.first {
                lastTranscript = mostRecent.text
            }
        } catch {
            print("Could not refresh saved data: \(error.localizedDescription)")
        }
    }

    private func hasPendingRecordings() -> Bool {
        do {
            return try !recordingStore.pendingSessions().isEmpty
        } catch {
            showError(error.localizedDescription)
            return true
        }
    }

    private var isErrorPhase: Bool {
        if case .error = appState.phase {
            return true
        }
        return false
    }

    private func currentEnhancementOptions() -> PersistedCleanupOptions {
        PersistedCleanupOptions(
            isEnabled: appState.enhancementEnabled,
            model: settings.enhancementModel,
            prompt: settings.enhancementPrompt,
            mode: .audioEnhancement
        )
    }

    private func resetToIdle() {
        activeOperationID = nil
        processingTask = nil
        processingSessionID = nil
        stopElapsedTimer()
        targetApplication = nil
        activeInputDevice = nil
        appState.recordingDeviceName = nil
        clearAttachedScreenshot()
        overlayController?.hide()
        appState.setPhase(.idle)
        appState.showsRecoveryActions = false
        recoverySessionID = nil
        appState.setElapsed(seconds: 0)
        menuBarController?.updateStatusTitle(for: .idle)
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        return (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    let startedAt = self.startedAt,
                    self.appState.phase == .recording
                else {
                    return
                }

                self.appState.setElapsed(
                    seconds: Date().timeIntervalSince(startedAt)
                )
                let level = self.audioCapture.currentLevel()
                self.appState.pushLevel(level)
                self.updateMicrophoneSignalStatus(
                    level: level,
                    elapsed: self.appState.elapsedSeconds
                )
            }
        }
    }

    private func updateMicrophoneSignalStatus(
        level: Float,
        elapsed: TimeInterval
    ) {
        if level >= 0.025 {
            hasDetectedMicrophoneSignal = true
            if isShowingMicrophoneWarning {
                isShowingMicrophoneWarning = false
                appState.setProgressMessage("Recording locally...")
            }
            return
        }

        guard
            elapsed >= 5,
            !hasDetectedMicrophoneSignal,
            !isShowingMicrophoneWarning
        else {
            return
        }

        isShowingMicrophoneWarning = true
        appState.setProgressMessage(
            "No recorded signal from \(activeInputDevice?.name ?? "the selected microphone") — check your input device."
        )
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startedAt = nil
        hasDetectedMicrophoneSignal = false
        isShowingMicrophoneWarning = false
        activeInputDevice = nil
    }

    private func currentPasteTarget() -> NSRunningApplication? {
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != currentProcessIdentifier
        {
            return frontmostApplication
        }

        if let targetApplication,
           targetApplication.processIdentifier != currentProcessIdentifier
        {
            return targetApplication
        }

        return nil
    }

    private func copyLastTranscript() {
        let transcript = lastTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !transcript.isEmpty else {
            return
        }
        clipboard.setString(transcript)
    }

    private func openAccessibilitySettings() {
        _ = permissions.hasAccessibilityPermission(prompt: true)
        permissions.openAccessibilitySettings()
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings)
        }
        settingsWindowController?.show()
    }

    private func captureScreenshot() {
        guard appState.phase == .recording, !appState.isCapturingScreenshot else {
            return
        }

        appState.isCapturingScreenshot = true
        appState.screenshotStatusMessage = nil
        defer { appState.isCapturingScreenshot = false }

        do {
            try permissions.ensureScreenRecordingPermission(prompt: true)
        } catch {
            appState.screenshotStatusMessage =
                "\(error.localizedDescription) Enable it in System Settings, then retake."
            return
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let candidates = [NSWorkspace.shared.frontmostApplication, targetApplication]
            .compactMap { $0 }
            .filter { $0.processIdentifier != currentProcessIdentifier }
            .reduce(into: [NSRunningApplication]()) { applications, application in
                if !applications.contains(where: {
                    $0.processIdentifier == application.processIdentifier
                }) {
                    applications.append(application)
                }
            }

        var lastError: Error?
        for application in candidates {
            do {
                let attachment = try screenshotCapture.captureWindow(for: application)
                let previousAttachment = appState.attachedScreenshot
                appState.attachedScreenshot = attachment
                screenshotCapture.remove(previousAttachment)
                return
            } catch {
                lastError = error
            }
        }

        appState.screenshotStatusMessage =
            lastError?.localizedDescription ?? "Could not attach a screenshot."
    }

    private func clearAttachedScreenshot() {
        screenshotCapture.remove(appState.attachedScreenshot)
        appState.attachedScreenshot = nil
        appState.screenshotStatusMessage = nil
        appState.isCapturingScreenshot = false
    }

    private func showError(
        _ message: String,
        recoverable: Bool = false
    ) {
        stopElapsedTimer()
        targetApplication = nil
        clearAttachedScreenshot()
        appState.setPhase(.error(message))
        appState.setProgressMessage(message)
        appState.showsRecoveryActions = recoverable
        menuBarController?.updateStatusTitle(for: .error(message))
        overlayController?.show()

        errorResetTask?.cancel()
        guard !recoverable else {
            return
        }

        errorResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            self?.resetToIdle()
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
