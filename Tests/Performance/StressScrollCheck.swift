import AppKit

@MainActor
enum StressScrollCheck {
    static let itemCount = 5_000

    static func scrollViews(in host: NSView) -> [NSScrollView] {
        let nested = host.subviews.flatMap(scrollViews(in:))
        return (host as? NSScrollView).map { [$0] + nested } ?? nested
    }

    static func longScroll(in host: NSView, name: String,
                           matching: (NSScrollView) -> Bool = { _ in true }) async throws -> NSScrollView {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(8)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let scroll = scrollViews(in: host).first(where: {
                matching($0) && $0.convert($0.bounds, to: host).minX >= host.bounds.width * 0.12 &&
                    $0.contentView.documentRect.height >= 20_000
            }) {
                return scroll
            }
            try await Task.sleep(for: .milliseconds(65))
        } while clock.now < deadline
        throw HomeScrollCheck.Failure("\(name): no populated long scroll view")
    }

    static func scroll(_ scroll: NSScrollView, name: String) async throws {
        let clip = scroll.contentView
        let startX = clip.bounds.minX
        let top = clip.documentRect.minY
        let bottom = clip.documentRect.maxY - clip.bounds.height
        var offsets: [CGFloat] = []
        for fraction in [0.15, 0.55, 0.95, 0.35, 0.0] {
            clip.scroll(to: CGPoint(x: startX, y: top + (bottom - top) * fraction))
            scroll.reflectScrolledClipView(clip)
            try await Task.sleep(for: .milliseconds(45))
            offsets.append(clip.bounds.minY)
        }
        guard let nearest = offsets.min(), let farthest = offsets.max(), farthest - nearest > 1_000,
              abs((offsets.last ?? bottom) - top) < clip.bounds.height else {
            throw HomeScrollCheck.Failure("\(name): the populated list did not scroll down and back")
        }
    }
}
