import AVFoundation
import CoreMedia
import Foundation

@MainActor
final class SpatialPCMOutput {
    private static let timescale: CMTimeScale = 48_000
    private let renderer: AVSampleBufferAudioRenderer
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let receiver: AVSampleBufferAudioRenderer.Receiver

    init() {
        let renderer = AVSampleBufferAudioRenderer()
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        self.renderer = renderer
        self.receiver = synchronizer.sampleBufferReceiver(adding: renderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    var volume: Double {
        get { Double(renderer.volume) }
        set { renderer.volume = Float(newValue) }
    }

    var isPlaying: Bool { synchronizer.rate > 0 }

    var renderedFrame: AVAudioFramePosition? {
        let time = synchronizer.currentTime()
        return time.isNumeric ? time.convertScale(Self.timescale, method: .roundTowardZero).value : nil
    }

    func play() { synchronizer.rate = 1 }

    func pause() { synchronizer.rate = 0 }

    func reset() {
        synchronizer.setRate(0, time: .zero)
        receiver.flush()
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition) throws -> Bool {
        let samples = CMReadOnlyDataBlockBuffer(CMMutableDataBlockBuffer(copying: buffer.audioBufferList))
        let sampleBuffer = CMReadySampleBuffer(
            audioDataBuffer: samples, formatDescription: buffer.format.formatDescription,
            sampleCount: Int(buffer.frameLength), presentationTimeStamp: CMTime(value: frame, timescale: Self.timescale)
        )
        switch receiver.enqueueImmediately(CMReadySampleBuffer(sampleBuffer)) {
        case .enqueued:
            return true
        case .enqueuedWithSuggestedFlush(let reasons):
            return !reasons.contains { reason in
                if case .wasFlushedAutomatically = reason { return true }
                return false
            }
        case .cancelledDueToFlush:
            return false
        case .cancelledDueToError(let error):
            throw error
        @unknown default:
            throw PCMStreamError.unsupportedFormat
        }
    }
}
