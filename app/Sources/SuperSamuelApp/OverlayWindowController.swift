import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let state: AppState
    private var panel: NSPanel?
    private var resizeStartFrame: NSRect?
    var onStop: (() -> Void)?
    var onAttachScreenshot: (() -> Void)?
    var onClearScreenshot: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDelete: (() -> Void)?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        let panel = ensurePanel()
        center(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            // Update the view with current callback
            updatePanelContent(panel)
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 340),
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

        updatePanelContent(panel)

        self.panel = panel
        return panel
    }

    private func updatePanelContent(_ panel: NSPanel) {
        let contentView = RecordingOverlayView(
            state: state,
            onStop: onStop,
            onAttachScreenshot: onAttachScreenshot,
            onClearScreenshot: onClearScreenshot,
            onRetry: onRetry,
            onDelete: onDelete,
            onResize: { [weak self, weak panel] translation, ended in
                guard let self, let panel else {
                    return
                }
                self.resize(
                    panel,
                    translation: translation,
                    ended: ended
                )
            }
        )
        let host = NSHostingView(rootView: contentView)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = makeLiquidGlassHost(
            content: host,
            cornerRadius: 22
        )
    }

    private func resize(
        _ panel: NSPanel,
        translation: CGSize,
        ended: Bool
    ) {
        if resizeStartFrame == nil {
            resizeStartFrame = panel.frame
        }

        guard let startingFrame = resizeStartFrame else {
            return
        }

        let resizedFrame = OverlayResizeGeometry.resizedFrame(
            from: startingFrame,
            translation: translation
        )
        panel.setFrame(resizedFrame, display: true)

        if ended {
            resizeStartFrame = nil
        }
    }

    private func center(_ panel: NSPanel) {
        guard let screenFrame = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }

        let originX = screenFrame.midX - (panel.frame.width / 2)
        let originY = screenFrame.midY - (panel.frame.height / 2)
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

enum OverlayResizeGeometry {
    static let minimumSize = NSSize(width: 340, height: 300)
    static let maximumSize = NSSize(width: 900, height: 800)

    static func resizedFrame(
        from startingFrame: NSRect,
        translation: CGSize
    ) -> NSRect {
        let width = min(
            maximumSize.width,
            max(minimumSize.width, startingFrame.width + translation.width)
        )
        let height = min(
            maximumSize.height,
            max(minimumSize.height, startingFrame.height + translation.height)
        )

        return NSRect(
            x: startingFrame.minX,
            y: startingFrame.maxY - height,
            width: width,
            height: height
        )
    }
}
