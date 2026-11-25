import AppKit
import QuartzCore

@MainActor
enum HomeScrollCheck {
    static func run(host: NSView, window: NSWindow, down: Bool) async throws {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }

        let views = descendants(host)
        guard let glow = views.first(where: { String(describing: type(of: $0)) == "GlowView" }),
              let layers = glow.layer?.sublayers, !layers.isEmpty else {
            throw Failure("Home Shuffle glow is missing")
        }
        var ancestor = glow.superview
        while let view = ancestor, !(view is NSScrollView) {
            ancestor = view.superview
        }
        guard let scroll = ancestor as? NSScrollView else {
            throw Failure("Home Shuffle is outside the scroll view")
        }
        let start = scroll.contentView.bounds.origin
        let distance = min(96, glow.bounds.height / 3)
        let endY = start.y + (down ? distance : -distance)
        guard distance > 50 else { throw Failure("Home Shuffle has no laid-out content") }

        let sampler = ScrollSampler(scroll: scroll, glow: glow, layers: layers, endY: endY)
        let link = window.displayLink(target: sampler, selector: #selector(ScrollSampler.tick(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        try await Task.sleep(for: .milliseconds(1_080))
        guard abs(scroll.contentView.bounds.minY - endY) < 1,
              abs(scroll.contentView.bounds.minY - start.y) > 50 else {
            throw Failure("Home did not scroll \(down ? "down" : "back up")")
        }
        guard sampler.visibleFrames == sampler.callbacks, sampler.animatedFrames == sampler.callbacks, sampler.callbacks > 1,
              sampler.glowChanges > 1 else {
            throw Failure(
                "Shuffle scroll: \(sampler.visibleFrames)/\(sampler.callbacks) visible frames, "
                + "\(sampler.animatedFrames) with glow animations, \(sampler.glowChanges) presented glow positions"
            )
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }

    @MainActor
    private final class ScrollSampler: NSObject {
        let scroll: NSScrollView
        let glow: NSView
        let layers: [CALayer]
        let origin: CGPoint
        let endY: CGFloat
        var startTime: CFTimeInterval?
        var lastGlowPosition: CGPoint?
        var callbacks = 0
        var visibleFrames = 0
        var glowChanges = 0
        var animatedFrames = 0

        init(scroll: NSScrollView, glow: NSView, layers: [CALayer], endY: CGFloat) {
            self.scroll = scroll
            self.glow = glow
            self.layers = layers
            origin = scroll.contentView.bounds.origin
            self.endY = endY
        }

        @objc func tick(_ link: CADisplayLink) {
            let time = link.timestamp
            if startTime == nil { startTime = time }
            let progress = min(1, max(0, (time - (startTime ?? time)) / 1.0))
            let clip = scroll.contentView
            clip.scroll(to: CGPoint(x: origin.x, y: origin.y + (endY - origin.y) * progress))
            scroll.reflectScrolledClipView(clip)
            callbacks += 1
            let glowBounds = glow.convert(glow.bounds, to: clip)
            let visible = glowBounds.intersection(clip.bounds)
            if scroll.window?.occlusionState.contains(.visible) == true,
               !visible.isNull, visible.height >= glowBounds.height * 0.5 {
                visibleFrames += 1
            }
            if layers.allSatisfy({ $0.animation(forKey: "drift") != nil }) {
                animatedFrames += 1
            }
            if let position = layers.first?.presentation()?.position, position != lastGlowPosition {
                lastGlowPosition = position
                glowChanges += 1
            }
        }
    }
}
