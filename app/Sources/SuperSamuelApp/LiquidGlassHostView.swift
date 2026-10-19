import AppKit

/// The same regular Liquid Glass as the Settings window: the desktop shows through,
/// blurred, with no tint of its own. Older systems get a plain rounded background.
func makeLiquidGlassHost(
    content: NSView,
    cornerRadius: CGFloat
) -> NSView {
    content.autoresizingMask = [.width, .height]

    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }

    let fallback = NSView()
    fallback.wantsLayer = true
    fallback.layer?.cornerRadius = cornerRadius
    fallback.layer?.backgroundColor = NSColor.windowBackgroundColor
        .withAlphaComponent(0.94)
        .cgColor
    content.frame = fallback.bounds
    fallback.addSubview(content)
    return fallback
}
