import AppKit
import SwiftUI
import XCTest
@testable import SuperSamuelApp

final class OverlayWindowControllerTests: XCTestCase {
    private let startingFrame = NSRect(x: 100, y: 200, width: 640, height: 420)

    func testBottomRightCornerGrowsDownAndRightWhileKeepingTopLeftFixed() {
        // Screen coordinates: dragging down is a negative y delta.
        let resizedFrame = OverlayResizeGeometry.resizedFrame(
            from: startingFrame,
            by: CGSize(width: 100, height: -80),
            edges: [.bottom, .trailing]
        )

        XCTAssertEqual(resizedFrame.minX, startingFrame.minX)
        XCTAssertEqual(resizedFrame.maxY, startingFrame.maxY)
        XCTAssertEqual(resizedFrame.size, NSSize(width: 740, height: 500))
    }

    func testTopLeftCornerGrowsUpAndLeftWhileKeepingBottomRightFixed() {
        let resizedFrame = OverlayResizeGeometry.resizedFrame(
            from: startingFrame,
            by: CGSize(width: -50, height: 30),
            edges: [.top, .leading]
        )

        XCTAssertEqual(resizedFrame.maxX, startingFrame.maxX)
        XCTAssertEqual(resizedFrame.minY, startingFrame.minY)
        XCTAssertEqual(resizedFrame.size, NSSize(width: 690, height: 450))
    }

    func testResizeClampsToSupportedSizeRange() {
        let minimumFrame = OverlayResizeGeometry.resizedFrame(
            from: startingFrame,
            by: CGSize(width: -1_000, height: 1_000),
            edges: [.bottom, .trailing]
        )
        let maximumFrame = OverlayResizeGeometry.resizedFrame(
            from: startingFrame,
            by: CGSize(width: -2_000, height: 2_000),
            edges: [.top, .leading]
        )

        XCTAssertEqual(minimumFrame.size, OverlayResizeGeometry.minimumSize)
        XCTAssertEqual(minimumFrame.maxY, startingFrame.maxY)
        XCTAssertEqual(maximumFrame.size, OverlayResizeGeometry.maximumSize)
        XCTAssertEqual(maximumFrame.maxX, startingFrame.maxX)
    }
}
