import AVFAudio
import AudioToolbox
import Foundation

nonisolated enum PCMStreamFormat {
    static let sampleRate = 48_000.0
    static let channels: AVAudioChannelCount = 2
    static let chunkFrames: AVAudioFrameCount = 8192

    static var format: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }
}

nonisolated enum PCMStreamError: LocalizedError {
    case unsupportedFormat
    case noSamples

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: String(localized: "The audio format could not be decoded.")
        case .noSamples: String(localized: "The file contains no playable audio.")
        }
    }
}

nonisolated struct PCMChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private extension AVAudioFile {
    nonisolated func readPCMUntilEnd(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws -> Bool {
        let position = framePosition
        buffer.frameLength = 0
        do {
            try read(into: buffer, frameCount: frameCount)
            return buffer.frameLength == 0
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain
            && error.code == Int(kAudioFileEndOfFileError)
            && position > 0
            && length - position <= Int64(fileFormat.streamDescription.pointee.mFramesPerPacket) {
            return true
        }
    }
}

private nonisolated final class PCMConverterInput: @unchecked Sendable {
    let file: AVAudioFile
    var buffer: AVAudioPCMBuffer?
    var error: (any Error)?
    private var ended = false

    init(file: AVAudioFile) {
        self.file = file
    }

    func next(_ packets: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let remaining = max(0, file.length - file.framePosition)
        guard !ended, remaining > 0, error == nil, packets > 0 else {
            status.pointee = .endOfStream
            return nil
        }
        let frames = AVAudioFrameCount(min(remaining, Int64(packets)))
        if buffer == nil || buffer!.frameCapacity < frames {
            buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        }
        guard let buffer else {
            error = PCMStreamError.unsupportedFormat
            status.pointee = .endOfStream
            return nil
        }
        do {
            ended = try file.readPCMUntilEnd(into: buffer, frameCount: frames)
            let hasAudio = buffer.frameLength > 0
            status.pointee = hasAudio ? .haveData : .endOfStream
            return hasAudio ? buffer : nil
        } catch {
            self.error = error
            status.pointee = .endOfStream
            return nil
        }
    }
}

actor PCMStream {
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let input: PCMConverterInput?
    private var remainingFrames: AVAudioFramePosition
    private var ended = false
    let initialPosition: Double

    init(url: URL, position: Double) throws {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let output = PCMStreamFormat.format
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, file.length > 0 else {
            throw PCMStreamError.noSamples
        }
        let seconds = min(max(position, 0), Double(file.length) / inputFormat.sampleRate)
        let start = min(file.length, AVAudioFramePosition((seconds * inputFormat.sampleRate).rounded()))
        file.framePosition = start
        self.file = file
        let outputFrames = Double(file.length - start) * output.sampleRate / inputFormat.sampleRate
        self.remainingFrames = AVAudioFramePosition(outputFrames.rounded())
        self.initialPosition = Double(start) / inputFormat.sampleRate
        if inputFormat == output {
            self.converter = nil
            self.input = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: output) else {
                throw PCMStreamError.unsupportedFormat
            }
            converter.primeMethod = .none
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.converter = converter
            self.input = PCMConverterInput(file: file)
        }
    }

    func read() throws -> PCMChunk? {
        guard !ended, remainingFrames > 0 else { return nil }
        let frames = AVAudioFrameCount(min(remainingFrames, Int64(PCMStreamFormat.chunkFrames)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: PCMStreamFormat.format, frameCapacity: frames) else {
            throw PCMStreamError.unsupportedFormat
        }
        if let converter, let input {
            var conversionError: NSError?
            let result = converter.convert(to: buffer, error: &conversionError, withInputFrom: input.next)
            if let error = input.error ?? conversionError { throw error }
            if result == .error { throw PCMStreamError.unsupportedFormat }
            ended = result == .endOfStream
        } else {
            ended = try file.readPCMUntilEnd(into: buffer, frameCount: frames)
        }
        guard buffer.frameLength > 0 else {
            ended = true
            return nil
        }
        remainingFrames -= Int64(buffer.frameLength)
        return PCMChunk(buffer: buffer)
    }
}
