import AVFoundation
import Foundation
import MediaToolbox

nonisolated struct QueueOffsets: Sendable {
    let indices: Range<Int>

    func index(_ offset: Int) -> Int? {
        guard offset >= 0, offset < indices.count else { return nil }
        return indices.lowerBound + offset
    }

    func insertionIndex(_ offset: Int) -> Int? {
        offset == indices.count ? indices.upperBound : index(offset)
    }
}

@MainActor
final class QueuePlayback: PlaybackTransport {
    private let player = AVQueuePlayer()
    private let spatial: Bool
    private let mailbox = SpectrumMailbox()
    private lazy var analyzer = FrequencySpectrum(mailbox: mailbox)
    private var source: PCMPlayback.Source?
    private var item: AVPlayerItem?
    private var endObserver: (any NSObjectProtocol)?
    private var seekTask: Task<Void, Never>?
    private var failed = Set<UUID>()
    private var wantsSpectrum = false
    private var requestedPlayback = false
    private var reachedEnd = false
    private var reportedPosition = 0.0
    private var completedPosition: Double?

    var successor: ((UUID, Set<UUID>) -> PCMPlayback.Source?)?
    var onTransition: ((UUID) -> Void)?
    var onAdvance: ((UUID, Double) -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((UUID, Error) -> Void)?

    init(spatial: Bool) {
        self.spatial = spatial
        player.actionAtItemEnd = .pause
    }

    isolated deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        seekTask?.cancel()
    }

    var volume: Double {
        get { Double(player.volume) }
        set { player.volume = Float(newValue) }
    }

    var isRendering: Bool { seekTask == nil && player.timeControlStatus == .playing }

    var livePosition: Double? {
        guard let item else { return completedPosition }
        if seekTask != nil || !requestedPlayback { return reportedPosition }
        let time = item.currentTime().seconds
        return time.isFinite ? max(reportedPosition, time) : reportedPosition
    }

    func begin(_ source: PCMPlayback.Source, position: Double, play: Bool) {
        reset()
        requestedPlayback = play
        load(source, position: position)
    }

    func play() {
        guard item != nil else { return }
        requestedPlayback = true
        if seekTask == nil { player.play() }
    }

    func pause() {
        player.pause()
        reportProgress()
        requestedPlayback = false
    }

    func reset() {
        requestedPlayback = false
        failed.removeAll()
        completedPosition = nil
        clearItem()
    }

    func poll() {
        guard let item else { return }
        reportProgress()
        guard requestedPlayback else { return }
        if item.status == .failed {
            finishItem(error: item.error ?? CocoaError(.fileReadCorruptFile))
        } else if reachedEnd {
            finishItem(error: nil)
        }
    }

    func refreshSuccessor() { poll() }

    func setSpectrumEnabled(_ enabled: Bool) {
        guard wantsSpectrum != enabled else { return }
        wantsSpectrum = enabled
        analyzer.enable(enabled)
        updateTap()
    }

    func spectrum() -> [Float] { wantsSpectrum ? analyzer.read() : [] }

    private func load(_ source: PCMPlayback.Source, position: Double) {
        self.source = source
        reportedPosition = position
        let asset = AVURLAsset(url: source.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        item.allowedAudioSpatializationFormats = spatial ? .monoStereoAndMultichannel : []
        self.item = item
        updateTap()
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd = true }
        }
        player.insert(item, after: nil)
        let target = CMTime(seconds: position, preferredTimescale: 48_000)
        if position > 0, target.isNumeric {
            seekTask = Task { [weak self, weak item] in
                guard let self, let item else { return }
                let moved = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled, self.item === item else { return }
                seekTask = nil
                let actual = item.currentTime().seconds
                if actual.isFinite { reportedPosition = actual }
                if !moved, item.status == .failed { poll(); return }
                if requestedPlayback { player.play() }
            }
        } else {
            reportedPosition = 0
            if requestedPlayback { player.play() }
        }
    }

    private func updateTap() {
        guard let item else { return }
        item.audioMix = wantsSpectrum ? QueueSpectrumTap.makeMix(mailbox) : nil
    }

    private func reportProgress() {
        guard seekTask == nil, let id = source?.id, let time = livePosition, time > reportedPosition else { return }
        let elapsed = time - reportedPosition
        reportedPosition = time
        onAdvance?(id, elapsed)
    }

    private func finishItem(error: Error?) {
        guard let id = source?.id else { return }
        if let error {
            failed.insert(id)
            onError?(id, error)
        } else {
            failed.removeAll()
        }
        if let next = successor?(id, failed) {
            clearItem()
            load(next, position: 0)
            onTransition?(next.id)
        } else {
            let position = livePosition
            reset()
            completedPosition = position
            onEnd?()
        }
    }

    private func clearItem() {
        seekTask?.cancel()
        item?.cancelPendingSeeks()
        seekTask = nil
        reachedEnd = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.removeAllItems()
        item = nil
        source = nil
        if wantsSpectrum { analyzer.reset() }
    }
}

private nonisolated final class QueueSpectrumTap {
    private let mailbox: SpectrumMailbox
    private var supportedFormat = false

    init(_ mailbox: SpectrumMailbox) {
        self.mailbox = mailbox
    }

    static func makeMix(_ mailbox: SpectrumMailbox) -> AVAudioMix? {
        let state = QueueSpectrumTap(mailbox)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(state).toOpaque(),
            init: { _, client, storage in
                guard let client else { return }
                storage.pointee = Unmanaged<QueueSpectrumTap>.fromOpaque(client).retain().toOpaque()
            },
            finalize: { tap in
                Unmanaged<QueueSpectrumTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<QueueSpectrumTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let asbd = format.pointee
                state.supportedFormat = asbd.mFormatID == kAudioFormatLinearPCM
                    && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && asbd.mBitsPerChannel == 32
                    && asbd.mSampleRate == PCMStreamFormat.sampleRate
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, readFrames, flags in
                let result = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, nil, readFrames)
                guard result == noErr else { readFrames.pointee = 0; return }
                let state = Unmanaged<QueueSpectrumTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                if state.supportedFormat { state.mailbox.capture(buffers, frames: readFrames.pointee) }
            }
        )
        var tap: MTAudioProcessingTap?
        let result = withExtendedLifetime(state) {
            MTAudioProcessingTapCreateWithPreferredFormat(
                kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects,
                PCMStreamFormat.format.formatDescription, &tap
            )
        }
        guard result == noErr, let tap else { return nil }
        let parameters = AVMutableAudioMixInputParameters()
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
