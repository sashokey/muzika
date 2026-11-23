import Accelerate
import AVFAudio
import Foundation
import Synchronization

nonisolated final class SpectrumMailbox: @unchecked Sendable {
    static let frameCount = 2048

    let enabled = Atomic(false)
    private let busy = Atomic(false)
    private let epoch = Atomic<UInt64>(0)
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
    private var capturedEpoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var writeIndex = 0
    private var available = 0
    private var latest = ContinuousClock.now

    init() {
        samples.initialize(repeating: 0, count: Self.frameCount)
    }

    deinit {
        samples.deinitialize(count: Self.frameCount)
        samples.deallocate()
    }

    func capture(_ buffer: AVReadOnlyAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return }
        buffer.withUnsafeAudioBufferList {
            capture(UnsafeMutablePointer(mutating: $0), frames: buffer.frameLength)
        }
    }

    func capture(_ buffer: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer)
        guard let first = buffers.first, let data = first.mData else { return }
        let left = data.assumingMemoryBound(to: Float.self)
        let stride = Int(first.mNumberChannels)
        let right = stride > 1 ? left + 1 : buffers.dropFirst().first?.mData?.assumingMemoryBound(to: Float.self)
        capture(left, right: right, stride: stride, frames: frames)
    }

    func capture(_ left: UnsafePointer<Float>, right: UnsafePointer<Float>?, stride: Int, frames: Int) {
        let count = Self.frameCount
        guard enabled.load(ordering: .relaxed), frames > 0, stride > 0,
              busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return }
        defer { busy.store(false, ordering: .releasing) }
        let now = ContinuousClock.now
        let currentEpoch = epoch.load(ordering: .relaxed)
        if capturedEpoch != currentEpoch || now - latest >= .milliseconds(250) {
            capturedEpoch = currentEpoch
            available = 0
            writeIndex = 0
        }
        let length = min(frames, count)
        let start = (frames - length) * stride
        var channel = left
        if let right {
            var leftPower: Float = 0
            var rightPower: Float = 0
            for offset in 0..<length {
                let index = start + offset * stride
                let l = left[index]
                let r = right[index]
                leftPower += l * l
                rightPower += r * r
            }
            if rightPower > leftPower { channel = right }
        }
        for offset in 0..<length {
            samples[(writeIndex + offset) & (count - 1)] = channel[start + offset * stride]
        }
        writeIndex = (writeIndex + length) & (count - 1)
        available = min(count, available + length)
        latest = now
        generation &+= 1
    }

    func reset() {
        _ = epoch.wrappingAdd(1, ordering: .relaxed)
    }

    func snapshot(into destination: UnsafeMutableBufferPointer<Float>, since previous: UInt64) -> UInt64? {
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else {
            return previous
        }
        defer { busy.store(false, ordering: .releasing) }
        guard capturedEpoch == epoch.load(ordering: .relaxed), available == Self.frameCount,
              ContinuousClock.now - latest < .milliseconds(250),
              let start = destination.baseAddress else { return nil }
        if generation != previous {
            let suffix = Self.frameCount - writeIndex
            start.update(from: samples + writeIndex, count: suffix)
            (start + suffix).update(from: samples, count: writeIndex)
        }
        return generation
    }
}

@MainActor
final class FrequencySpectrum {
    private static let bandCount = 32
    private static let exponent: vDSP_Length = 11

    private let mailbox: SpectrumMailbox
    private let setup = vDSP_create_fftsetup(exponent, FFTRadix(kFFTRadix2))
    private let window = (0..<SpectrumMailbox.frameCount).map {
        0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(SpectrumMailbox.frameCount - 1))
    }
    private let bins = (0...bandCount).map {
        let frequency = 65 * pow(16_000 / 65.0, Double($0) / Double(bandCount))
        return Int(frequency / PCMStreamFormat.sampleRate * Double(SpectrumMailbox.frameCount))
    }
    private var real = [Float](repeating: 0, count: SpectrumMailbox.frameCount)
    private var imaginary = [Float](repeating: 0, count: SpectrumMailbox.frameCount)
    private var levels = [Float](repeating: 0, count: bandCount)
    private var generation: UInt64 = 0

    init(mailbox: SpectrumMailbox) {
        self.mailbox = mailbox
    }

    isolated deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func enable(_ enabled: Bool) {
        guard mailbox.enabled.load(ordering: .relaxed) != enabled else { return }
        mailbox.enabled.store(enabled, ordering: .relaxed)
        if !enabled { reset() }
    }

    func reset() {
        mailbox.reset()
        clearLevels()
    }

    private func clearLevels() {
        levels.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    func read() -> [Float] {
        guard mailbox.enabled.load(ordering: .relaxed), let setup else { return levels }
        let previous = generation
        guard let captured = real.withUnsafeMutableBufferPointer({
            mailbox.snapshot(into: $0, since: previous)
        }) else {
            clearLevels()
            return levels
        }
        generation = captured
        guard previous != generation else { return levels }
        for index in real.indices {
            real[index] *= window[index]
            imaginary[index] = 0
        }
        let exponent = Self.exponent
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, exponent, FFTDirection(FFT_FORWARD))
            }
        }
        let normalization = 4 / Float(SpectrumMailbox.frameCount)
        for band in levels.indices {
            let start = max(1, bins[band])
            let end = max(start + 1, bins[band + 1])
            var power: Float = 0
            for index in start..<end {
                let squared = real[index] * real[index] + imaginary[index] * imaginary[index]
                power = max(power, squared)
            }
            let magnitude = sqrt(power) * normalization
            let decibels = 20 * log10(max(0.00025, magnitude))
            let intensity = min(1, max(0, (decibels + 72) / 72))
            levels[band] = max(intensity, levels[band] * 0.75)
        }
        return levels
    }
}
