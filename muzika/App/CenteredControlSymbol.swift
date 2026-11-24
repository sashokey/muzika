import AppKit
import SwiftUI

@MainActor
struct CenteredControlSymbol: View {
    let name: String
    let size: CGSize
    var symbolScale: CGFloat = 1
    var pointSize: CGFloat = 15
    var weight: NSFont.Weight = .semibold

    @Environment(\.layoutDirection) private var layoutDirection
    private static let rasterScale: CGFloat = 8
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()

    var body: some View {
        let symbol = name == "chevron.backward" ? (layoutDirection == .rightToLeft ? "chevron.right" : "chevron.left") : name
        let glyph = Self.glyph(symbol, size: pointSize, weight: weight)
        Canvas { context, size in
            let midpoint = CGPoint(x: size.width / 2, y: size.height / 2)
            if let glyph {
                let image = Image(decorative: glyph, scale: Self.rasterScale).renderingMode(.template)
                let width = CGFloat(glyph.width) / Self.rasterScale * symbolScale
                let height = CGFloat(glyph.height) / Self.rasterScale * symbolScale
                context.draw(image, in: CGRect(x: midpoint.x - width / 2, y: midpoint.y - height / 2,
                                               width: width, height: height))
            } else {
                let fontWeight: Font.Weight = weight == .semibold ? .semibold : .regular
                context.draw(Text(Image(systemName: symbol))
                    .font(.system(size: pointSize * symbolScale, weight: fontWeight)), at: midpoint)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private static func glyph(_ name: String, size: CGFloat, weight: NSFont.Weight) -> CGImage? {
        let key = "\(name):\(size):\(weight.rawValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return nil }

        let width = Int(ceil(symbol.size.width * rasterScale))
        let height = Int(ceil(symbol.size.height * rasterScale))
        guard width > 0, height > 0,
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        bitmap.scaleBy(x: rasterScale, y: rasterScale)
        symbol.draw(in: CGRect(origin: .zero, size: symbol.size))
        NSGraphicsContext.restoreGraphicsState()

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for y in 0..<height {
            for x in 0..<width where pixels[y * bitmap.bytesPerRow + x * 4 + 3] > 8 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX, minY <= maxY,
              let glyph = bitmap.makeImage()?.cropping(to: CGRect(x: minX, y: minY,
                                                                  width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        cache.setObject(glyph, forKey: key)
        return glyph
    }
}
