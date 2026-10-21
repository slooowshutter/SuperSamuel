import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    /// The defaults name under which AppKit keeps the window frame between launches.
    private static let frameName = "RecordingOverlayFrame"

    private let state: AppState
    private var panel: NSPanel?
    private var resizeStart: (frame: NSRect, mouse: NSPoint)?
    var onStop: (() -> Void)?
    var onAttachScreenshot: (() -> Void)?
    var onClearScreenshot: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        let panel = ensurePanel()
        // Keep the position the user chose while the overlay stays on screen.
        if !panel.isVisible {
            center(panel)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: OverlayResizeGeometry.defaultSize),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = OverlayResizeGeometry.minimumSize
        panel.contentMaxSize = OverlayResizeGeometry.maximumSize
        // Reopen at the size the user chose last time, and save every new size.
        panel.setFrameUsingName(Self.frameName)
        panel.setFrameAutosaveName(Self.frameName)

        let contentView = RecordingOverlayView(
            state: state,
            onStop: onStop,
            onAttachScreenshot: onAttachScreenshot,
            onClearScreenshot: onClearScreenshot,
            onRetry: onRetry,
            onDelete: onDelete,
            onCopy: onCopy,
            onResize: { [weak self, weak panel] edges, ended in
                guard let self, let panel else {
                    return
                }
                self.resize(panel, edges: edges, ended: ended)
            }
        )
        let host = NSHostingView(rootView: contentView)
        // The window owns its size. Otherwise SwiftUI sets a minimum height from its
        // narrowest layout, where a wrapped notice can stretch the window past the screen.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = makeLiquidGlassHost(content: host, cornerRadius: 26)

        self.panel = panel
        return panel
    }

    /// Follows the pointer in screen coordinates, so the window can move under it
    /// while a left or top edge is dragged.
    private func resize(_ panel: NSPanel, edges: Edge.Set, ended: Bool) {
        let mouse = NSEvent.mouseLocation
        let start = resizeStart ?? (panel.frame, mouse)
        resizeStart = ended ? nil : start
        let delta = CGSize(width: mouse.x - start.mouse.x, height: mouse.y - start.mouse.y)
        panel.setFrame(
            OverlayResizeGeometry.resizedFrame(
                from: start.frame,
                by: delta,
                edges: edges,
                screenHeight: panel.screen?.visibleFrame.height ?? .infinity
            ),
            display: true
        )
    }

    private func center(_ panel: NSPanel) {
        guard let screenFrame = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }

        // A size saved on a taller screen must still fit this one.
        let width = panel.frame.width
        let height = min(panel.frame.height, screenFrame.height)
        panel.setFrame(
            NSRect(
                x: screenFrame.midX - (width / 2),
                y: screenFrame.midY - (height / 2),
                width: width,
                height: height
            ),
            display: false
        )
    }
}

enum OverlayResizeGeometry {
    static let defaultSize = NSSize(width: 640, height: 420)
    static let minimumSize = NSSize(width: 520, height: 360)
    static let maximumSize = NSSize(width: 1200, height: 900)

    /// The frame after the user drags `edges` of `frame` by `delta`, in screen
    /// coordinates. The opposite edges stay where they are, and the height never
    /// passes `screenHeight`.
    static func resizedFrame(
        from frame: NSRect,
        by delta: CGSize,
        edges: Edge.Set,
        screenHeight: CGFloat = .infinity
    ) -> NSRect {
        var width = frame.width
        var height = frame.height
        if edges.contains(.leading) { width -= delta.width }
        if edges.contains(.trailing) { width += delta.width }
        if edges.contains(.top) { height += delta.height }
        if edges.contains(.bottom) { height -= delta.height }
        width = min(max(width, minimumSize.width), maximumSize.width)
        height = min(max(height, minimumSize.height), maximumSize.height, screenHeight)

        return NSRect(
            x: edges.contains(.leading) ? frame.maxX - width : frame.minX,
            y: edges.contains(.bottom) ? frame.maxY - height : frame.minY,
            width: width,
            height: height
        )
    }
}
