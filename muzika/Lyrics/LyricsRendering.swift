import AppKit
import CoreImage
import CoreText
import QuartzCore

nonisolated struct LyricsTypography: Equatable, Sendable {
    let width: CGFloat
    let scale: Double

    private var wide: Bool { width >= 500 }
    private var safeScale: Double { scale.isFinite ? min(1.4, max(0.8, scale)) : 1 }
    var textSize: CGFloat { (wide ? 30 : 21) * safeScale }
    var auxiliarySize: CGFloat { (wide ? 16 : 13) * safeScale }
    var auxiliarySpacing: CGFloat { wide ? 5 : 3 }
    var spacing: CGFloat { wide ? 22 : 15 }
    var horizontalInset: CGFloat { wide ? 44 : 22 }
    var containerWidth: CGFloat { wide ? min(width, 750) : width }
    var textWidth: CGFloat { max(1, containerWidth - 2 * horizontalInset) }

    func blocks(for line: LyricsLine) -> [LyricsTextBlock] {
        var blocks: [LyricsTextBlock] = []
        if let pronunciation = line.pronunciation {
            blocks.append(LyricsTextBlock(text: pronunciation, words: line.pronunciationWords, size: auxiliarySize,
                                          weight: .medium, isPrimary: false))
        }
        blocks.append(LyricsTextBlock(text: line.text, words: line.words, size: textSize * (line.isBackground ? 0.86 : 1),
                                      weight: .semibold, isPrimary: true))
        if let translation = line.translation {
            blocks.append(LyricsTextBlock(text: translation, words: line.translationWords, size: auxiliarySize,
                                          weight: .regular, isPrimary: false))
        }
        return blocks
    }
}

nonisolated struct LyricsTextBlock: Sendable {
    let text: String
    let words: [LyricsWord]
    let size: CGFloat
    let weight: NSFont.Weight
    let isPrimary: Bool

    var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
    }

    func height(at width: CGFloat) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let constraints = CGSize(width: width, height: .greatestFiniteMagnitude)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, constraints, nil)
        return ceil(max(size, measured.height)) + 1
    }

    var wordRanges: [Range<Int>?] {
        guard !words.isEmpty else { return [] }
        var offsets = [0]
        for character in text { offsets.append(offsets[offsets.count - 1] + String(character).utf16.count) }
        return words.map { word in
            guard word.range.lowerBound >= 0, word.range.upperBound < offsets.count else { return nil }
            return offsets[word.range.lowerBound]..<offsets[word.range.upperBound]
        }
    }
}

enum LyricsAccentMotion {
    case playing
    case paused
    case immediate
}

@MainActor
final class LyricsRowLayer {
    let layer = CALayer()
    private let blocks: [LyricsBlockLayer]
    private var appearance: Appearance?

    struct Appearance: Equatable {
        let singing: Bool
        let dimmed: Bool
        let idleOpacity: Float
        let hovered: Bool
        let softened: Bool
        let wordTime: Double
        let fillInterval: Range<Double>?
    }

    init(line: LyricsLine, typography: LyricsTypography, heights: [CGFloat], deviceScale: CGFloat, blur: Bool) {
        let indent: CGFloat = line.isBackground ? 16 : 0
        let width = max(1, typography.textWidth - indent)
        var y: CGFloat = 0
        blocks = zip(typography.blocks(for: line), heights).map { text, height in
            let block = LyricsBlockLayer(
                text: text, size: CGSize(width: width, height: height), scale: deviceScale, blur: blur,
                supportsLineFill: line.start != nil && text.isPrimary && text.words.isEmpty
            )
            block.layer.frame.origin = CGPoint(x: indent, y: y)
            y += height + typography.auxiliarySpacing
            return block
        }
        layer.bounds.size = CGSize(width: typography.textWidth, height: max(0, y - typography.auxiliarySpacing))
        for block in blocks { layer.addSublayer(block.layer) }
    }

    func update(_ state: Appearance, animated: Bool) {
        if !animated {
            for block in blocks { block.stopScaleAnimation() }
        }
        guard state != appearance else { return }
        let animate = animated && appearance != nil
        appearance = state
        for block in blocks { block.update(state, animated: animate) }
    }

    var hasLineFill: Bool { appearance?.fillInterval != nil }

    func paintLineFill(at position: Double) {
        for block in blocks { block.paintLineFill(at: position) }
    }

    func paintAccents(at position: Double, motion: LyricsAccentMotion, reposition: Bool = false) {
        for block in blocks { block.paintAccents(at: position, motion: motion, reposition: reposition) }
    }
}

@MainActor
private final class LyricsBlockLayer {
    private struct InkFragment {
        let bounds: CGRect
        let rightToLeft: Bool

        func append(to path: CGMutablePath, width: CGFloat) {
            let left = rightToLeft ? bounds.maxX - width : bounds.minX
            let right = left + width
            path.move(to: CGPoint(x: left, y: bounds.minY))
            path.addLine(to: CGPoint(x: right, y: bounds.minY))
            path.addLine(to: CGPoint(x: right, y: bounds.maxY))
            path.addLine(to: CGPoint(x: left, y: bounds.maxY))
            path.closeSubpath()
        }
    }

    private struct WordInk {
        let fragments: [InkFragment]
        let width: CGFloat
        let full: CGPath

        init(fragments: [InkFragment]) {
            self.fragments = fragments
            width = fragments.reduce(0) { $0 + $1.bounds.width }
            let path = CGMutablePath()
            for fragment in fragments { path.addRect(fragment.bounds) }
            full = path
        }

        func append(to path: CGMutablePath, progress: Double) {
            var remaining = CGFloat(progress) * width
            for fragment in fragments {
                let amount = min(remaining, fragment.bounds.width)
                fragment.append(to: path, width: amount)
                remaining -= amount
            }
        }

        func joins(during interval: Range<Double>) -> [Double] {
            guard width > 0 else { return [] }
            let duration = interval.upperBound - interval.lowerBound
            var distance: CGFloat = 0
            return fragments.dropLast().map { fragment in
                distance += fragment.bounds.width
                return interval.lowerBound + duration * Double(distance / width)
            }
        }
    }

    let layer = CALayer()
    private let base: CALayer
    private let sharp: CGImage?
    private var soft: CGImage?
    private var showingSoft = false
    private let permitsBlur: Bool
    private let text: LyricsTextBlock
    private let wordInk: [WordInk]
    private let lineInk: WordInk?
    private var fillInterval: Range<Double>?
    private var fillProgress: Double?
    private var wordTime: Double?
    private var activeWords: [Int] = []
    private var accentMotion: LyricsAccentMotion?
    private var accentPosition: Double?
    private let completed = CALayer()
    private let current = CALayer()
    private let completedMask = CAShapeLayer()
    private let currentMask = CAShapeLayer()
    private static let sweepKey = "lyrics-accent-sweep"
    private static let scaleKey = "lyrics-emphasis-scale"
    private static let blurContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])

    init(text: LyricsTextBlock, size: CGSize, scale: CGFloat, blur: Bool, supportsLineFill: Bool) {
        self.text = text
        permitsBlur = blur
        let rect = CGRect(origin: .zero, size: size)
        let setter = CTFramesetterCreateWithAttributedString(text.attributed)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        let primary = Self.image(frame, size: size, scale: scale, color: NSColor.white.cgColor)
        sharp = primary
        let firstLine = (CTFrameGetLines(frame) as? [CTLine])?.first
        let firstRun = firstLine.flatMap { (CTLineGetGlyphRuns($0) as? [CTRun])?.first }
        let rightToLeft = firstRun.map { CTRunGetStatus($0).contains(.rightToLeft) } ?? false
        layer.anchorPoint.x = rightToLeft ? 1 : 0
        layer.frame = rect
        if let primary {
            base = CALayer()
            base.contents = primary
            if supportsLineFill {
                let range = 0..<text.text.utf16.count
                lineInk = Self.wordGeometry(in: frame, height: size.height, ranges: [range]).first
                wordInk = []
            } else {
                lineInk = nil
                wordInk = Self.wordGeometry(in: frame, height: size.height, ranges: text.wordRanges)
            }
            if !wordInk.isEmpty || lineInk != nil {
                completed.contents = primary
                current.contents = lineInk != nil
                    ? primary : Self.image(frame, size: size, scale: scale, color: NSColor.controlAccentColor.cgColor)
                for (colored, mask) in [(completed, completedMask), (current, currentMask)] {
                    colored.frame = rect
                    colored.contentsScale = scale
                    mask.frame = rect
                    mask.fillColor = NSColor.white.cgColor
                    colored.mask = mask
                    colored.isHidden = true
                }
            }
        } else {
            let fallback = CATextLayer()
            fallback.string = text.attributed
            fallback.foregroundColor = NSColor.white.cgColor
            fallback.isWrapped = true
            fallback.alignmentMode = .natural
            base = fallback
            wordInk = []
            lineInk = nil
        }
        base.frame = rect
        base.contentsScale = scale
        layer.addSublayer(base)
        if !wordInk.isEmpty { layer.addSublayer(completed) }
        if !wordInk.isEmpty || lineInk != nil { layer.addSublayer(current) }
    }

    func update(_ appearance: LyricsRowLayer.Appearance, animated: Bool) {
        let wordsActive = appearance.singing && !wordInk.isEmpty
        let lineFills = appearance.fillInterval != nil && (lineInk?.width ?? 0) > 0
        let idle = appearance.hovered ? (appearance.idleOpacity + 1) / 2 : appearance.idleOpacity
        let opacity: Float = text.isPrimary
            ? (appearance.dimmed ? idle : (wordsActive || lineFills ? 0.65 : 1))
            : 0.65
        let oldOpacity = base.presentation()?.opacity ?? base.opacity
        if base.opacity != opacity {
            base.opacity = opacity
            if animated {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = oldOpacity
                fade.toValue = opacity
                fade.duration = 0.24
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                base.add(fade, forKey: "emphasis")
            } else {
                base.removeAnimation(forKey: "emphasis")
            }
        }
        if let sharp, appearance.softened != showingSoft {
            if appearance.softened && permitsBlur && soft == nil {
                let image = CIImage(cgImage: sharp)
                let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 0.65 * base.contentsScale)
                soft = Self.blurContext.createCGImage(blurred, from: image.extent)
            }
            showingSoft = appearance.softened
            base.contents = showingSoft ? (soft ?? sharp) : sharp
        }
        updateScale(appearance.dimmed ? 0.97 : 1, animated: animated)
        if lineInk != nil {
            let interval = lineFills ? appearance.fillInterval : nil
            if fillInterval != interval {
                #if MUZIKA_DEV_LOGS
                if let interval {
                    MuzikaTrace.event(.lyrics, "line.fill.begin",
                        "start_s=\(interval.lowerBound) end_s=\(interval.upperBound) fragments=\(lineInk?.fragments.count ?? 0) height_pt=\(layer.bounds.height)")
                } else {
                    MuzikaTrace.event(.lyrics, "line.fill.stop", "progress=\(fillProgress ?? 0)")
                }
                #endif
                fillInterval = interval
                fillProgress = nil
                current.isHidden = interval == nil
                currentMask.path = nil
            }
            return
        }
        let nextTime = wordsActive ? appearance.wordTime : nil
        if nextTime != wordTime {
            wordTime = nextTime
            completed.isHidden = nextTime == nil
            var nextActive: [Int] = []
            if let nextTime {
                let completedPath = CGMutablePath()
                for (index, word) in text.words.enumerated() {
                    let ink = wordInk[index]
                    guard ink.width > 0 else { continue }
                    if word.isActive(at: nextTime) { nextActive.append(index) }
                    else if (word.end ?? .infinity) <= nextTime { completedPath.addPath(ink.full) }
                }
                completedMask.path = completedPath
            }
            if activeWords != nextActive {
                activeWords = nextActive
                accentMotion = nil
                accentPosition = nil
                currentMask.removeAnimation(forKey: Self.sweepKey)
                current.isHidden = nextActive.isEmpty
            }
        }
    }

    private func updateScale(_ scale: CGFloat, animated: Bool) {
        guard layer.transform.m11 != scale else { return }
        let start = layer.presentation()?.transform.m11 ?? layer.transform.m11
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        if animated {
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = start
            animation.toValue = scale
            animation.duration = 0.34
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: Self.scaleKey)
        }
    }

    func stopScaleAnimation() {
        layer.removeAnimation(forKey: Self.scaleKey)
    }

    func paintLineFill(at position: Double) {
        guard let fillInterval, let lineInk else { return }
        let duration = fillInterval.upperBound - fillInterval.lowerBound
        let progress = min(1, max(0, (position - fillInterval.lowerBound) / duration))
        guard fillProgress != progress else { return }
        fillProgress = progress
        let path = CGMutablePath()
        if progress >= 1 {
            path.addRect(layer.bounds)
        } else if progress > 0 {
            lineInk.append(to: path, progress: progress)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentMask.path = path
        CATransaction.commit()
    }

    func paintAccents(at position: Double, motion: LyricsAccentMotion, reposition: Bool) {
        guard !activeWords.isEmpty else { return }
        if !reposition, accentMotion == motion, motion != .paused || accentPosition == position { return }
        accentMotion = motion
        accentPosition = position
        currentMask.removeAnimation(forKey: Self.sweepKey)

        let partial = accentMask(at: position, wholeWord: motion == .immediate)
        guard motion == .playing else {
            currentMask.path = partial
            return
        }

        let stops = activeWords.flatMap { index -> [Double] in
            guard let interval = interval(for: text.words[index]) else { return [] }
            return wordInk[index].joins(during: interval) + [interval.upperBound]
        }
        let times = Set(stops.filter { $0 > position }).sorted()
        guard let end = times.last, (end - position).isFinite else {
            currentMask.path = partial
            return
        }
        let points = [position] + times
        let animation = CAKeyframeAnimation(keyPath: "path")
        let paths = [partial] + times.map { accentMask(at: $0, wholeWord: false) }
        animation.values = paths
        animation.duration = end - position
        #if MUZIKA_DEV_LOGS
        if reposition {
            MuzikaTrace.event(.lyrics, "word.sweep.reposition",
                "active_words=\(activeWords.count) stops=\(times.count) duration_s=\(animation.duration)")
        }
        #endif
        animation.keyTimes = points.map { NSNumber(value: ($0 - position) / animation.duration) }
        animation.calculationMode = .linear
        currentMask.path = paths.last
        currentMask.add(animation, forKey: Self.sweepKey)
    }

    private func accentMask(at position: Double, wholeWord: Bool) -> CGPath {
        let path = CGMutablePath()
        for index in activeWords {
            let progress: Double
            if !wholeWord, let interval = interval(for: text.words[index]) {
                progress = min(1, max(0, (position - interval.lowerBound) / (interval.upperBound - interval.lowerBound)))
            } else {
                progress = 1
            }
            wordInk[index].append(to: path, progress: progress)
        }
        return path
    }

    private func interval(for word: LyricsWord) -> Range<Double>? {
        guard let end = word.end, word.start.isFinite, end.isFinite, word.start < end,
              (end - word.start).isFinite else { return nil }
        return word.start..<end
    }

    private static func image(_ frame: CTFrame, size: CGSize, scale: CGFloat, color: CGColor) -> CGImage? {
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, height <= 4_096, width <= 8_000_000 / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(color)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    private static func wordGeometry(in frame: CTFrame, height: CGFloat, ranges: [Range<Int>?]) -> [WordInk] {
        guard !ranges.isEmpty else { return [] }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        var fragments = Array(repeating: [InkFragment](), count: ranges.count)
        for (line, origin) in zip(lines, origins) {
            let runs = (CTLineGetGlyphRuns(line) as! [CTRun]).sorted {
                CTRunGetStringRange($0).location < CTRunGetStringRange($1).location
            }
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                var indices = [CFIndex](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                _ = CTRunGetTypographicBounds(run, CFRange(), &ascent, &descent, nil)
                CTRunGetStringIndices(run, CFRange(), &indices)
                CTRunGetPositions(run, CFRange(), &positions)
                CTRunGetAdvances(run, CFRange(), &advances)
                var runBounds = [CGRect?](repeating: nil, count: ranges.count)
                for index in indices.indices {
                    let x = origin.x + positions[index].x
                    let next = x + advances[index].width
                    let rect = CGRect(x: min(x, next), y: height - origin.y - ascent,
                                      width: abs(next - x), height: ascent + descent)
                    for (word, range) in ranges.enumerated() where range?.contains(indices[index]) == true {
                        runBounds[word] = runBounds[word]?.union(rect) ?? rect
                    }
                }
                let rightToLeft = CTRunGetStatus(run).contains(.rightToLeft)
                for (word, bounds) in runBounds.enumerated() {
                    guard let bounds, bounds.width > 0 else { continue }
                    fragments[word].append(InkFragment(bounds: bounds, rightToLeft: rightToLeft))
                }
            }
        }
        return fragments.map(WordInk.init)
    }
}
