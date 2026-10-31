import AppKit
import Testing
@testable import SuperSamuelApp

@MainActor
struct TextInsertionServiceTests {
    @Test
    func transcriptRemainsAvailableWhenTargetDoesNotConsumePaste() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        clipboard.setString("Before dictation")
        let target = TestPasteTarget()
        target.isActive = true
        var pasteRequests = 0
        let insertion = TextInsertionService(clipboard: clipboard, postCommandV: {
            // A posted keyboard event does not prove that the target accepted it.
            pasteRequests += 1
        })

        insertion.deliver(
            text: "Dictated text",
            targetApplication: target,
            autoPaste: true
        )
        #expect(pasteboard.string(forType: .string) == "Dictated text")
        try await Task.sleep(for: .milliseconds(750))

        withExtendedLifetime(insertion) {
            #expect(pasteRequests == 1)
            #expect(pasteboard.string(forType: .string) == "Dictated text")
        }
    }

    @Test
    func pasteWaitsUntilTargetBecomesActive() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let target = TestPasteTarget()
        var pastedTexts: [String] = []
        let insertion = TextInsertionService(clipboard: clipboard, postCommandV: {
            if target.isActive, let text = pasteboard.string(forType: .string) {
                pastedTexts.append(text)
            }
        })

        insertion.deliver(
            text: "Dictated text",
            targetApplication: target,
            autoPaste: true
        )
        try await Task.sleep(for: .milliseconds(300))
        #expect(pastedTexts.isEmpty)
        target.isActive = true
        try await Task.sleep(for: .milliseconds(150))

        withExtendedLifetime(insertion) {
            #expect(pastedTexts == ["Dictated text"])
        }
    }

    enum UnavailableTarget: CaseIterable {
        case missing, terminated, rejected, neverActive
    }

    @Test(arguments: UnavailableTarget.allCases)
    func unavailableTargetKeepsTranscriptWithoutPaste(reason: UnavailableTarget) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let target = TestPasteTarget()
        target.isTerminated = reason == .terminated
        target.acceptsActivation = reason != .rejected
        var pasteRequests = 0
        let insertion = TextInsertionService(clipboard: clipboard, postCommandV: {
            pasteRequests += 1
        })

        insertion.deliver(
            text: "Dictated text",
            targetApplication: reason == .missing ? nil : target,
            autoPaste: true
        )
        try await Task.sleep(for: .milliseconds(1_200))
        // Becoming active after the timeout must not send a surprise Paste.
        target.isActive = true
        try await Task.sleep(for: .milliseconds(75))

        withExtendedLifetime(insertion) {
            #expect(pasteRequests == 0)
            #expect(pasteboard.string(forType: .string) == "Dictated text")
        }
    }

    @Test(arguments: ["A newer copy", "Dictated text"])
    func userCopyCancelsPendingPaste(newCopy: String) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let target = TestPasteTarget()
        var pasteRequests = 0
        let insertion = TextInsertionService(clipboard: clipboard, postCommandV: {
            pasteRequests += 1
        })

        insertion.deliver(text: "Dictated text", targetApplication: target, autoPaste: true)
        try await Task.sleep(for: .milliseconds(50))
        clipboard.setString(newCopy)
        target.isActive = true
        try await Task.sleep(for: .milliseconds(100))

        withExtendedLifetime(insertion) {
            #expect(pasteRequests == 0)
            #expect(pasteboard.string(forType: .string) == newCopy)
        }
    }

    @Test(arguments: [false, true])
    func newDictationCancelsPreviousPendingPaste(autoPaste: Bool) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let oldTarget = TestPasteTarget()
        let newTarget = TestPasteTarget()
        newTarget.isActive = true
        var pastedTexts: [String] = []
        let insertion = TextInsertionService(clipboard: clipboard, postCommandV: {
            if let text = pasteboard.string(forType: .string) {
                pastedTexts.append(text)
            }
        })

        insertion.deliver(text: "First transcript", targetApplication: oldTarget, autoPaste: true)
        try await Task.sleep(for: .milliseconds(50))
        insertion.deliver(text: "Second transcript", targetApplication: newTarget, autoPaste: autoPaste)
        oldTarget.isActive = true
        try await Task.sleep(for: .milliseconds(100))

        withExtendedLifetime(insertion) {
            #expect(pastedTexts == (autoPaste ? ["Second transcript"] : []))
            #expect(pasteboard.string(forType: .string) == "Second transcript")
        }
    }
}

@MainActor
private final class TestPasteTarget: TextInsertionTarget {
    var isActive = false
    var isTerminated = false
    var acceptsActivation = true

    func activate(options: NSApplication.ActivationOptions) -> Bool { acceptsActivation }
}
