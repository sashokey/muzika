import AppKit
import CoreText
import QuartzCore

@MainActor
final class LyricsCountdownLayer {
    let layer = CALayer()
    private let muted = CALayer()
    private let ink = CALayer()
    private let mask = CALayer()
    private let solid = CALayer()
    private let edge = CAGradientLayer()
    private var key: Key?
    private var currentProgress: Double?

    private struct Key: Equatable {
        let seconds: String
        let maximum: String
        let scale: CGFloat
    }

    init() {
        muted.opacity = 0.65
        layer.addSublayer(muted)
        layer.addSublayer(ink)
        solid.backgroundColor = NSColor.white.cgColor
        edge.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
        edge.startPoint = CGPoint(x: 0, y: 0.5)
        edge.endPoint = CGPoint(x: 1, y: 0.5)
        mask.addSublayer(solid)
        mask.addSublayer(edge)
        ink.mask = mask
    }

    func update(gap: LyricsGap, at time: Double, scale: CGFloat, reduceMotion: Bool) {
        let duration = gap.end - gap.start
        let proposal = Key(seconds: format(gap.end - time), maximum: format(duration), scale: scale)
        if key != proposal {
            key = proposal
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .semibold)
            let line = Self.line(for: proposal.seconds, font: font)
            let longest = Self.line(for: proposal.maximum, font: font)
            let textWidth = max(CTLineGetTypographicBounds(longest, nil, nil, nil), CTLineGetTypographicBounds(line, nil, nil, nil))
            let size = CGSize(width: ceil(textWidth) + 25, height: 28)
            layer.frame.size = size
            let rect = CGRect(origin: .zero, size: size)
            let image = Self.image(line, size: size, scale: scale)
            for item in [muted, ink] {
                item.frame = rect
                item.contentsScale = scale
                item.contents = image
            }
            mask.frame = rect
            currentProgress = nil
        }
        ink.isHidden = reduceMotion
        if !reduceMotion { setProgress((time - gap.start) / duration) }
    }

    func setProgress(_ progress: Double) {
        let value = min(1, max(0, progress))
        guard value != currentProgress else { return }
        currentProgress = value
        let width = layer.bounds.width
        let height = layer.bounds.height
        let feather = min(width, 6)
        let position = value * (width + feather) - feather
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        solid.frame = CGRect(x: 0, y: 0, width: max(0, position), height: height)
        edge.frame = CGRect(x: position, y: 0, width: feather, height: height)
        CATransaction.commit()
    }

    private func format(_ duration: Double) -> String {
        max(1, duration.rounded(.up)).formatted(.number.precision(.fractionLength(0)))
    }

    private static func line(for seconds: String, font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(
            string: String(localized: "Instrumental · \(seconds)s"),
            attributes: [.font: font, .foregroundColor: NSColor.white]
        ))
    }

    private static func image(_ line: CTLine, size: CGSize, scale: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: 24, y: (size.height - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
        let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white])))
        if let symbol {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let height = min(16, symbol.size.height)
            let width = symbol.size.height > 0 ? symbol.size.width * height / symbol.size.height : 0
            symbol.draw(in: CGRect(x: (17 - width) / 2, y: (size.height - height) / 2, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }
}
