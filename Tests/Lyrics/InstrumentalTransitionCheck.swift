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
            }) ?? NSScreen.main else { throw Failure(description: "No display available") }
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
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
        func apply(_ time: Double, reduceMotion: Bool = false, lyrics: LyricsDocument? = nil, playing: Bool = false) {
            view.configure(TimedLyricsConfiguration(document: lyrics ?? document, position: { time },
                                                    pausedPosition: playing ? nil : time, playing: playing, offset: 0, textSize: 1, blur: false,
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
            try expect(countdown.opacity == 0 && ink.opacity == 0.65, "The next lyric must start at its unfilled brightness")

            if window.isVisible {
                if let preceding, let precedingY {
                    let offset = (preceding.animation(forKey: "lyrics-gap-position") as? CABasicAnimation)?.fromValue
                    let start = screenY(preceding, tiles: tiles, view: view) + (offset.map { number($0) - preceding.position.y } ?? 0)
                    try expect(abs(start - precedingY) < 0.75, "Preceding line jumped by \(start - precedingY) pt")
                }
                let fade = try require(countdown.animation(forKey: "lyrics-countdown-fade") as? CABasicAnimation, "Missing countdown fade")
                let emphasis = try require(ink.animation(forKey: "emphasis") as? CABasicAnimation, "Incoming line changed brightness in one frame")
                try expect(number(fade.fromValue) == 1 && number(fade.toValue) == 0, "Incorrect countdown fade range")
                try expect(number(emphasis.fromValue) == 0.5 && abs(number(emphasis.toValue) - 0.65) < 0.001, "Incorrect emphasis range")
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

        let leadIn = LyricsDocument(lines: [
            LyricsLine(id: 0, text: "First vocal line", start: 1, end: 2),
            LyricsLine(id: 1, text: "Next vocal line", start: 2, end: 3),
        ])
        func rowOpacities() -> [Float] {
            (tiles.sublayers ?? []).sorted { $0.frame.minY < $1.frame.minY }.compactMap {
                $0.sublayers?.first?.sublayers?.first?.opacity
            }
        }
        apply(0, reduceMotion: true, lyrics: leadIn)
        for _ in 0..<40 where rowOpacities().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(rowOpacities() == [0.5, 0.5], "The first lead-in frame must show both inactive rows dimmed")
        apply(1, reduceMotion: true, lyrics: leadIn)
        try expect(rowOpacities() == [1, 0.5], "Only the first row should brighten at its cue")

        for (word, growsLeft) in [("Melody", false), ("מנגינה", true)] {
            let lyrics = LyricsDocument(lines: [
                LyricsLine(id: 0, text: word, start: 0, end: 1,
                           words: [LyricsWord(id: 0, start: 0, end: 1, range: 0..<word.count)]),
            ])
            func accentMask() throws -> CAShapeLayer {
                let block = try require(tiles.sublayers?.first?.sublayers?.first, "Missing timed word block")
                return try require(block.sublayers?.last?.mask as? CAShapeLayer, "Missing word accent mask")
            }
            func accentBounds() throws -> CGRect {
                try require(accentMask().path?.boundingBox, "Missing word accent geometry")
            }
            apply(0.2, lyrics: lyrics)
            for _ in 0..<40 {
                if (try? accentBounds()) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let start = try accentBounds()
            apply(0.8, lyrics: lyrics)
            let later = try accentBounds()
            try expect(start.width > 0 && later.width > start.width, "Accent must grow within the same word")
            try expect(growsLeft ? later.maxX == start.maxX : later.minX == start.minX,
                       "Accent starts from the wrong edge")
            apply(0.3, lyrics: lyrics)
            let rewound = try accentBounds()
            try expect(rewound.width < later.width, "Seeking back must restore the word's earlier progress")
            apply(0.2, reduceMotion: true, lyrics: lyrics)
            let still = try accentBounds()
            apply(0.8, reduceMotion: true, lyrics: lyrics)
            let stillLater = try accentBounds()
            try expect(stillLater == still && still.width >= later.width,
                       "Reduce Motion must keep the active word uniformly accented")

            apply(0.25, lyrics: lyrics, playing: true)
            let mask = try accentMask()
            if window.isVisible {
                let sweep = try require(mask.animation(forKey: "lyrics-accent-sweep") as? CAKeyframeAnimation,
                                        "The compositor did not receive a word sweep")
                let paths = try require(sweep.values as? [CGPath], "Missing sweep frames")
                try expect(abs(sweep.duration - 0.75) < 0.001 && (paths.first?.boundingBox.width ?? 0) < still.width,
                           "Sweep should start at the sampled fraction and finish at the word boundary")
            }
            let target = try accentBounds()
            try expect(target == still, "The sweep target should include the complete word")
            apply(0.65, lyrics: lyrics, playing: true)
            if window.isVisible {
                let sweep = try require(mask.animation(forKey: "lyrics-accent-sweep") as? CAKeyframeAnimation,
                                        "Seeking did not replace the word sweep")
                try expect(abs(sweep.duration - 0.35) < 0.001, "Seeking must start the compositor at the new word fraction")
            }
            apply(0.5, lyrics: lyrics)
            try expect(mask.animation(forKey: "lyrics-accent-sweep") == nil, "Pausing must cancel the live sweep")
        }

        let wrappedWord = String(repeating: "W", count: 42)
        let wrapped = LyricsDocument(lines: [
            LyricsLine(id: 0, text: wrappedWord, start: 0, end: 1,
                       words: [LyricsWord(id: 0, start: 0, end: 1, range: 0..<wrappedWord.count)]),
        ])
        func wrappedMask() -> CGPath? {
            let block = tiles.sublayers?.first?.sublayers?.first
            return (block?.sublayers?.last?.mask as? CAShapeLayer)?.path
        }
        apply(0.25, lyrics: wrapped)
        for _ in 0..<40 where wrappedMask() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstPart = try require(wrappedMask(), "Missing wrapped accent")
        apply(0.99, lyrics: wrapped)
        let almostComplete = try require(wrappedMask(), "Missing wrapped continuation")
        let lastRow = almostComplete.boundingBox.maxY - 1
        let spans = stride(from: 3.0, to: almostComplete.boundingBox.maxX, by: 3)
        let lowerRowAccented = spans.contains { almostComplete.contains(CGPoint(x: $0, y: lastRow)) }
        let lowerRowTooEarly = spans.contains { firstPart.contains(CGPoint(x: $0, y: lastRow)) }
        try expect(lowerRowAccented && !lowerRowTooEarly, "A wrapped word must finish its first row before lighting the continuation")

        let phrases = LyricsDocument(lines: (0..<4).map { index in
            LyricsLine(id: index, text: "Vocal phrase", start: Double(index), end: Double(index + 1))
        })
        apply(0.5, reduceMotion: true, lyrics: phrases)
        for _ in 0..<40 where rowOpacities().count != 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let gradient = rowOpacities()
        try expect(gradient == [1, 0.5, 0.46, 0.42], "Distant phrases should recede without changing cue selection")
        let rows = (tiles.sublayers ?? []).sorted { $0.frame.minY < $1.frame.minY }
        try expect(rows.count == 4, "Missing lyric rows in emphasis check")
        let ink = try require(rows[1].sublayers?.first, "Missing primary lyric ink")
        try expect(ink.transform.m11 < 1, "An upcoming line without word timings should be slightly smaller")
        apply(0.96, lyrics: phrases, playing: true)
        apply(1.01, lyrics: phrases, playing: true)
        try expect(ink.transform.m11 == 1, "The active line should grow to its full size")
        if window.isVisible {
            let scale = try require(ink.animation(forKey: "lyrics-emphasis-scale") as? CABasicAnimation,
                                    "The newly active phrase must animate to full size")
            try expect(number(scale.fromValue) < 1 && number(scale.toValue) == 1,
                       "The active phrase must start at its previous size")
            let followingRows = try rows.suffix(2).map {
                try require($0.animation(forKey: "lyrics-row-stagger") as? CAKeyframeAnimation,
                            "Subsequent phrases must follow with a stagger")
            }
            let peaks = followingRows.map { ($0.values as? [NSNumber])?.dropFirst().first?.doubleValue ?? 0 }
            try expect(peaks[0] > 0 && peaks[1] > peaks[0],
                       "The scroll lag should increase with distance from the active phrase")
            try await Task.sleep(for: .milliseconds(120))
            let scaleInFlight = try require(ink.presentation()?.transform.m11, "Missing presented line scale")
            let rowLag = try rows.suffix(2).map {
                try require($0.presentation()?.transform.m42, "Missing presented row lag")
            }
            try expect(scaleInFlight > 0.97 && scaleInFlight < 1, "The line did not appear at an intermediate scale")
            try expect(rowLag[0] > 0 && rowLag[1] > rowLag[0], "The stagger was not visible in the presented rows")
        }
        apply(1.01, reduceMotion: true, lyrics: phrases)
        try expect(ink.animation(forKey: "lyrics-emphasis-scale") == nil, "Reduce Motion must stop the scale animation")
        try expect(rows.allSatisfy { $0.animation(forKey: "lyrics-row-stagger") == nil },
                   "Reduce Motion must stop the scroll stagger")
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
