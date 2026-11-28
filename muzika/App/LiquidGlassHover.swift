import AppKit
import SwiftUI

enum GlassHoverMotion {
    static let duration: TimeInterval = 0.20
    static let appearance = Animation.smooth(duration: duration)
    static let initialScale: CGFloat = 0.96
}

extension View {
    func stableHover(_ perform: @escaping (Bool) -> Void) -> some View {
        background {
            StableHoverRegion(perform: perform)
                .accessibilityHidden(true)
        }
    }

    func liquidGlassHover(outset: CGSize = CGSize(width: 1, height: 1), hovered: Bool? = nil) -> some View {
        modifier(LiquidGlassHover(outline: RoundedRectangle(cornerRadius: 8), outset: outset, hoverOverride: hovered))
    }

    func liquidGlassHover<Fill: ShapeStyle>(restingFill: Fill) -> some View {
        modifier(LiquidGlassHover(
            outline: RoundedRectangle(cornerRadius: 8), outset: .zero, restingFill: AnyShapeStyle(restingFill)
        ))
    }

    func liquidGlassSidebarHover(selectionTint: Bool) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .modifier(LiquidGlassHover(
                outline: RoundedRectangle(cornerRadius: 8),
                outset: CGSize(width: 6, height: 0),
                selectionTint: selectionTint,
                usesListRowHeight: true
            ))
            .contentShape(Rectangle())
            .buttonPointer()
    }

    func liquidGlassHover<Outline: InsettableShape>(
        in outline: Outline, outset: CGSize = CGSize(width: 1, height: 1), scale: CGFloat = 1,
        stableTracking: Bool = false
    ) -> some View {
        modifier(LiquidGlassHover(outline: outline, outset: outset, scale: scale, stableTracking: stableTracking))
    }
}

private struct LiquidGlassHover<Outline: InsettableShape>: ViewModifier {
    let outline: Outline
    var outset = CGSize(width: 1, height: 1)
    var selectionTint = false
    var scale: CGFloat = 1
    var stableTracking = false
    var usesListRowHeight = false
    var restingFill: AnyShapeStyle?
    var hoverOverride: Bool?
    @Environment(\.defaultMinListRowHeight) private var listRowHeight
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let visible = (hoverOverride ?? hovered) && isEnabled
        let surface = content
            .background {
                ZStack {
                    if visible {
                        material
                            .padding(.horizontal, -outset.width)
                            .padding(.vertical, -outset.height)
                            .frame(height: usesListRowHeight ? listRowHeight : nil)
                            .scaleEffect(scale)
                            .transition(appearance)
                    } else if let restingFill {
                        outline.fill(restingFill)
                    }
                }
                .animation(reduceMotion ? nil : GlassHoverMotion.appearance, value: visible)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        if hoverOverride != nil {
            surface
        } else if stableTracking {
            surface.stableHover { hovered = $0 }
        } else {
            surface.onHover { hovered = $0 }
        }
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

private struct StableHoverRegion: NSViewRepresentable {
    let perform: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView()
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.perform = perform
    }

    final class TrackingView: NSView {
        var perform: ((Bool) -> Void)?

        init() {
            super.init(frame: .zero)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { perform?(true) }
        override func mouseExited(with event: NSEvent) { perform?(false) }
    }
}

struct GlassHoverButtonStyle: ButtonStyle {
    enum HoverAppearance {
        case glass
        case stableGlass
        case color
    }

    var prominent = false
    var iconSymbol: String?
    var showsMenuIndicator = false
    var hoverAppearance = HoverAppearance.glass

    static func action(
        prominent: Bool = false, iconSymbol: String? = nil, showsMenuIndicator: Bool = false
    ) -> Self {
        Self(prominent: prominent, iconSymbol: iconSymbol, showsMenuIndicator: showsMenuIndicator, hoverAppearance: .stableGlass)
    }

    static func accent() -> Self {
        Self(prominent: true, hoverAppearance: .color)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(GlassHoverButtonSurface(
            prominent: prominent, iconSymbol: iconSymbol, role: configuration.role, pressed: configuration.isPressed,
            showsMenuIndicator: showsMenuIndicator, hoverAppearance: hoverAppearance
        ))
    }
}

private struct GlassHoverButtonSurface: ViewModifier {
    let prominent: Bool
    let iconSymbol: String?
    let role: ButtonRole?
    let pressed: Bool
    let showsMenuIndicator: Bool
    let hoverAppearance: GlassHoverButtonStyle.HoverAppearance
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false

    @ViewBuilder
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
        let iconOnly = iconSymbol != nil

        let button = label(content, height: height, fontSize: fontSize)
            .font(.system(size: fontSize))
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 0 : height / 2)
            .frame(minWidth: iconOnly ? height + 10 : nil, minHeight: height)
            .background {
                let material: Glass = prominent ? .regular.tint(.accentColor) : .regular
                Group {
                    switch hoverAppearance {
                    case .color:
                        outline.fill(visible ? Color.accentColor.mix(with: .black, by: 0.12) : restingFill)
                    case .stableGlass:
                        ZStack {
                            outline.fill(visible ? fallback : restingFill)
                                .opacity(glass ? 0 : 1)
                            if !reduceTransparency {
                                Color.clear.glassEffect(material, in: outline)
                                    .opacity(glass ? 1 : 0)
                            }
                        }
                    case .glass:
                        let fill: Color = glass ? .clear : visible ? fallback : restingFill
                        outline.fill(fill)
                            .glassEffect(glass ? material : .identity, in: outline)
                    }
                }
                .animation(reduceMotion ? nil : GlassHoverMotion.appearance, value: visible)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(outline)
            .opacity(isEnabled ? 1 : 0.5)
            .buttonPointer()
        if hoverAppearance != .glass {
            button.stableHover { inside in
                hovered = inside
            }
        } else {
            button.onHover { hovered = $0 }
        }
    }

    @ViewBuilder
    private func label(_ content: Content, height: CGFloat, fontSize: CGFloat) -> some View {
        if let iconSymbol {
            CenteredControlSymbol(name: iconSymbol, size: CGSize(width: height + 10, height: height),
                                  pointSize: fontSize, weight: .regular)
        } else if showsMenuIndicator {
            HStack(spacing: 8) {
                content
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}
