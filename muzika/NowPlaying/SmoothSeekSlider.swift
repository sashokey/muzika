import AppKit
import QuartzCore
import SwiftUI

struct SmoothSeekSlider: NSViewRepresentable {
    let duration: Double
    let snapshot: Double
    let entryID: UUID?
    let playing: Bool
    let isVisible: Bool
    let reduceMotion: Bool
    let controlSize: ControlSize
    let isRendering: @MainActor () -> Bool
    let livePosition: @MainActor () -> Double
    let preview: @MainActor (Double) -> Void
    let seek: @MainActor (Double) -> Void

    func makeNSView(context: Context) -> NativeSeekSlider {
        let slider = NativeSeekSlider(frame: .zero)
        slider.setAccessibilityLabel(String(localized: "Playback position"))
        return slider
    }

    func updateNSView(_ view: NativeSeekSlider, context: Context) { view.configure(self) }

    static func dismantleNSView(_ view: NativeSeekSlider, coordinator: ()) { view.stop() }
}

struct SeekDisplayClock {
    private var lastFrame: CFTimeInterval?
    private var lastSampleTime: CFTimeInterval = 0
    private var lastSample: Double = 0
    private var displayed: Double = 0

    mutating func reset() { lastFrame = nil }

    mutating func update(_ sample: Double, at time: CFTimeInterval) -> Double {
        guard let previousFrame = lastFrame, time >= previousFrame, time - previousFrame < 0.15,
              sample >= lastSample - 0.01, abs(sample - displayed) < 0.12 else {
            lastFrame = time
            lastSampleTime = time
            lastSample = sample
            displayed = sample
            return sample
        }

        let delta = time - previousFrame
        lastFrame = time
        if sample != lastSample {
            lastSampleTime = time
            lastSample = sample
        }

        let bound = sample + 0.065
        let expected = sample + min(0.065, time - lastSampleTime)
        let correction = min(delta * 0.25, max(-delta * 0.25, (expected - displayed - delta) * 0.18))
        displayed = max(displayed, min(bound, displayed + delta + correction))
        return displayed
    }
}

@MainActor
final class NativeSeekSlider: NSSlider {
    private var configuration: SmoothSeekSlider?
    private var clock = SeekDisplayClock()
    private var display: CADisplayLink?
    private var tracking = false
    private var changedWhileTracking = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = FractionalSeekCell()
        target = self
        action = #selector(positionChanged)
        isContinuous = true
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeDisplay()
    }

    func configure(_ next: SmoothSeekSlider) {
        if configuration?.entryID != next.entryID {
            clock.reset()
            changedWhileTracking = false
        }
        configuration = next
        let maximum = Self.maximum(for: next.duration)
        if maxValue != maximum { maxValue = maximum }
        let size: NSControl.ControlSize = next.controlSize == .large || next.controlSize == .extraLarge ? .large : .regular
        if controlSize != size { controlSize = size }
        if !tracking { redrawPosition() }
        synchronizeDisplay()
    }

    func stop() {
        display?.invalidate()
        display = nil
        clock.reset()
    }

    override func mouseDown(with event: NSEvent) {
        tracking = true
        changedWhileTracking = false
        stop()
        super.mouseDown(with: event)
        tracking = false
        if changedWhileTracking { configuration?.seek(doubleValue) }
        synchronizeDisplay()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else {
            super.keyDown(with: event)
            return
        }
        let direction: Double
        switch Int(key) {
        case NSLeftArrowFunctionKey:
            direction = userInterfaceLayoutDirection == .rightToLeft ? 1 : -1
        case NSRightArrowFunctionKey:
            direction = userInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        case NSDownArrowFunctionKey:
            direction = -1
        case NSUpArrowFunctionKey:
            direction = 1
        default:
            super.keyDown(with: event)
            return
        }
        let step = (maxValue - minValue) / 100
        doubleValue = min(maxValue, max(minValue, doubleValue + direction * step))
        positionChanged()
    }

    private func synchronizeDisplay() {
        let shouldRun = window != nil && !tracking && configuration?.playing == true &&
            configuration?.isVisible == true && configuration?.reduceMotion == false
        if shouldRun, display == nil {
            let link = displayLink(target: self, selector: #selector(redrawPosition))
            display = link
            link.add(to: .main, forMode: .common)
        } else if !shouldRun {
            stop()
        }
    }

    @objc private func redrawPosition() {
        guard !tracking, let configuration else { return }
        let position: Double
        if configuration.playing, configuration.isVisible, !configuration.reduceMotion, configuration.isRendering() {
            let current = configuration.livePosition()
            position = current.isFinite ? clock.update(current, at: CACurrentMediaTime()) : configuration.snapshot
        } else {
            clock.reset()
            position = configuration.snapshot
        }
        let bounded = position.isFinite ? min(max(0, position), maxValue) : 0
        if doubleValue != bounded { doubleValue = bounded }
    }

    @objc private func positionChanged() {
        clock.reset()
        if tracking {
            changedWhileTracking = true
            configuration?.preview(doubleValue)
        } else {
            configuration?.seek(doubleValue)
        }
    }

    private static func maximum(for duration: Double) -> Double {
        duration.isFinite ? max(0.01, duration) : 0.01
    }
}

@MainActor
private final class FractionalSeekCell: NSSliderCell {
    override func knobRect(flipped: Bool) -> NSRect {
        guard let view = controlView else { return super.knobRect(flipped: flipped) }
        let thumb = controlSize == .large ? CGSize(width: 24, height: 20) : CGSize(width: 20, height: 16)
        let progress = (doubleValue - minValue) / (maxValue - minValue)
        let fraction = view.userInterfaceLayoutDirection == .rightToLeft ? 1 - progress : progress
        let offset = max(0, view.bounds.width - thumb.width) * fraction
        return NSRect(x: view.bounds.minX + offset, y: view.bounds.midY - thumb.height / 2,
                      width: thumb.width, height: thumb.height)
    }

    override func barRect(flipped: Bool) -> NSRect {
        guard let view = controlView else { return super.barRect(flipped: flipped) }
        return NSRect(x: view.bounds.minX, y: view.bounds.midY - 3, width: view.bounds.width, height: 6)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let view = controlView else { return }
        let bar = barRect(flipped: flipped)
        NSColor.white.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        let center = knobRect(flipped: flipped).midX
        let rtl = view.userInterfaceLayoutDirection == .rightToLeft
        let length = rtl ? bar.maxX - center : center - bar.minX
        guard doubleValue > minValue, length > 0 else { return }
        let filled = NSRect(x: rtl ? center : bar.minX, y: bar.minY, width: length, height: bar.height)
        let tint = view.window?.isKeyWindow == true ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.45)
        tint.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
    }

    override func drawKnob(_ rect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }
}
