import AppKit

final class SettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel,
           let contentView,
           let hitView = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)),
           let scrollView = pageScrollView(over: hitView, deltaY: event.scrollingDeltaY) {
            scrollView.scrollWheel(with: event)
            return
        }
        super.sendEvent(event)
    }

    func pageScrollView(over hitView: NSView, deltaY: CGFloat) -> NSScrollView? {
        var view: NSView? = hitView
        var textView: NSTextView?
        var isTextInput = false
        var scrollViews: [NSScrollView] = []
        while let current = view {
            if current is NSScroller { return nil }
            if let editor = current as? NSTextView {
                textView = editor
                isTextInput = true
            }
            if current is NSTextField { isTextInput = true }
            if let scrollView = current as? NSScrollView {
                scrollViews.append(scrollView)
            }
            view = current.superview
        }
        guard isTextInput, let page = scrollViews.last else { return nil }

        // Hovering an input must not trap page scrolling. A focused multiline
        // editor can scroll its text, then hands scrolling back at either edge.
        if let textView, textView.isEditable, !textView.isFieldEditor,
           firstResponder === textView,
           let inner = scrollViews.first, inner !== page,
           let document = inner.documentView {
            let visible = inner.documentVisibleRect
            let towardMinimumY = document.isFlipped ? deltaY > 0 : deltaY < 0
            let canScroll = towardMinimumY
                ? visible.minY > document.bounds.minY + 0.5
                : visible.maxY < document.bounds.maxY - 0.5
            if canScroll { return nil }
        }
        return page
    }
}
