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

@MainActor
final class LyricsRowLayer {
    let layer = CALayer()
    private let blocks: [LyricsBlockLayer]
    private var appearance: Appearance?

    struct Appearance: Equatable {
        let singing: Bool
        let dimmed: Bool
        let hovered: Bool
        let softened: Bool
        let wordTime: Double
    }

    init(line: LyricsLine, typography: LyricsTypography, heights: [CGFloat], deviceScale: CGFloat, blur: Bool) {
        let indent: CGFloat = line.isBackground ? 16 : 0
        let width = max(1, typography.textWidth - indent)
        var y: CGFloat = 0
        blocks = zip(typography.blocks(for: line), heights).map { text, height in
            let block = LyricsBlockLayer(text: text, size: CGSize(width: width, height: height), scale: deviceScale, blur: blur)
            block.layer.frame.origin = CGPoint(x: indent, y: y)
            y += height + typography.auxiliarySpacing
            return block
        }
        layer.bounds.size = CGSize(width: typography.textWidth, height: max(0, y - typography.auxiliarySpacing))
        for block in blocks { layer.addSublayer(block.layer) }
    }

    func update(_ state: Appearance, animated: Bool) {
        guard state != appearance else { return }
        let animate = animated && appearance != nil
        appearance = state
        for block in blocks { block.update(state, animated: animate) }
    }
}

@MainActor
private final class LyricsBlockLayer {
    let layer = CALayer()
    private let base: CALayer
    private let sharp: CGImage?
    private var soft: CGImage?
    private var showingSoft = false
    private let permitsBlur: Bool
    private let text: LyricsTextBlock
    private let wordPaths: [CGPath?]
    private var wordTime: Double?
    private let completed = CALayer()
    private let current = CALayer()
    private let completedMask = CAShapeLayer()
    private let currentMask = CAShapeLayer()
    private static let blurContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])

    init(text: LyricsTextBlock, size: CGSize, scale: CGFloat, blur: Bool) {
        self.text = text
        permitsBlur = blur
        let rect = CGRect(origin: .zero, size: size)
        let setter = CTFramesetterCreateWithAttributedString(text.attributed)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        let primary = Self.image(frame, size: size, scale: scale, color: NSColor.white.cgColor)
        sharp = primary
        layer.frame = rect
        if let primary {
            base = CALayer()
            base.contents = primary
            wordPaths = Self.paths(in: frame, height: size.height, ranges: text.wordRanges)
            if !wordPaths.isEmpty {
                completed.contents = primary
                current.contents = Self.image(frame, size: size, scale: scale, color: NSColor.controlAccentColor.cgColor)
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
            wordPaths = []
        }
        base.frame = rect
        base.contentsScale = scale
        layer.addSublayer(base)
        if !wordPaths.isEmpty {
            layer.addSublayer(completed)
            layer.addSublayer(current)
        }
    }

    func update(_ appearance: LyricsRowLayer.Appearance, animated: Bool) {
        let wordsActive = appearance.singing && !wordPaths.isEmpty
        let opacity: Float = text.isPrimary
            ? (appearance.dimmed ? (appearance.hovered ? 0.75 : 0.5) : (wordsActive ? 0.65 : 1))
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
        let nextTime = wordsActive ? appearance.wordTime : nil
        if nextTime != wordTime {
            wordTime = nextTime
            completed.isHidden = nextTime == nil
            current.isHidden = nextTime == nil
            if let nextTime {
                let completedPath = CGMutablePath()
                let currentPath = CGMutablePath()
                for (word, path) in zip(text.words, wordPaths) {
                    guard let path else { continue }
                    if word.isActive(at: nextTime) { currentPath.addPath(path) }
                    else if (word.end ?? .infinity) <= nextTime { completedPath.addPath(path) }
                }
                completedMask.path = completedPath
                currentMask.path = currentPath
            }
        }
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

    private static func paths(in frame: CTFrame, height: CGFloat, ranges: [Range<Int>?]) -> [CGPath?] {
        guard !ranges.isEmpty else { return [] }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        let paths = ranges.map { _ in CGMutablePath() }
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
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
                for index in indices.indices {
                    let x = origin.x + positions[index].x
                    let next = x + advances[index].width
                    let rect = CGRect(x: min(x, next), y: height - origin.y - ascent,
                                      width: abs(next - x), height: ascent + descent)
                    for (path, range) in zip(paths, ranges) where range?.contains(indices[index]) == true {
                        path.addRect(rect)
                    }
                }
            }
        }
        return paths.map { $0.isEmpty ? nil : $0 }
    }
}
