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
    private let settings: SettingsStore
    private let permissions = PermissionsService()
    private let hotkeyService = HotkeyService()
    private let audioCapture: AudioCaptureService
    private let realtimeAudioCapture = RealtimeAudioCaptureService()
    private let clipboard = ClipboardService()
    private let openRouterService = OpenRouterService()
    private let screenshotCapture = ScreenshotCaptureService()
    private let recordingStore: RecordingStore
    private let microphonePermission: (() async throws -> Void)?
    private let historyStore: TranscriptHistoryStore
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
    private var realtimeSession: RealtimeTranscriptionService?
    private var realtimeStartTask: Task<Void, Never>?
    private var liveContextAttachmentID: UUID?
    private var recordingConfiguration: RecordingConfiguration?
    private var liveCaptureContinuous = true
    private var savedCaptureContinuous = true
    private var liveAudioDuration: TimeInterval = 0
    private var nextMicrophoneRecoveryAt = Date.distantPast
    private var persistentMenuRefreshTask: Task<Void, Never>?

    private struct RecordingConfiguration {
        let model: String
        let context: String
        let vocabulary: [String]
        let delay: TranscriptionDelay
        let cleanup: TranscriptCleanupConfiguration?
    }

    private var processingTask: Task<Void, Never>?
    private var processingSessionID: UUID?
    private var activeOperationID: UUID?
    private var errorResetTask: Task<Void, Never>?
    private var isRecoveryPromptVisible = false
    private var recoverySessionID: UUID?

    init(
        settings: SettingsStore? = nil,
        recordingStore: RecordingStore? = nil,
        historyStore: TranscriptHistoryStore? = nil,
        audioCapture: AudioCaptureService? = nil,
        microphonePermission: (() async throws -> Void)? = nil
    ) {
        self.settings = settings ?? SettingsStore()
        self.recordingStore = recordingStore ?? RecordingStore()
        self.historyStore = historyStore ?? TranscriptHistoryStore()
        self.audioCapture = audioCapture ?? AudioCaptureService()
        self.microphonePermission = microphonePermission
    }

    func start() {
        configureOverlay()
        configureMenuBar()
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
        cancelActiveRealtimeTranscription()

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
        if appState.phase == .idle {
            resetToIdle()
            return
        }
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
                self?.deletePendingRecording(id)
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
            Task { await startRecording() }
        case .recording:
            stopAndProcessRecording()
        case .transcribing:
            cancelProcessing()
        }
    }

    func startRecording() async {
        guard
            !isStartingRecording,
            activeRecordingID == nil,
            processingTask == nil
        else {
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
            if let microphonePermission {
                try await microphonePermission()
            } else {
                try await permissions.ensureMicrophonePermission()
            }
            guard !Task.isCancelled, activeRecordingID == nil, processingTask == nil else { return }

            clearAttachedScreenshot()

            let configuration = RecordingConfiguration(
                model: settings.transcriptionModel,
                context: "",
                vocabulary: settings.personalDictionary,
                delay: settings.transcriptionDelay,
                cleanup: settings.cleanupConfiguration
            )
            recordingConfiguration = configuration
            liveCaptureContinuous = true
            savedCaptureContinuous = true
            liveAudioDuration = 0
            let session = try recordingStore.createSession(
                transcriptionModel: configuration.model,
                transcriptionContext: configuration.context,
                vocabulary: configuration.vocabulary,
                liveTranscriptionModel: settings.canUseRealtimeGPTTranscribe
                    ? RealtimeTranscriptionService.transcriptionModel : nil,
                liveTranscriptionDelay: settings.canUseRealtimeGPTTranscribe
                    ? configuration.delay.rawValue : nil,
                cleanup: configuration.cleanup
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
                try? recordingStore.finishCurrentChunk(in: session.id, duration: audioCapture.recordedDuration)
                try? recordingStore.markFailed(session.id, message: error.localizedDescription)
                refreshPersistentMenus()
                throw error
            }

            recoverySessionID = nil
            activeRecordingID = session.id
            startedAt = Date()
            hasDetectedMicrophoneSignal = false
            isShowingMicrophoneWarning = false
            nextMicrophoneRecoveryAt = .distantPast
            startElapsedTimer()
            appState.resetForRecording(
                deviceName: activeInputDevice?.name ??
                    "System Default Microphone"
            )
            overlayController?.show()
            menuBarController?.updateStatusTitle(for: .recording)
            startRealtimeTranscriptionIfAvailable(sessionID: session.id)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func stopAndProcessRecording() {
        guard let sessionID = activeRecordingID else {
            return
        }

        if case .interrupted(let message) = audioCapture.checkHealth() {
            savedCaptureContinuous = false
            appState.captureStatusMessage = message
        }
        if let attachment = appState.attachedScreenshot,
           liveContextAttachmentID != attachment.id {
            liveCaptureContinuous = false
        }
        let realtimeSession = detachActiveRealtimeSession()
        let pasteTarget = currentPasteTarget()
        do {
            try finishCurrentChunk(sessionID: sessionID)
            try recordingStore.prepareForProcessing(
                sessionID: sessionID,
                transcriptionModel: recordingConfiguration?.model ?? settings.transcriptionModel,
                transcriptionContext: recordingConfiguration?.context ?? "",
                vocabulary: recordingConfiguration?.vocabulary ?? settings.personalDictionary,
                cleanup: recordingConfiguration == nil ? settings.cleanupConfiguration : recordingConfiguration?.cleanup,
                screenshotSourceURL: appState.attachedScreenshot?.fileURL
            )
        } catch {
            realtimeSession?.cancel()
            if case AudioCaptureError.emptyRecording = error,
               savedCaptureContinuous,
               let startedAt, Date().timeIntervalSince(startedAt) < 0.15 {
                try? recordingStore.markReady(sessionID, message: "Recording was too short. The saved audio was kept.")
                activeRecordingID = nil
                resetToIdle()
                refreshPersistentMenus()
                return
            }
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
            realtimeSession: realtimeSession,
            delivery: DeliveryOptions(
                targetApplication: pasteTarget,
                autoPaste: settings.autoPaste,
                restoreClipboard: settings.restoreClipboard
            )
        )
    }

    private func finishCurrentChunk(sessionID: UUID) throws {
        var stopError: Error?
        if audioCapture.hasActiveRecording {
            do { _ = try audioCapture.stop() } catch { stopError = error }
            try recordingStore.finishCurrentChunk(
                in: sessionID,
                duration: audioCapture.recordedDuration
            )
        }
        // Allow AAC priming and one capture buffer of scheduling skew. Larger gaps
        // include a slow sidecar startup or missed PCM, even if the engine recovered.
        if audioCapture.recordedDuration - liveAudioDuration > 0.15 {
            liveCaptureContinuous = false
        }
        try recordingStore.setCaptureContinuity(
            live: liveCaptureContinuous,
            saved: savedCaptureContinuous,
            for: sessionID
        )
        if let stopError { throw stopError }
    }

    private func startRealtimeTranscriptionIfAvailable(sessionID: UUID) {
        switch settings.realtimeTranscriptionAvailability {
        case .available:
            break
        case .missingOpenAIAPIKey:
            appState.setProgressMessage(
                "Live transcription needs a separate OpenAI API key in Settings. Recording locally..."
            )
            return
        case .disabled:
            return
        }

        let service = RealtimeTranscriptionService { [weak self] transcript in
            guard let self else {
                return
            }
            guard self.activeRecordingID == sessionID ||
                    self.processingSessionID == sessionID
            else {
                return
            }
            self.appState.setTranscriptPreview(fullText: transcript)
        }
        realtimeSession = service
        appState.setProgressMessage("Listening for live transcription...")

        realtimeAudioCapture.onDiscontinuity = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.activeRecordingID == sessionID else { return }
                self.liveCaptureContinuous = false
                self.appState.captureStatusMessage = "Live audio interrupted. The saved recording will be transcribed. \(message)"
            }
        }
        do {
            try realtimeAudioCapture.start { [weak self] data in
                guard let self, self.activeRecordingID == sessionID else { return }
                self.liveAudioDuration += Double(data.count) / (24_000 * 2)
                self.realtimeSession?.appendAudio(data)
            }
        } catch {
            realtimeSession = nil
            liveCaptureContinuous = false
            service.cancel()
            appState.captureStatusMessage = "Live audio unavailable. The saved recording will be used. \(error.localizedDescription)"
            appState.setProgressMessage("Recording locally...")
            print(
                "Realtime audio sidecar unavailable; recording locally: " +
                    error.localizedDescription
            )
            return
        }

        let apiKey = settings.openAIAPIKey
        let context = recordingConfiguration?.context ?? ""
        let delay = recordingConfiguration?.delay ?? settings.transcriptionDelay
        let keywords = recordingConfiguration?.vocabulary ?? settings.personalDictionary
        appState.liveInstructionsShortened = !RealtimeTranscriptionService.contextIsValid(context)
        realtimeStartTask = Task { @MainActor [weak self, weak service] in
            guard let service else {
                return
            }
            do {
                try await service.start(
                    apiKey: apiKey,
                    transcriptionContext: context,
                    delay: delay,
                    keywords: keywords
                )
            } catch {
                service.cancel()
                guard let self, self.realtimeSession === service else {
                    return
                }
                self.realtimeAudioCapture.stop()
                self.realtimeSession = nil
                self.realtimeStartTask = nil
                if self.activeRecordingID == sessionID {
                    self.liveCaptureContinuous = false
                    self.appState.captureStatusMessage = "Live transcription unavailable. The saved recording will be used. \(error.localizedDescription)"
                    self.appState.setProgressMessage("Recording locally...")
                }
                print(
                    "Realtime connection unavailable; recording locally: " +
                        error.localizedDescription
                )
            }
        }
    }

    private func detachActiveRealtimeSession() -> RealtimeTranscriptionService? {
        realtimeAudioCapture.stop()
        liveCaptureContinuous = liveCaptureContinuous && !realtimeAudioCapture.hasDiscontinuity
        let service = realtimeSession
        realtimeSession = nil
        realtimeStartTask = nil
        return service
    }

    private func cancelActiveRealtimeTranscription() {
        realtimeAudioCapture.stop()
        realtimeStartTask?.cancel()
        realtimeStartTask = nil
        realtimeSession?.cancel()
        realtimeSession = nil
    }

    private func preserveActiveRecording(message: String) {
        guard let sessionID = activeRecordingID else {
            stopElapsedTimer()
            return
        }

        cancelActiveRealtimeTranscription()

        if audioCapture.hasActiveRecording {
            do {
                try finishCurrentChunk(sessionID: sessionID)
            } catch {
                print("Could not finalize saved recording: \(error.localizedDescription)")
            }
        }

        do {
            try recordingStore.prepareForProcessing(
                sessionID: sessionID,
                transcriptionModel: recordingConfiguration?.model ?? settings.transcriptionModel,
                transcriptionContext: recordingConfiguration?.context ?? "",
                vocabulary: recordingConfiguration?.vocabulary ?? settings.personalDictionary,
                cleanup: recordingConfiguration == nil ? settings.cleanupConfiguration : recordingConfiguration?.cleanup,
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
        realtimeSession: RealtimeTranscriptionService? = nil,
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
                realtimeSession: realtimeSession,
                delivery: delivery,
                operationID: operationID
            )
        }
    }

    private func process(
        sessionID: UUID,
        realtimeSession: RealtimeTranscriptionService?,
        delivery: DeliveryOptions,
        operationID: UUID
    ) async {
        do {
            var realtimeTranscript: String?
            let savedSession = try recordingStore.load(sessionID)
            if let realtimeSession,
               !savedSession.canUseLiveTranscript || savedSession.savedCaptureContinuous == false {
                try? recordingStore.saveLivePartialTranscript(realtimeSession.currentTranscript, sessionID: sessionID)
                realtimeSession.cancel()
                appState.setProgressMessage(savedSession.livePreviewRequiresFinalization == true
                    ? "Applying your full instructions to the saved recording..."
                    : "Transcribing the saved recording...")
            } else if let realtimeSession {
                appState.setProgressMessage("Finishing live transcript...")
                do {
                    let finishedTranscript = try await realtimeSession.finish()
                    let session = try recordingStore.load(sessionID)
                    if session.canUseLiveTranscript {
                        realtimeTranscript = finishedTranscript
                    }
                } catch is CancellationError {
                    realtimeSession.cancel()
                    throw CancellationError()
                } catch {
                    try? recordingStore.saveLivePartialTranscript(realtimeSession.currentTranscript, sessionID: sessionID)
                    realtimeSession.cancel()
                    print(
                        "Realtime transcription unavailable; using saved recording: " +
                            error.localizedDescription
                    )
                    appState.setProgressMessage(
                        "Realtime unavailable. Transcribing saved recording..."
                    )
                }
            }

            let result = try await recordingProcessor.process(
                sessionID: sessionID,
                apiKey: settings.openRouterAPIKey,
                preferredTranscript: realtimeTranscript
            ) { [weak self] progress in
                guard self?.isCurrentOperation(operationID) == true else { return }
                self?.showProcessingProgress(progress)
            }

            try Task.checkCancellation()
            guard isCurrentOperation(operationID) else {
                return
            }

            completeOperation(
                transcript: result.transcript,
                captureWarning: result.captureWarning,
                delivery: delivery
            )
        } catch {
            guard isCurrentOperation(operationID) else {
                return
            }

            let message: String
            if case OpenRouterServiceError.noSpeechDetected = error {
                try? recordingStore.markReady(
                    sessionID,
                    message: "No speech detected. The saved audio remains available."
                )
                resetToIdle()
                appState.setProgressMessage("No speech detected. Ready to record.")
            } else if isCancellation(error) {
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
        appState.setPhase(.transcribing)
        appState.processingStatusMessage = progress.stage == .cleaningUp ? "Cleaning up transcript..." : "Transcribing"
        appState.setProgressMessage(
            progress.stage == .cleaningUp ? "Cleaning up transcript..."
                : "Transcribing part \(progress.currentPart) of \(progress.totalParts)..."
        )
        if !progress.transcriptPreview.isEmpty {
            appState.setTranscriptPreview(fullText: progress.transcriptPreview)
        }
        menuBarController?.updateStatusTitle(for: .transcribing)
    }

    private func completeOperation(
        transcript: String,
        captureWarning: String?,
        delivery: DeliveryOptions
    ) {
        activeOperationID = nil
        processingTask = nil
        processingSessionID = nil
        targetApplication = nil
        lastTranscript = transcript
        appState.setTranscriptPreview(fullText: transcript)
        appState.captureStatusMessage = captureWarning
        appState.showsRecoveryActions = false

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
        if captureWarning != nil {
            overlayController?.show()
        } else {
            overlayController?.hide()
        }
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
        deletePendingRecording(recoverySessionID)
    }

    private func sendPendingRecording(
        _ sessionID: UUID,
        targetApplication: NSRunningApplication? = nil
    ) {
        guard !isStartingRecording, appState.phase == .idle || isErrorPhase else {
            return
        }

        errorResetTask?.cancel()
        resetToIdle()
        do {
            let saved = try recordingStore.load(sessionID)
            let resumesCleanup = saved.cleanup != nil && recordingStore.draftTranscript(sessionID: sessionID) != nil
            try recordingStore.prepareForProcessing(
                sessionID: sessionID,
                transcriptionModel: resumesCleanup ? saved.resolvedTranscriptionModel : settings.transcriptionModel,
                transcriptionContext: resumesCleanup ? (saved.resolvedTranscriptionContext ?? "") : "",
                vocabulary: resumesCleanup ? (saved.vocabulary ?? []) : settings.personalDictionary,
                forceRetranscription: !resumesCleanup,
                cleanup: settings.cleanupConfiguration,
                screenshotSourceURL: nil
            )
        } catch {
            showError(error.localizedDescription)
            return
        }
        processSavedRecording(
            sessionID,
            delivery: DeliveryOptions(
                targetApplication: targetApplication ?? currentPasteTarget(),
                autoPaste: settings.autoPaste,
                restoreClipboard: settings.restoreClipboard
            )
        )
    }

    private func deletePendingRecording(_ sessionID: UUID) {
        guard processingSessionID != sessionID, activeRecordingID != sessionID else {
            return
        }

        do {
            try recordingStore.trashSession(sessionID)
            refreshPersistentMenus()
            if recoverySessionID == sessionID, activeRecordingID == nil {
                resetToIdle()
            }
        } catch {
            if activeRecordingID != nil {
                appState.captureStatusMessage = "Could not move the older recording to Trash: \(error.localizedDescription)"
            } else {
                showError(error.localizedDescription)
            }
        }
    }

    private func revealPendingRecording(_ sessionID: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([
            recordingStore.directoryURL(for: sessionID)
        ])
    }

    private func presentOldestPendingRecording() {
        guard
            !isRecoveryPromptVisible,
            !isStartingRecording,
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
            deletePendingRecording(recording.id)
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

        You can keep this recording for later and start a new one at any time.\(error)
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

        Task { [weak self] in
            guard let self else { return }
            do {
                try await historyStore.clear()
                lastTranscript = ""
                refreshPersistentMenus()
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func refreshPersistentMenus() {
        // Coalesce menu openings; the history store caches decoded entries and scans off-main.
        persistentMenuRefreshTask?.cancel()
        persistentMenuRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let history = try await historyStore.recent()
                try Task.checkCancellation()
                let pending = try recordingStore.summaries()
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
            } catch is CancellationError {
                return
            } catch {
                print("Could not refresh saved data: \(error.localizedDescription)")
            }
        }
    }

    private var isErrorPhase: Bool {
        if case .error = appState.phase {
            return true
        }
        return false
    }

    private func resetToIdle() {
        activeOperationID = nil
        processingTask = nil
        processingSessionID = nil
        stopElapsedTimer()
        targetApplication = nil
        activeInputDevice = nil
        appState.recordingDeviceName = nil
        appState.captureStatusMessage = nil
        appState.liveInstructionsShortened = false
        recordingConfiguration = nil
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
                self.monitorCaptureHealth()
                let level = self.audioCapture.currentLevel()
                self.appState.pushLevel(level)
                self.updateMicrophoneSignalStatus(
                    level: level,
                    elapsed: self.appState.elapsedSeconds
                )
            }
        }
    }

    private func monitorCaptureHealth() {
        guard let sessionID = activeRecordingID else { return }
        realtimeAudioCapture.checkHealth()
        if let message = realtimeSession?.failureMessage {
            liveCaptureContinuous = false
            appState.captureStatusMessage = "Live transcription stopped. The saved recording will be used. \(message)"
        }

        guard Date() >= nextMicrophoneRecoveryAt else { return }
        let interruption: String
        if !audioCapture.hasActiveRecording {
            interruption = "The microphone is unavailable. Retrying capture..."
        } else if case .interrupted(let message) = audioCapture.checkHealth() {
            interruption = message
        } else {
            return
        }

        savedCaptureContinuous = false
        liveCaptureContinuous = false
        appState.captureStatusMessage = "\(interruption) Some audio may be missing; recorded parts will be kept."
        try? recordingStore.setCaptureContinuity(live: false, saved: false, for: sessionID)
        nextMicrophoneRecoveryAt = Date().addingTimeInterval(2)
        if audioCapture.hasActiveRecording {
            _ = audioCapture.stopIfNeeded()
            try? recordingStore.finishCurrentChunk(in: sessionID, duration: audioCapture.recordedDuration)
        }
        do {
            let url = try recordingStore.beginChunk(in: sessionID)
            let device = try audioCapture.start(at: url)
            try recordingStore.setInputDevice(device, for: sessionID)
            activeInputDevice = device
            appState.recordingDeviceName = device.name
        } catch {
            appState.captureStatusMessage = "Microphone capture interrupted. Recorded parts are safe. Retrying: \(error.localizedDescription)"
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
                if liveCaptureContinuous && savedCaptureContinuous {
                    appState.captureStatusMessage = nil
                }
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
        guard appState.captureStatusMessage == nil else { return }
        appState.captureStatusMessage =
            "No recorded signal from \(activeInputDevice?.name ?? "the selected microphone") — check your input device."
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
                updateRealtimeContext(for: attachment)
                return
            } catch {
                lastError = error
            }
        }

        appState.screenshotStatusMessage =
            lastError?.localizedDescription ?? "Could not attach a screenshot."
    }

    private func updateRealtimeContext(for attachment: AttachedScreenshot) {
        let attachmentID = attachment.id
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let visibleText = await ScreenshotContextExtractor.extractText(
                from: attachment.fileURL
            )
            guard
                self.activeRecordingID != nil,
                self.appState.attachedScreenshot?.id == attachmentID
            else {
                return
            }

            var contextParts = [self.recordingConfiguration?.context ?? ""]
            if let visibleText {
                contextParts.append(
                    "Screenshot text:\n\(visibleText)"
                )
            }
            self.realtimeSession?.updateTranscriptionContext(
                contextParts.joined(separator: "\n\n")
            )
            self.appState.liveInstructionsShortened = self.realtimeSession?.usesShortenedInstructions ?? false
            self.liveContextAttachmentID = attachmentID
        }
    }

    private func clearAttachedScreenshot() {
        liveContextAttachmentID = nil
        screenshotCapture.remove(appState.attachedScreenshot)
        appState.attachedScreenshot = nil
        appState.screenshotStatusMessage = nil
        appState.isCapturingScreenshot = false
        if activeRecordingID != nil {
            realtimeSession?.updateTranscriptionContext(
                recordingConfiguration?.context ?? ""
            )
        }
    }

    private func showError(
        _ message: String,
        recoverable: Bool = false
    ) {
        stopElapsedTimer()
        targetApplication = nil
        clearAttachedScreenshot()
        appState.setPhase(.error(message))
        if recoverable {
            appState.captureStatusMessage = message
            if let id = recoverySessionID,
               let partial = recordingStore.draftTranscript(sessionID: id)
                    ?? recordingStore.livePartialTranscript(sessionID: id) {
                appState.setTranscriptPreview(fullText: partial)
            }
        } else {
            appState.setProgressMessage(message)
        }
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
