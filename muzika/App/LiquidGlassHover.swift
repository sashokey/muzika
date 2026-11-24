import SwiftUI

enum GlassHoverMotion {
    static let appearance = Animation.smooth(duration: 0.20)
    static let initialScale: CGFloat = 0.96
}

extension View {
    func liquidGlassHover(outset: CGSize = CGSize(width: 1, height: 1)) -> some View {
        modifier(LiquidGlassHover(outline: RoundedRectangle(cornerRadius: 8), outset: outset))
    }

    func liquidGlassSidebarHover(selectionTint: Bool) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .modifier(LiquidGlassHover(
                outline: RoundedRectangle(cornerRadius: 8),
                outset: CGSize(width: 6, height: 0),
                selectionTint: selectionTint,
                usesListRowHeight: true
            ))
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
    var usesListRowHeight = false
    @Environment(\.defaultMinListRowHeight) private var listRowHeight
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
                            .frame(height: usesListRowHeight ? listRowHeight : nil)
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

struct GlassHoverButtonStyle: ButtonStyle {
    var prominent = false
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(GlassHoverButtonSurface(
            prominent: prominent, iconOnly: iconOnly, role: configuration.role, pressed: configuration.isPressed
        ))
    }
}

private struct GlassHoverButtonSurface: ViewModifier {
    let prominent: Bool
    let iconOnly: Bool
    let role: ButtonRole?
    let pressed: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false

    func body(content: Content) -> some View {
        let visible = hovered && isEnabled
        let glass = visible && !reduceTransparency
        let outline = RoundedRectangle(cornerRadius: 6)
        let height = switch controlSize {
        case .mini: 16.0
        case .small: 20.0
        case .large: 28.0
        case .extraLarge: 32.0
        default: 24.0
        }
        let fontSize = switch controlSize {
        case .mini: 10.0
        case .small: 11.0
        case .large: 15.0
        case .extraLarge: 17.0
        default: 13.0
        }
        let foreground: Color = prominent ? .white : role == .destructive ? .red : .primary
        let restingFill: Color = prominent ? .accentColor : .primary.opacity(pressed ? 0.16 : 0.09)
        let fallback: Color = prominent ? .accentColor.opacity(0.85) : .primary.opacity(pressed ? 0.2 : 0.12)

        content
            .font(.system(size: fontSize))
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 0 : height / 2)
            .frame(minWidth: iconOnly ? height + 10 : nil, minHeight: height)
            .background {
                let fill: Color = glass ? .clear : visible ? fallback : restingFill
                outline.fill(fill)
                    .glassEffect(glass ? (prominent ? .regular.tint(.accentColor) : .regular) : .identity, in: outline)
                    .animation(reduceMotion ? nil : GlassHoverMotion.appearance, value: visible)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(outline)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovered = $0 }
    }
}
