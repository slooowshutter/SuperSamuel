import AppKit
import XCTest
@testable import SuperSamuelApp

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testHoveringLongEditorKeepsScrollingPage() {
        let (window, page, inner, editor) = fixture(textHeight: 1_000)
        inner.contentView.scroll(to: NSPoint(x: 0, y: 200))
        window.makeFirstResponder(nil)
        XCTAssertTrue(window.pageScrollView(over: editor, deltaY: -10) === page)
        XCTAssertTrue(window.pageScrollView(over: editor, deltaY: 10) === page)
    }

    func testFocusedShortEditorKeepsScrollingPage() {
        let (window, page, _, editor) = fixture(textHeight: 100)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.pageScrollView(over: editor, deltaY: -10) === page)
        XCTAssertTrue(window.pageScrollView(over: editor, deltaY: 10) === page)
    }

    func testFocusedLongEditorScrollsTextAndHandsOffAtBothEdges() {
        let (window, page, inner, editor) = fixture(textHeight: 1_000)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setFrameSize(NSSize(width: 380, height: 1_000))
        inner.contentView.scroll(to: NSPoint(x: 0, y: 200))
        XCTAssertNil(window.pageScrollView(over: editor, deltaY: -10))
        XCTAssertNil(window.pageScrollView(over: editor, deltaY: 10))

        inner.contentView.scroll(to: .zero)
        XCTAssertTrue(window.pageScrollView(over: editor, deltaY: 10) === page)
        XCTAssertNil(window.pageScrollView(over: editor, deltaY: -10))

        inner.contentView.scroll(to: NSPoint(x: 0, y: editor.bounds.maxY - inner.contentView.bounds.height))
        XCTAssertTrue(window.pageScrollView(over: editor, deltaY: -10) === page)
        XCTAssertNil(window.pageScrollView(over: editor, deltaY: 10))
    }

    func testPlainAndSecureFieldsKeepScrollingPageWhileEditing() {
        let (window, page, _, _) = fixture(textHeight: 100)
        for field in [NSTextField(), NSSecureTextField()] {
            field.frame = NSRect(x: 0, y: 300, width: 300, height: 24)
            page.documentView!.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            XCTAssertTrue(window.pageScrollView(over: field, deltaY: -10) === page)
            if let editor = window.firstResponder as? NSTextView {
                XCTAssertTrue(window.pageScrollView(over: editor, deltaY: -10) === page)
            }
        }
    }

    func testDisabledEditorScrollsPageAndOtherControlsUseNormalDispatch() {
        let (window, page, inner, editor) = fixture(textHeight: 1_000)
        window.makeFirstResponder(editor)
        editor.isEditable = false
        XCTAssertTrue(window.pageScrollView(over: editor, deltaY: -10) === page)
        XCTAssertNil(window.pageScrollView(over: inner.verticalScroller!, deltaY: -10))
        XCTAssertNil(window.pageScrollView(over: page.documentView!, deltaY: -10))
    }

    private func fixture(textHeight: CGFloat) -> (SettingsWindow, NSScrollView, NSScrollView, NSTextView) {
        _ = NSApplication.shared
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                                    styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = NSScrollView(frame: window.contentView!.bounds)
        page.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 2_000))
        window.contentView = page
        let inner = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        inner.hasVerticalScroller = true
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: textHeight))
        inner.documentView = editor
        page.documentView!.addSubview(inner)
        editor.string = String(repeating: "Example text\n", count: Int(textHeight / 16))
        editor.sizeToFit()
        return (window, page, inner, editor)
    }
}
