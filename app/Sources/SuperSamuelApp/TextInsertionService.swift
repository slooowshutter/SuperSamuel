import AppKit
import Foundation
import os

private let deliveryLog = Logger(subsystem: "com.supersamuel.app", category: "Delivery")

@MainActor
protocol TextInsertionTarget: AnyObject {
    var isActive: Bool { get }
    var isTerminated: Bool { get }
    func activate(options: NSApplication.ActivationOptions) -> Bool
}

extension NSRunningApplication: TextInsertionTarget {}

@MainActor
final class TextInsertionService {
    private let clipboard: ClipboardService
    private let postCommandV: () -> Void
    private var pendingPaste: Task<Void, Never>?

    init(clipboard: ClipboardService, postCommandV: (() -> Void)? = nil) {
        self.clipboard = clipboard
        self.postCommandV = postCommandV ?? Self.simulateCommandV
    }

    deinit {
        pendingPaste?.cancel()
    }

    func deliver(
        text: String,
        targetApplication: (any TextInsertionTarget)?,
        autoPaste: Bool
    ) {
        pendingPaste?.cancel()
        pendingPaste = nil
        // A posted Paste event cannot confirm that the field accepted the text.
        // Keep the transcript available for a manual paste, including slow targets.
        clipboard.setString(text)
        let deliveryChangeCount = clipboard.changeCount

        guard autoPaste else {
            return
        }
        guard let targetApplication, !targetApplication.isTerminated else {
            deliveryLog.notice("Transcript copied; no running paste target")
            return
        }
        if targetApplication.isActive {
            postCommandV()
            return
        }
        guard targetApplication.activate(options: [.activateIgnoringOtherApps]) else {
            deliveryLog.notice("Transcript copied; target rejected activation")
            return
        }

        pendingPaste = Task { [clipboard, postCommandV] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !targetApplication.isActive {
                guard !Task.isCancelled,
                      !targetApplication.isTerminated,
                      clipboard.changeCount == deliveryChangeCount else { return }
                guard ContinuousClock.now < deadline else {
                    deliveryLog.notice("Transcript copied; target did not become active")
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return
                }
            }

            // A new copy or dictation supersedes this delayed Paste request.
            guard !Task.isCancelled,
                  !targetApplication.isTerminated,
                  clipboard.changeCount == deliveryChangeCount else { return }
            postCommandV()
        }
    }

    private static func simulateCommandV() {
        let keyCodeForV: CGKeyCode = 9
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: false) else {
            deliveryLog.error("Transcript copied; could not create Paste key events")
            return
        }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        deliveryLog.notice("Paste key events posted")
    }
}
