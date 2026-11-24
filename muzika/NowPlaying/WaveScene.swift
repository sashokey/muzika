import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct WaveClock {
    static let playerFramesPerSecond = 60
    static let artworkFramesPerSecond = 20

    private let frameInterval: TimeInterval
    private var lastRender: TimeInterval?

    init(framesPerSecond: Int = Self.playerFramesPerSecond) {
        frameInterval = 1 / Double(framesPerSecond)
    }

    mutating func delta(at timestamp: TimeInterval) -> TimeInterval? {
        let elapsed = lastRender.map { timestamp - $0 } ?? frameInterval
        guard elapsed >= frameInterval * 0.9 else { return nil }
        lastRender = timestamp
        return min(elapsed, 0.12)
    }
}

struct WaveHeightField {
    static let width = 64
    static let height = 48

    struct Surface {
        let height: Data
        let lighting: Data
    }

    private struct Coordinate {
        let sine: Double
        let cosine: Double
    }

    private static let coordinates = (0..<(width * height)).map { index in
        let x = Double(index % width) / Double(width - 1)
        let y = Double(index / width) / Double(height - 1)
        let flow = x * 5.9 + y * 3.8 + 0.77 * sin(y * 3)
        let bend = x * 3.4 - y * 5.4 + 0.6 * sin(x * 2.2 + y * 2) + 1.15
        return Coordinate(sine: 0.73 * sin(flow) + 0.27 * sin(bend),
                          cosine: 0.73 * cos(flow) + 0.27 * cos(bend))
    }

    private var pressure = SIMD3<Double>.zero
    private var velocity = SIMD3<Double>.zero
    private var phase = 0.0
    private var elevations = [Double](repeating: 0, count: width * height)

    mutating func samples(spectrum: [Float], delta: TimeInterval, crest: SIMD3<Double>, reflection: SIMD3<Double>) -> Surface? {
        let response = 4.5
        let decay = exp(-response * delta)
        for band in 0..<3 {
            let start = spectrum.count * band / 3
            let end = spectrum.count * (band + 1) / 3
            var sum = 0.0
            var peak = 0.0
            for index in start..<end {
                let value = spectrum[index]
                let level = value.isFinite ? min(1, max(0, (Double(value) - 0.12) / 0.88)) : 0
                sum += level * level
                peak = max(peak, level)
            }
            let rms = sqrt(sum / Double(max(1, end - start)))
            let target = rms * 0.86 + peak * 0.14
            let offset = pressure[band] - target
            let rate = velocity[band] + response * offset
            pressure[band] = target + (offset + rate * delta) * decay
            velocity[band] = (velocity[band] - response * rate * delta) * decay
        }

        let energy = pressure.x * 0.64 + pressure.y * 0.33 + pressure.z * 0.18
        phase = (phase + delta * (0.32 + energy * 0.14))
            .truncatingRemainder(dividingBy: 2 * .pi)
        guard energy > 0.001 else { return nil }

        let amplitude = energy / (0.35 + energy) * 0.225
        let pixelCount = Self.width * Self.height
        let sine = sin(phase) * amplitude
        let cosine = cos(phase) * amplitude
        for (index, coordinate) in Self.coordinates.enumerated() {
            elevations[index] = coordinate.sine * cosine - coordinate.cosine * sine
        }

        var height = Data(count: pixelCount * 4)
        var lighting = Data(count: pixelCount * 4)
        height.withUnsafeMutableBytes { heightBytes in
            lighting.withUnsafeMutableBytes { lightBytes in
                writeSurface(elevations, crest: crest, reflection: reflection, height: heightBytes, lighting: lightBytes)
            }
        }
        return Surface(height: height, lighting: lighting)
    }

    private func writeSurface(
        _ elevations: [Double], crest: SIMD3<Double>, reflection: SIMD3<Double>,
        height: UnsafeMutableRawBufferPointer, lighting: UnsafeMutableRawBufferPointer
    ) {
        let heightPixels = height.bindMemory(to: UInt8.self)
        let lightPixels = lighting.bindMemory(to: UInt8.self)
        for row in 0..<Self.height {
            let above = max(0, row - 1) * Self.width
            let below = min(Self.height - 1, row + 1) * Self.width
            let line = row * Self.width
            let yWeight = row == 0 || row == Self.height - 1 ? 7.2 : 3.6
            for column in 0..<Self.width {
                let left = max(0, column - 1)
                let right = min(Self.width - 1, column + 1)
                let xWeight = column == 0 || column == Self.width - 1 ? 2.4 : 1.2
                let slope = yWeight * (elevations[below + column] - elevations[above + column])
                    + xWeight * (elevations[line + right] - elevations[line + left])
                let slopePower = slope * slope
                let illumination = slopePower / (0.14 + slopePower)
                let index = (line + column) * 4
                let elevation = elevations[line + column]
                let light = max(0, elevation) * 1.55 + (slope > 0 ? illumination * 0.16 : 0)
                let tintedReflection = max(0, -elevation) * 2.45
                let shadow = slope < 0 ? illumination * 0.18 : 0
                let alpha = light + tintedReflection + shadow
                let color = crest * light + reflection * tintedReflection
                let gray = UInt8(((0.5 + elevation) * 255).rounded())
                heightPixels[index] = gray
                heightPixels[index + 1] = gray
                heightPixels[index + 2] = gray
                heightPixels[index + 3] = 255
                lightPixels[index] = UInt8((color.x * 255).rounded())
                lightPixels[index + 1] = UInt8((color.y * 255).rounded())
                lightPixels[index + 2] = UInt8((color.z * 255).rounded())
                lightPixels[index + 3] = UInt8((alpha * 255).rounded())
            }
        }
    }
}

struct WaveScene {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var heightField = WaveHeightField()
    private var cachedPalette: WavePalette?
    private var cachedExtent: CGRect = .zero
    private var baseImage: CIImage?

    static func drawableSize(for size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let ratio = min(1, 768 / max(size.width, size.height))
        return CGSize(
            width: max(1, (size.width * ratio).rounded(.down)),
            height: max(1, (size.height * ratio).rounded(.down))
        )
    }

    mutating func frame(palette: WavePalette, spectrum: [Float], delta: TimeInterval, extent: CGRect) -> CIImage {
        let base = background(palette: palette, extent: extent)
        guard let surface = heightField.samples(
            spectrum: spectrum, delta: delta, crest: palette.crest, reflection: palette.reflection
        ) else { return base }

        let width = WaveHeightField.width
        let height = WaveHeightField.height
        let longestSide = max(extent.width, extent.height)
        let softening = longestSide / 120
        let padding = (softening * 4).rounded(.up)
        let textureSide = longestSide + 2 * padding
        let size = CGSize(width: width, height: height)
        let scale = CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height))
        let map = CIImage(
            bitmapData: surface.height, bytesPerRow: width * 4, size: size,
            format: .RGBA8, colorSpace: nil
        ).clampedToExtent()
            .transformed(by: scale)
            .transformed(by: CGAffineTransform(translationX: padding, y: padding))
            .applyingGaussianBlur(sigma: softening)
            .cropped(to: CGRect(x: 0, y: 0, width: textureSide, height: textureSide))

        let glass = CIFilter.glassDistortion()
        glass.inputImage = base.clampedToExtent()
        glass.textureImage = map
        glass.center = CGPoint(x: -padding, y: -padding)
        glass.scale = Float(min(extent.width, extent.height)) * 15
        let shading = CIImage(
            bitmapData: surface.lighting, bytesPerRow: width * 4, size: size,
            format: .RGBA8, colorSpace: Self.colorSpace
        ).clampedToExtent().transformed(by: scale)
            .applyingGaussianBlur(sigma: longestSide / 180)
        return shading.composited(over: glass.outputImage ?? base).cropped(to: extent)
    }

    private mutating func background(palette: WavePalette, extent: CGRect) -> CIImage {
        if let baseImage, cachedPalette == palette, cachedExtent == extent { return baseImage }
        let size = max(extent.width, extent.height)
        let shadow = CIImage(color: CIColor(cgColor: palette.shadow.cgColor))
        let light = Self.glow(palette.highlight, x: extent.width * 0.19, y: extent.height * 0.74, radius: size * 0.69)
        let accent = Self.glow(palette.midtone, x: extent.width * 0.80, y: extent.height * 0.22, radius: size * 0.58)
        let crest = palette.crest
        let reflection = Self.glow(
            NSColor(srgbRed: crest.x, green: crest.y, blue: crest.z, alpha: 0.24),
            x: extent.width * 0.37, y: extent.height * 0.98, radius: size * 0.64
        )
        let base = reflection.composited(over: light.composited(over: accent.composited(over: shadow))).cropped(to: extent)
        cachedPalette = palette
        cachedExtent = extent
        baseImage = base
        return base
    }

    private static func glow(_ tone: NSColor, x: CGFloat, y: CGFloat, radius: CGFloat) -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: x, y: y)
        gradient.radius0 = 0
        gradient.radius1 = Float(radius)
        gradient.color0 = CIColor(cgColor: tone.cgColor)
        gradient.color1 = CIColor(cgColor: tone.withAlphaComponent(0).cgColor)
        return gradient.outputImage ?? CIImage.empty()
    }
}
