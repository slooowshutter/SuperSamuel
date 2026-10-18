import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?

    init(settings: SettingsStore) {
        model = SettingsModel(settings: settings)
    }

    func show() {
        let window = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window {
            return window
        }

        let window = AlwaysActiveWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // A native split view with a sidebar item: on macOS 26 AppKit draws the floating
        // Liquid Glass sidebar and puts the window controls inside it.
        let sidebarHost = NSHostingController(
            rootView: SettingsSidebar(model: model).environment(\.controlActiveState, .key)
        )
        let detailHost = NSHostingController(
            rootView: SettingsPage(model: model).environment(\.controlActiveState, .key)
        )
        // The window owns its size; SwiftUI scrolls inside it instead of resizing it.
        detailHost.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.minimumThickness = 210
        sidebar.maximumThickness = 280
        sidebar.canCollapse = false
        let split = NSSplitViewController()
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailHost))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 780, height: 580))
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.title = "SuperSamuel Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The empty toolbar is what makes the sidebar float and hold the window controls.
        window.toolbar = NSToolbar(identifier: "SuperSamuelSettings")
        window.toolbarStyle = .unified
        // The whole window is Liquid Glass: the desktop shows through, blurred, behind the
        // floating sidebar and the page. The glass sits below the content in the frame
        // view, so the split view keeps its native layout. Older systems keep the normal look.
        if #available(macOS 26.0, *), let frameView = window.contentView?.superview {
            window.isOpaque = false
            window.backgroundColor = .clear
            let glass = NSGlassEffectView(frame: frameView.bounds)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = 26 // The macOS 26 window corner with a toolbar.
            frameView.addSubview(glass, positioned: .below, relativeTo: window.contentView)
        }
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        return window
    }
}

/// macOS draws an inactive window with faded, matte glass and a gray sidebar. Reporting
/// the window as main keeps more of the focused look while another app is in front. Key
/// status stays real, so typing and the text cursor work as usual.
/// ponytail: relies on AppKit asking isMainWindow for the active look; no public API
/// exists for Liquid Glass.
private final class AlwaysActiveWindow: NSWindow {
    override var isMainWindow: Bool { true }
}
