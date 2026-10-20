import SwiftUI

extension View {
    /// Regular Liquid Glass in `shape` on macOS 26; a faint filled shape on older systems.
    func liquidGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: shape, interactive: interactive))
    }

    /// A text button drawn in Liquid Glass on macOS 26 and bordered on older systems.
    func liquidGlassButton(prominent: Bool = false) -> some View {
        modifier(LiquidGlassButtonModifier(prominent: prominent))
    }
}

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content
                .background(shape.fill(Color.primary.opacity(0.07)))
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }
}

private struct LiquidGlassButtonModifier: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
