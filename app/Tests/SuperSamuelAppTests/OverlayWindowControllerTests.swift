import AppKit
import XCTest
@testable import SuperSamuelApp

final class OverlayWindowControllerTests: XCTestCase {
    func testResizeGripExpandsDownwardWhileKeepingTopEdgeFixed() {
        let startingFrame = NSRect(x: 100, y: 200, width: 376, height: 340)

        let resizedFrame = OverlayResizeGeometry.resizedFrame(
            from: startingFrame,
            translation: CGSize(width: 100, height: 80)
        )

        XCTAssertEqual(resizedFrame.minX, 100)
        XCTAssertEqual(resizedFrame.maxY, startingFrame.maxY)
        XCTAssertEqual(resizedFrame.width, 476)
        XCTAssertEqual(resizedFrame.height, 420)
    }

    func testResizeGripClampsToSupportedSizeRange() {
        let startingFrame = NSRect(x: 100, y: 200, width: 376, height: 340)

        let minimumFrame = OverlayResizeGeometry.resizedFrame(
            from: startingFrame,
            translation: CGSize(width: -1_000, height: -1_000)
        )
        let maximumFrame = OverlayResizeGeometry.resizedFrame(
            from: startingFrame,
            translation: CGSize(width: 1_000, height: 1_000)
        )

        XCTAssertEqual(minimumFrame.size, NSSize(width: 340, height: 300))
        XCTAssertEqual(minimumFrame.maxY, startingFrame.maxY)
        XCTAssertEqual(maximumFrame.size, NSSize(width: 900, height: 800))
        XCTAssertEqual(maximumFrame.maxY, startingFrame.maxY)
    }
}
