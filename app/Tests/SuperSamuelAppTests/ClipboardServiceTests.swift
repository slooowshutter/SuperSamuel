import AppKit
import XCTest
@testable import SuperSamuelApp

@MainActor
final class ClipboardServiceTests: XCTestCase {
    func testRestoresPreviousContentsWhenDeliveryStillOwnsClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        clipboard.setString("Before dictation")
        let snapshot = clipboard.snapshot()
        clipboard.setString("Dictated text")

        XCTAssertTrue(clipboard.restore(snapshot, ifUnchangedSince: clipboard.changeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "Before dictation")
    }

    func testNewUserCopySurvivesDelayedRestorationEvenWhenTextMatches() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        clipboard.setString("Before dictation")
        let snapshot = clipboard.snapshot()
        clipboard.setString("Dictated text")
        let deliveryChangeCount = clipboard.changeCount
        clipboard.setString("Dictated text")

        XCTAssertFalse(clipboard.restore(snapshot, ifUnchangedSince: deliveryChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "Dictated text")
    }
}
