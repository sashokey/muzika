import Accelerate
import Foundation

@MainActor
final class AudioInfoSpectrum {
    nonisolated enum Input {
        case samples(frame: Int64, sampleRate: Double)
        case missing
        case retry
    }

    nonisolated static let pcmFrameCount = 2048
    private static let bandCount = 16
    private static let edges = (0...bandCount).map { 65 * pow(16_000 / 65.0, Double($0) / Double(bandCount)) }

    let sampleRate: Double
    private let exponent: vDSP_Length
    private let setup: FFTSetup?
    private let window: [Float]
    private let powerScale: Float
    private var left: [Float]
    private var right: [Float]
    private var imaginary: [Float]
    private var binPower: [Float]
    private var currentLevels = [Float](repeating: 0, count: bandCount)
    private var previousFrame: Int64?
    private var previousRate = 0.0

    init(sampleRate: Double = PCMStreamFormat.sampleRate) {
        self.sampleRate = sampleRate
        let additional = max(0, Int(ceil(log2(sampleRate / PCMStreamFormat.sampleRate))))
        let count = Self.pcmFrameCount << additional
        exponent = vDSP_Length(count.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(exponent, FFTRadix(kFFTRadix2))
        window = (0..<count).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(count - 1)) }
        powerScale = 2 / (Float(count) * window.reduce(0) { $0 + $1 * $1 })
        left = Array(repeating: 0, count: count)
        right = Array(repeating: 0, count: count)
        imaginary = Array(repeating: 0, count: count)
        binPower = Array(repeating: 0, count: count / 2)
    }

    isolated deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func reset() {
        previousFrame = nil
        currentLevels.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    func read(_ load: (
        UnsafeMutableBufferPointer<Float>, UnsafeMutableBufferPointer<Float>
    ) -> Input) -> [Float] {
        guard let setup else { return [] }
        let input = left.withUnsafeMutableBufferPointer { left in
            right.withUnsafeMutableBufferPointer { load(left, $0) }
        }
        if case .retry = input { return previousFrame == nil ? [] : currentLevels }
        guard case let .samples(frame, rate) = input else {
            reset()
            return []
        }
        if rate != previousRate { reset() }
        if frame == previousFrame { return currentLevels }

        let elapsed = previousFrame.map { Double(frame - $0) / rate } ?? 0
        let decay = elapsed > 0 && elapsed < 0.25 ? Float(exp(-elapsed / 0.08)) : 0
        previousFrame = frame
        previousRate = rate

        let window = window
        for index in window.indices {
            left[index] *= window[index]
            right[index] *= window[index]
        }
        binPower.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        Self.addPower(left: &left, imaginary: &imaginary, power: &binPower, setup: setup, exponent: exponent)
        Self.addPower(left: &right, imaginary: &imaginary, power: &binPower, setup: setup, exponent: exponent)

        let binsPerHertz = Double(window.count) / rate
        for band in currentLevels.indices {
            let start = min(binPower.count, Int(ceil(Self.edges[band] * binsPerHertz)))
            let end = min(binPower.count, Int(ceil(Self.edges[band + 1] * binsPerHertz)))
            let power = binPower[start..<end].reduce(0, +) * powerScale
            let decibels = 10 * log10(max(0.000001, power))
            let level = min(1, max(0, (decibels + 60) / 60))
            currentLevels[band] = max(level, currentLevels[band] * decay)
        }
        return currentLevels
    }

    private static func addPower(left: inout [Float], imaginary: inout [Float], power: inout [Float], setup: FFTSetup,
                                 exponent: vDSP_Length) {
        imaginary.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        left.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, exponent, FFTDirection(FFT_FORWARD))
                for bin in power.indices {
                    power[bin] += real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                }
            }
        }
    }
}
