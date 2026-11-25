#if MUZIKA_DEV_LOGS
import AppKit
import QuartzCore
import SwiftUI

struct AnimationTraceProbe: NSViewRepresentable {
    let area: MuzikaTrace.Area
    let state: String
    var observesWindow = false

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.update(self) }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }

    final class Anchor: NSView {
        private var configuration: AnimationTraceProbe?
        private var lastState: String?
        private weak var observedWindow: NSWindow?
        private var display: CADisplayLink?
        private var finish: Task<Void, Never>?
        private var frames = MuzikaFrameMetrics()
        private var dragSample: WindowMoveSample?

        private struct WindowMoveSample {
            let time: Double
            let mouse: CGPoint
            let topLeft: CGPoint
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stop()
                lastState = nil
            } else {
                synchronize()
            }
        }

        func update(_ configuration: AnimationTraceProbe) {
            self.configuration = configuration
            synchronize()
        }

        func stop() {
            finishCapture(reason: "detached")
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
            dragSample = nil
        }

        private func synchronize() {
            let windowToObserve = configuration?.observesWindow == true ? window : nil
            if windowToObserve !== observedWindow {
                NotificationCenter.default.removeObserver(self)
                observedWindow = windowToObserve
                dragSample = nil
                if let windowToObserve {
                    let center = NotificationCenter.default
                    for name in [NSWindow.willMoveNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                 NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
                        center.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: windowToObserve)
                    }
                }
            }
            guard window != nil, let configuration, lastState != configuration.state else { return }
            finishCapture(reason: "superseded")
            lastState = configuration.state
            frames = MuzikaFrameMetrics()
            MuzikaTrace.event(configuration.area, "animation.observe.begin", configuration.state)
            let link = displayLink(target: self, selector: #selector(recordFrame))
            display = link
            link.add(to: .main, forMode: .common)
            finish = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(550)) }
                catch { return }
                self?.finishCapture(reason: "sample-ended")
            }
        }

        @objc private func recordFrame() {
            frames.record(at: CACurrentMediaTime())
        }

        private func finishCapture(reason: StaticString) {
            finish?.cancel()
            finish = nil
            guard let display else { return }
            display.invalidate()
            self.display = nil
            if let configuration {
                MuzikaTrace.event(configuration.area, "animation.observe.end",
                    "reason=\(reason) width_pt=\(bounds.width) height_pt=\(bounds.height) \(frames.summary)")
            }
        }

        @objc private func windowChanged(_ notification: Notification) {
            guard let window = observedWindow else { return }
            let frame = window.frame
            let dragging = NSEvent.pressedMouseButtons & 1 != 0
            let now = CACurrentMediaTime()
            let current = WindowMoveSample(time: now, mouse: NSEvent.mouseLocation,
                                           topLeft: CGPoint(x: frame.minX, y: frame.maxY))
            let previous = dragSample
            dragSample = dragging ? current : nil
            var mouseDelta = CGPoint.zero
            var windowDelta = CGPoint.zero
            if let previous, dragging, notification.name != NSWindow.willMoveNotification, now - previous.time < 0.25 {
                mouseDelta = CGPoint(x: current.mouse.x - previous.mouse.x, y: current.mouse.y - previous.mouse.y)
                windowDelta = CGPoint(x: current.topLeft.x - previous.topLeft.x, y: current.topLeft.y - previous.topLeft.y)
            }
            let drift = CGPoint(x: mouseDelta.x - windowDelta.x, y: mouseDelta.y - windowDelta.y)
            if notification.name == NSWindow.didMoveNotification, hypot(drift.x, drift.y) <= 1 { return }
            MuzikaTrace.event(.window, "geometry.changed",
                "event=\(notification.name.rawValue) dragging=\(dragging) cursor_dx_pt=\(drift.x) cursor_dy_pt=\(drift.y) mouse_dx_pt=\(mouseDelta.x) mouse_dy_pt=\(mouseDelta.y) window_dx_pt=\(windowDelta.x) window_dy_pt=\(windowDelta.y) width_pt=\(frame.width) height_pt=\(frame.height) scale=\(window.backingScaleFactor) titlebar_transparent=\(window.titlebarAppearsTransparent)")
        }
    }
}
#endif
