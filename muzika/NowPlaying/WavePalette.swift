import AppKit
import CryptoKit
import ImageIO

struct WavePalette: Equatable, Sendable {
    static let defaultPalette = Self(
        light: SIMD3(0.34, 0.43, 0.66),
        accent: SIMD3(0.23, 0.25, 0.45),
        dark: SIMD3(0.07, 0.10, 0.19)
    )

    private let light: SIMD3<Float>
    private let accent: SIMD3<Float>
    private let dark: SIMD3<Float>

    var highlight: NSColor { Self.color(light) }
    var midtone: NSColor { Self.color(accent) }
    var shadow: NSColor { Self.color(dark) }
    var crest: SIMD3<Double> { SIMD3<Double>(light) * 0.39 + SIMD3(repeating: 0.57) }
    var reflection: SIMD3<Double> { SIMD3<Double>(accent) * 1.42 + SIMD3(repeating: 0.09) }

    static func fromArtwork(_ data: Data) async -> Self {
        await WavePaletteCache.shared.palette(for: data)
    }

    fileprivate static func extract(_ data: Data) -> Self {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return .defaultPalette }

        let rowBytes = image.width * 4
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: rowBytes, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), let data = context.data else { return .defaultPalette }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var bins = [ColorBin](repeating: ColorBin(), count: 12)
        var neutral = ColorBin()
        for offset in stride(from: 0, to: rowBytes * image.height, by: 4) {
            let alpha = Float(pixels[offset + 3])
            guard alpha > 127 else { continue }

            let color = SIMD3(Float(pixels[offset]), Float(pixels[offset + 1]), Float(pixels[offset + 2])) / alpha
            let maximum = max(color.x, color.y, color.z)
            let chroma = maximum - min(color.x, color.y, color.z)
            neutral.add(color, weight: alpha / 255)

            guard chroma >= 0.12, maximum >= 0.18 else { continue }
            let hue: Float
            if maximum == color.x {
                hue = (color.y - color.z) / chroma
            } else if maximum == color.y {
                hue = 2 + (color.z - color.x) / chroma
            } else {
                hue = 4 + (color.x - color.y) / chroma
            }

            let index = (Int((hue * 2).rounded()) + bins.count) % bins.count
            bins[index].add(color, weight: chroma * (0.5 + maximum * 0.5) * alpha / 255)
        }

        guard neutral.weight > 0 else { return .defaultPalette }
        let ranked = bins.indices.filter { bins[$0].weight > 0 }.sorted { bins[$0].weight > bins[$1].weight }
        let primary = ranked.first.map { bins[$0].average } ?? neutral.average
        let secondary = ranked.first.flatMap { mainHue in
            func distance(to hue: Int) -> Int {
                let distance = abs(hue - mainHue)
                return min(distance, bins.count - distance)
            }
            return ranked.dropFirst().filter { bins[$0].weight >= bins[mainHue].weight * 0.18 && distance(to: $0) >= 3 }
                .max { distance(to: $0) < distance(to: $1) }
        }.map { bins[$0].average } ?? primary
        let blended = primary * 0.13 + secondary * 0.87
        return Self(
            light: primary * 0.56 + SIMD3(repeating: 0.12),
            accent: blended * 0.52 + SIMD3(repeating: 0.07),
            dark: secondary * 0.16 + SIMD3(repeating: 0.035)
        )
    }

    private static func color(_ value: SIMD3<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(value.x), green: CGFloat(value.y), blue: CGFloat(value.z), alpha: 1)
    }

    private struct ColorBin {
        var weight: Float = 0
        var total = SIMD3<Float>(repeating: 0)
        var average: SIMD3<Float> { total / weight }

        mutating func add(_ color: SIMD3<Float>, weight: Float) {
            self.weight += weight
            total += color * weight
        }
    }
}

private actor WavePaletteCache {
    static let shared = WavePaletteCache()

    private final class Entry {
        let palette: WavePalette

        init(_ palette: WavePalette) {
            self.palette = palette
        }
    }

    private let values: NSCache<NSData, Entry> = {
        let cache = NSCache<NSData, Entry>()
        cache.countLimit = 64
        return cache
    }()

    func palette(for data: Data) -> WavePalette {
        guard !Task.isCancelled else { return .defaultPalette }
        let key = Data(SHA256.hash(data: data)) as NSData
        if let entry = values.object(forKey: key) { return entry.palette }
        let palette = WavePalette.extract(data)
        values.setObject(Entry(palette), forKey: key)
        return palette
    }
}
