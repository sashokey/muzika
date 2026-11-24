import SwiftUI

enum GlassHoverMotion {
    static let appearance = Animation.smooth(duration: 0.20)
    static let initialScale: CGFloat = 0.96
}

extension View {
    func liquidGlassHover() -> some View {
        liquidGlassHover(in: RoundedRectangle(cornerRadius: 8))
    }

    func liquidGlassHover<Outline: InsettableShape>(in outline: Outline) -> some View {
        modifier(LiquidGlassHover(outline: outline))
    }
}

private struct LiquidGlassHover<Outline: InsettableShape>: ViewModifier {
    let outline: Outline
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false

    func body(content: Content) -> some View {
        let visible = hovered && isEnabled
        content
            .background {
                ZStack {
                    if visible {
                        material
                            .overlay {
                                outline.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                            }
                            .padding(-1)
                            .transition(
                                reduceMotion ? .identity : .scale(scale: GlassHoverMotion.initialScale).combined(with: .opacity)
                            )
                    }
                }
                .animation(reduceMotion ? nil : GlassHoverMotion.appearance, value: visible)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var material: some View {
        if reduceTransparency {
            outline.fill(.primary.opacity(0.12))
        } else {
            Color.clear.glassEffect(.regular, in: outline)
        }
    }
}
