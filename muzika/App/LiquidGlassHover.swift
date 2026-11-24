import SwiftUI

enum GlassHoverMotion {
    static let appearance = Animation.smooth(duration: 0.20)
    static let initialScale: CGFloat = 0.96
}

extension View {
    func liquidGlassHover(outset: CGSize = CGSize(width: 1, height: 1), selectionTint: Bool = false) -> some View {
        modifier(LiquidGlassHover(outline: RoundedRectangle(cornerRadius: 8), outset: outset, selectionTint: selectionTint))
    }

    func liquidGlassHover<Outline: InsettableShape>(
        in outline: Outline, outset: CGSize = CGSize(width: 1, height: 1), scale: CGFloat = 1
    ) -> some View {
        modifier(LiquidGlassHover(outline: outline, outset: outset, scale: scale))
    }
}

private struct LiquidGlassHover<Outline: InsettableShape>: ViewModifier {
    let outline: Outline
    var outset = CGSize(width: 1, height: 1)
    var selectionTint = false
    var scale: CGFloat = 1
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
                            .padding(.horizontal, -outset.width)
                            .padding(.vertical, -outset.height)
                            .scaleEffect(scale)
                            .transition(appearance)
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
        if selectionTint {
            outline.fill(.white.opacity(0.07))
        } else {
            ZStack {
                if reduceTransparency {
                    outline.fill(.primary.opacity(0.12))
                } else {
                    Color.clear.glassEffect(.regular, in: outline)
                }
            }
            .overlay {
                outline.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
    }

    private var appearance: AnyTransition {
        if reduceMotion { return .identity }
        if selectionTint { return .opacity }
        return .modifier(active: GlassHoverReveal(progress: 0), identity: GlassHoverReveal(progress: 1))
    }
}

private struct GlassHoverReveal: ViewModifier, Animatable {
    nonisolated var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let progress = progress
        return content.visualEffect { effect, geometry in
            let span = max(1, geometry.size.width, geometry.size.height)
            let shrink = min(1 - GlassHoverMotion.initialScale, 2 / span)
            return effect.scaleEffect(1 - shrink * CGFloat(1 - progress)).opacity(progress)
        }
    }
}
