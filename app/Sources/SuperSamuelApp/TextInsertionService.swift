import AppKit
import Foundation

@MainActor
final class TextInsertionService {
    private let clipboard: ClipboardService

    init(clipboard: ClipboardService) {
        self.clipboard = clipboard
    }

    func deliver(
        text: String,
        targetApplication: NSRunningApplication?,
        autoPaste: Bool,
        restoreClipboard: Bool
    ) {
        let snapshot = (autoPaste && restoreClipboard) ? clipboard.snapshot() : nil

        clipboard.setString(text)
        let deliveryChangeCount = clipboard.changeCount

        if !autoPaste {
            return
        }

        pasteClipboardContents(into: targetApplication)

        if let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                self?.clipboard.restore(snapshot, ifUnchangedSince: deliveryChangeCount)
            }
        }

    }

    func pasteClipboardContents(into targetApplication: NSRunningApplication?) {
        targetApplication?.activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.simulateCommandV()
        }
    }

    private func simulateCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        let keyCodeForV: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
