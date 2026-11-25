import AppKit
import QuartzCore
import SwiftUI

struct UntimedLyricsScrollDriver: NSViewRepresentable {
    let position: @MainActor () -> Double
    let positionSnapshot: Double
    let duration: Double?
    let playing: Bool
    let visible: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.configure(self)
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) {
        anchor.stop()
    }

    final class Anchor: NSView {
        private struct ReturnMotion {
            let origin: CGFloat
            let started: CFTimeInterval
        }

        private static let returnDuration = 0.34
        private var configuration: UntimedLyricsScrollDriver?
        private weak var scroll: NSScrollView?
        private var link: CADisplayLink?
        private var resume: Task<Void, Never>?
        private var liveScrolling = false
        private var isHolding = false
        private var returnMotion: ReturnMotion?
        #if MUZIKA_DEV_LOGS
        private var frames = MuzikaFrameMetrics()
        private var reportedBottom = false
        #endif

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
            reflectPlayback()
        }

        override func layout() {
            super.layout()
            connect()
            reflectPlayback()
        }

        func configure(_ value: UntimedLyricsScrollDriver) {
            configuration = value
            connect()
            reflectPlayback()
        }

        func stop() {
            #if MUZIKA_DEV_LOGS
            if link != nil { MuzikaTrace.event(.lyrics, "untimed.clock.detached", frames.summary) }
            #endif
            resume?.cancel()
            resume = nil
            link?.invalidate()
            link = nil
            NotificationCenter.default.removeObserver(self)
            scroll = nil
            liveScrolling = false
            isHolding = false
            returnMotion = nil
        }

        private func connect() {
            let next = window == nil ? nil : enclosingScrollView
            guard next !== scroll else { return }
            stop()
            guard let next else { return }
            scroll = next
            #if MUZIKA_DEV_LOGS
            MuzikaTrace.event(.lyrics, "untimed.attach")
            #endif
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(startedScrolling), name: NSScrollView.willStartLiveScrollNotification, object: next)
            center.addObserver(self, selector: #selector(didScroll), name: NSScrollView.didLiveScrollNotification, object: next)
            center.addObserver(self, selector: #selector(endedScrolling), name: NSScrollView.didEndLiveScrollNotification, object: next)
        }

        @objc private func startedScrolling() {
            #if MUZIKA_DEV_LOGS
            MuzikaTrace.event(.lyrics, "untimed.manual.begin")
            #endif
            liveScrolling = true
            holdPosition()
        }

        @objc private func didScroll() {
            holdPosition()
            if !liveScrolling { scheduleResume() }
        }

        @objc private func endedScrolling() {
            #if MUZIKA_DEV_LOGS
            MuzikaTrace.event(.lyrics, "untimed.manual.end", "resume_delay_s=\(LyricsScrollTiming.manualHold)")
            #endif
            liveScrolling = false
            scheduleResume()
        }

        private func holdPosition() {
            isHolding = true
            returnMotion = nil
            resume?.cancel()
            resume = nil
            synchronizeClock()
        }

        private func scheduleResume() {
            resume?.cancel()
            resume = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(LyricsScrollTiming.manualHold)) }
                catch { return }
                guard let self else { return }
                isHolding = false
                #if MUZIKA_DEV_LOGS
                MuzikaTrace.event(.lyrics, "untimed.manual.resume", "animated=\(configuration?.reduceMotion == false)")
                #endif
                if let scroll, configuration?.reduceMotion == false {
                    returnMotion = ReturnMotion(origin: scroll.contentView.bounds.minY, started: CACurrentMediaTime())
                }
                reflectPlayback()
                guard returnMotion != nil else { return }
                do { try await Task.sleep(for: .seconds(Self.returnDuration)) }
                catch { return }
                returnMotion = nil
                reflectPlayback()
            }
        }

        private func synchronizeClock() {
            let hasDuration = configuration?.duration.map { $0.isFinite && $0 > 0 } ?? false
            let shouldRun = scroll != nil && hasDuration && configuration?.visible == true && !isHolding &&
                ((configuration?.playing == true && configuration?.reduceMotion == false) || returnMotion != nil)
            if shouldRun, link == nil {
                #if MUZIKA_DEV_LOGS
                frames = MuzikaFrameMetrics()
                MuzikaTrace.event(.lyrics, "untimed.clock.start")
                let display = displayLink(target: self, selector: #selector(traceFrame))
                #else
                let display = displayLink(target: self, selector: #selector(reflectPlayback))
                #endif
                link = display
                display.add(to: .main, forMode: .common)
            } else if !shouldRun, let link {
                #if MUZIKA_DEV_LOGS
                MuzikaTrace.event(.lyrics, "untimed.clock.stop", "\(frames.summary)")
                #endif
                link.invalidate()
                self.link = nil
            }
        }

        #if MUZIKA_DEV_LOGS
        @objc private func traceFrame() {
            reflectPlayback()
            frames.record(at: CACurrentMediaTime(), position: scroll.map { Double($0.contentView.bounds.minY) })
            frames.reportIfReady(.lyrics, "untimed.frames")
        }
        #endif

        @objc private func reflectPlayback() {
            defer { synchronizeClock() }
            guard !isHolding, let scroll, let configuration, configuration.visible,
                  let duration = configuration.duration, duration.isFinite, duration > 0 else { return }
            let clip = scroll.contentView
            let range = clip.documentRect
            let extent = range.height - clip.bounds.height
            guard extent > 0 else {
                returnMotion = nil
                return
            }

            let time = configuration.playing ? configuration.position() : configuration.positionSnapshot
            guard time.isFinite else { return }
            let fraction = min(1, max(0, time / duration))
            #if MUZIKA_DEV_LOGS
            if fraction == 1, !reportedBottom {
                MuzikaTrace.event(.lyrics, "untimed.bottom", "duration_s=\(duration) scrollable_pt=\(extent)")
            }
            reportedBottom = fraction == 1
            #endif
            let target = range.minY + extent * (clip.isFlipped ? fraction : 1 - fraction)
            var y = target
            if let returnMotion {
                let fractionOfReturn = (CACurrentMediaTime() - returnMotion.started) / Self.returnDuration
                if fractionOfReturn < 1, fraction < 1 {
                    let progress = fractionOfReturn * fractionOfReturn * (3 - 2 * fractionOfReturn)
                    y = returnMotion.origin + (target - returnMotion.origin) * progress
                } else {
                    self.returnMotion = nil
                }
            }
            guard abs(clip.bounds.minY - y) > 0.05 else { return }
            clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }

        isolated deinit {
            resume?.cancel()
            link?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }
    }
}
