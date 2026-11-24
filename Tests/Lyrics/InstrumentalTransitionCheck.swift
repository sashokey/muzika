import AppKit
import QuartzCore

@MainActor
private final class CheckPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@main
@MainActor
private final class InstrumentalTransitionCheck: NSObject, NSApplicationDelegate {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() async {
        let app = NSApplication.shared
        let check = InstrumentalTransitionCheck()
        if !CommandLine.arguments.contains("--visible") {
            await check.checkAndExit()
            return
        }
        app.setActivationPolicy(.accessory)
        app.delegate = check
        withExtendedLifetime(check) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await checkAndExit() }
    }

    private func checkAndExit() async {
        do {
            try await run()
            print("Instrumental transition checks passed.")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private func run() async throws {
        let rect = CGRect(x: 0, y: 0, width: 460, height: 400)
        let window = CheckPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.ignoresMouseEvents = true
        if CommandLine.arguments.contains("--visible") {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != CGMainDisplayID()
            }) else { throw Failure(description: "Secondary display unavailable") }
            let area = screen.visibleFrame
            window.hidesOnDeactivate = false
            window.setFrameOrigin(CGPoint(x: area.maxX - rect.width, y: area.minY))
            window.orderFrontRegardless()
            try expect(!window.isKeyWindow && !NSApp.isActive, "The check window took focus")
        }
        let view = TimedLyricsScrollView(frame: rect)
        window.contentView = view
        defer { view.stop(); window.orderOut(nil) }
        let document = LyricsDocument(lines: [
            LyricsLine(id: 0, text: "First vocal line", start: 5, end: 6),
            LyricsLine(id: 1, text: "Second vocal line", start: 6, end: 7),
            LyricsLine(id: 2, text: "Vocal line after the break", start: 10, end: 11),
            LyricsLine(id: 3, text: "Last vocal line", start: 11, end: 12),
        ])
        func apply(_ time: Double, reduceMotion: Bool = false) {
            view.configure(TimedLyricsConfiguration(document: document, position: { time }, pausedPosition: time,
                                                    playing: false, offset: 0, textSize: 1, blur: false,
                                                    reduceMotion: reduceMotion, topOverflow: 0, seek: { _ in }))
        }

        for (time, index) in [(5.0, 0), (10.0, 2)] {
            apply(time - 0.1)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let tiles = try require(view.documentView?.layer?.sublayers?.first, "Lyrics did not lay out")
            let rows = tiles.sublayers?.filter { $0.bounds.width == 416 }.sorted { $0.frame.minY < $1.frame.minY } ?? []
            try expect(rows.count == document.lines.count, "Expected all four rows in the viewport reserve")
            let line = rows[index]
            let ink = try require(line.sublayers?.first?.sublayers?.first, "Missing text layer")
            let countdown = try require(tiles.sublayers?.first { $0.bounds.height == 28 && $0.bounds.width < 416 }, "Missing countdown")
            let preceding = index == 0 ? nil : rows[index - 1]
            let before = screenY(line, tiles: tiles, view: view)
            let precedingY = preceding.map { screenY($0, tiles: tiles, view: view) }
            let countdownY = screenY(countdown, tiles: tiles, view: view)
            let anchor = view.contentSize.height * 0.36
            apply(time)

            let scroll = try require(tiles.animation(forKey: "lyrics-scroll") as? CABasicAnimation, "Missing scroll easing")
            let start = screenY(line, tiles: tiles, view: view) + number(scroll.fromValue)
            try expect(abs(start - before) < 0.75, "Incoming line jumped by \(start - before) pt")
            try expect(countdown.superlayer === tiles, "Countdown vanished in one frame")
            try expect(abs(screenY(countdown, tiles: tiles, view: view) - countdownY) < 0.75, "Countdown moved before fading")
            try expect(countdown.opacity == 0 && ink.opacity == 1, "Incorrect final countdown or emphasis opacity")

            if window.isVisible {
                if let preceding, let precedingY {
                    let offset = (preceding.animation(forKey: "lyrics-gap-position") as? CABasicAnimation)?.fromValue
                    let start = screenY(preceding, tiles: tiles, view: view) + (offset.map { number($0) - preceding.position.y } ?? 0)
                    try expect(abs(start - precedingY) < 0.75, "Preceding line jumped by \(start - precedingY) pt")
                }
                let fade = try require(countdown.animation(forKey: "lyrics-countdown-fade") as? CABasicAnimation, "Missing countdown fade")
                let emphasis = try require(ink.animation(forKey: "emphasis") as? CABasicAnimation, "Incoming line changed brightness in one frame")
                try expect(number(fade.fromValue) == 1 && number(fade.toValue) == 0, "Incorrect countdown fade range")
                try expect(number(emphasis.fromValue) == 0.5 && number(emphasis.toValue) == 1, "Incorrect emphasis range")
                try await Task.sleep(for: .milliseconds(80))
                try expect(window.occlusionState.contains(.visible) && !window.isKeyWindow && !NSApp.isActive, "The check window lost visibility or took focus")
                let middle = screenY(line, tiles: tiles, view: view, presented: true)
                let opacity = try require(countdown.presentation()?.opacity, "Missing presented countdown")
                let brightness = try require(ink.presentation()?.opacity, "Missing presented text")
                try expect(anchor < middle && middle < before, "Incoming line did not move through an intermediate position")
                try expect(0 < opacity && opacity < 1, "Countdown did not pass through an intermediate opacity")
                try expect(0.5 < brightness && brightness < 1, "Incoming line did not pass through an intermediate brightness")
                if let preceding, let precedingY {
                    let middleY = screenY(preceding, tiles: tiles, view: view, presented: true)
                    try expect(abs(middleY - precedingY) < 1.5, "Preceding line moved by \(middleY - precedingY) pt during the transition")
                }
                try await Task.sleep(for: .milliseconds(65))
                let later = screenY(line, tiles: tiles, view: view, presented: true)
                let remainingOpacity = try require(countdown.presentation()?.opacity, "Countdown ended early")
                try expect(anchor < later && later < middle, "Incoming line did not move monotonically")
                try expect(0 < remainingOpacity && remainingOpacity < opacity, "Countdown brightness did not decrease monotonically")
            }
            try await Task.sleep(for: .milliseconds(330))
            if window.isVisible {
                try expect(countdown.superlayer == nil, "Faded countdown was not removed")
                try expect(abs(screenY(line, tiles: tiles, view: view) - anchor) < 0.75, "Incoming line did not settle on the 36% anchor")
            }
        }
        apply(9.9, reduceMotion: true)
        let tiles = try require(view.documentView?.layer?.sublayers?.first, "Missing lyrics layers")
        let countdown = try require(tiles.sublayers?.first { $0.bounds.height == 28 && $0.bounds.width < 416 }, "Missing Reduce Motion countdown")
        apply(10, reduceMotion: true)
        try expect(countdown.superlayer == nil && tiles.animation(forKey: "lyrics-scroll") == nil, "Reduce Motion must follow immediately")

        if window.isVisible {
            apply(9.9)
            try await Task.sleep(for: .milliseconds(330))
            apply(10)
            try await Task.sleep(for: .milliseconds(70))
            apply(9.9)
            try await Task.sleep(for: .milliseconds(330))
            try expect(countdown.superlayer === tiles && countdown.opacity == 1, "Seeking into Instrumental did not restore the countdown")
        }
    }

    private func screenY(_ layer: CALayer, tiles: CALayer, view: TimedLyricsScrollView, presented: Bool = false) -> CGFloat {
        let rowY = presented ? layer.presentation()?.frame.minY ?? layer.frame.minY : layer.frame.minY
        let translation = presented ? tiles.presentation()?.transform.m42 ?? 0 : 0
        return rowY + translation - view.contentView.bounds.minY
    }

    private func number(_ value: Any?) -> CGFloat {
        CGFloat((value as? NSNumber)?.doubleValue ?? .nan)
    }

    private func expect(_ result: @autoclosure () -> Bool, _ message: String) throws {
        if !result() { throw Failure(description: message) }
    }

    private func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw Failure(description: message) }
        return value
    }
}
