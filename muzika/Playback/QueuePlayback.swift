import AVFoundation
import Foundation
import MediaToolbox
import Synchronization

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
    private lazy var audioInfoAnalyzer = AudioInfoSpectrum()
    private var audioInfoHistory: QueueAudioInfoHistory?
    private var source: PCMPlayback.Source?
    private var item: AVPlayerItem?
    private var endObserver: (any NSObjectProtocol)?
    private var seekTask: Task<Void, Never>?
    private var failed = Set<UUID>()
    private var wantsSpectrum = false
    private var wantsAudioInfoSpectrum = false
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

    func setAudioInfoSpectrumEnabled(_ enabled: Bool) {
        guard wantsAudioInfoSpectrum != enabled else { return }
        wantsAudioInfoSpectrum = enabled
        if !enabled { audioInfoAnalyzer.reset() }
        updateTap()
    }

    func audioInfoSpectrum() -> [Float] {
        guard wantsAudioInfoSpectrum, isRendering, let item, let audioInfoHistory else { return [] }
        let time = item.currentTime()
        let sampleRate = audioInfoHistory.sampleRate
        guard sampleRate > 0 else { return [] }
        if sampleRate != audioInfoAnalyzer.sampleRate { audioInfoAnalyzer = AudioInfoSpectrum(sampleRate: sampleRate) }
        return audioInfoAnalyzer.read { audioInfoHistory.read(at: time, sampleRate: sampleRate, left: $0, right: $1) }
    }

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
        guard wantsSpectrum || wantsAudioInfoSpectrum else {
            item.audioMix = nil
            audioInfoHistory = nil
            return
        }
        if let audioInfoHistory {
            audioInfoHistory.enabled.store(wantsAudioInfoSpectrum, ordering: .relaxed)
            return
        }
        let history = QueueAudioInfoHistory()
        history.enabled.store(wantsAudioInfoSpectrum, ordering: .relaxed)
        if let mix = QueueSpectrumTap.makeMix(mailbox, audioInfoHistory: history) {
            audioInfoHistory = history
            item.audioMix = mix
        }
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
        if wantsAudioInfoSpectrum { audioInfoAnalyzer.reset() }
        audioInfoHistory = nil
    }
}

private nonisolated final class QueueSpectrumTap {
    private let mailbox: SpectrumMailbox
    private let audioInfoHistory: QueueAudioInfoHistory
    private var sampleRate = 0.0

    init(_ mailbox: SpectrumMailbox, audioInfoHistory: QueueAudioInfoHistory) {
        self.mailbox = mailbox
        self.audioInfoHistory = audioInfoHistory
    }

    static func makeMix(_ mailbox: SpectrumMailbox, audioInfoHistory: QueueAudioInfoHistory) -> AVAudioMix? {
        let state = QueueSpectrumTap(mailbox, audioInfoHistory: audioInfoHistory)
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
                let supportedFormat = asbd.mFormatID == kAudioFormatLinearPCM
                    && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && asbd.mBitsPerChannel == 32
                state.sampleRate = supportedFormat ? asbd.mSampleRate : 0
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, readFrames, flags in
                var range = CMTimeRange.invalid
                let result = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &range, readFrames)
                guard result == noErr else { readFrames.pointee = 0; return }
                let state = Unmanaged<QueueSpectrumTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                if state.sampleRate == PCMStreamFormat.sampleRate { state.mailbox.capture(buffers, frames: readFrames.pointee) }
                state.audioInfoHistory.capture(buffers, frames: readFrames.pointee, at: range.start, sampleRate: state.sampleRate,
                                               startsStream: flags.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0)
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

private nonisolated final class QueueAudioInfoHistory: @unchecked Sendable {
    private static let capacity = 131_072
    let enabled = Atomic(false)
    private let version = Atomic<UInt64>(0)
    private let samples = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: capacity)
    private let rate = Atomic(0.0)
    private let firstFrame = Atomic<Int64>(0)
    private let endFrame = Atomic<Int64>(0)

    var sampleRate: Double { rate.load(ordering: .acquiring) }

    init() {
        for index in 0..<Self.capacity { (samples + index).initialize(to: Atomic(0)) }
    }

    deinit {
        samples.deinitialize(count: Self.capacity)
        samples.deallocate()
    }

    func capture(_ buffer: UnsafeMutablePointer<AudioBufferList>, frames: Int, at time: CMTime,
                 sampleRate: Double, startsStream: Bool) {
        guard enabled.load(ordering: .relaxed), frames > 0,
              let frame = Self.frame(at: time, sampleRate: sampleRate) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer)
        guard let first = buffers.first, let data = first.mData else { return }
        let stride = Int(first.mNumberChannels)
        guard stride > 0 else { return }
        let left = data.assumingMemoryBound(to: Float.self)
        let second = stride == 1 && buffers.count > 1 ? buffers[1] : nil
        let right = stride > 1 ? left + 1 : second?.mData?.assumingMemoryBound(to: Float.self) ?? left
        let leftFrames = Int(first.mDataByteSize) / (MemoryLayout<Float>.stride * stride)
        let rightFrames = second.map { Int($0.mDataByteSize) / MemoryLayout<Float>.stride } ?? leftFrames
        let count = min(frames, leftFrames, rightFrames)
        let previousVersion = version.load(ordering: .relaxed)
        guard count > 0, previousVersion.isMultiple(of: 2), version.compareExchange(expected: previousVersion,
              desired: previousVersion &+ 1, ordering: .sequentiallyConsistent).exchanged else { return }
        defer { version.store(previousVersion &+ 2, ordering: .sequentiallyConsistent) }

        let previousEnd = endFrame.load(ordering: .relaxed)
        let contiguous = !startsStream && self.sampleRate == sampleRate && abs(frame - previousEnd) <= 1
        let blockStart = contiguous ? previousEnd : frame
        let offset = max(0, count - Self.capacity)
        let end = blockStart + Int64(count)
        let start = contiguous ? firstFrame.load(ordering: .relaxed) : blockStart
        for index in offset..<count {
            let destination = Int(blockStart + Int64(index)) & (Self.capacity - 1)
            let bits = UInt64(left[index * stride].bitPattern) << 32 | UInt64(right[index * stride].bitPattern)
            samples[destination].store(bits, ordering: .relaxed)
        }
        firstFrame.store(max(start, end - Int64(Self.capacity)), ordering: .relaxed)
        endFrame.store(end, ordering: .relaxed)
        rate.store(sampleRate, ordering: .releasing)
    }

    func read(at time: CMTime, sampleRate: Double, left: UnsafeMutableBufferPointer<Float>,
              right: UnsafeMutableBufferPointer<Float>) -> AudioInfoSpectrum.Input {
        let snapshot = version.load(ordering: .sequentiallyConsistent)
        guard snapshot.isMultiple(of: 2), self.sampleRate == sampleRate else { return .retry }
        let start = firstFrame.load(ordering: .relaxed)
        let end = endFrame.load(ordering: .relaxed)
        guard let frame = Self.frame(at: time, sampleRate: sampleRate), start <= frame, frame < end else {
            return version.load(ordering: .sequentiallyConsistent) == snapshot ? .missing : .retry
        }
        let windowStart = frame - Int64(left.count / 2)
        left.update(repeating: 0)
        right.update(repeating: 0)
        let lower = max(start, windowStart)
        let upper = min(end, windowStart + Int64(left.count))
        for position in lower..<upper {
            let bits = samples[Int(position) & (Self.capacity - 1)].load(ordering: .relaxed)
            let index = Int(position - windowStart)
            left[index] = Float(bitPattern: UInt32(truncatingIfNeeded: bits >> 32))
            right[index] = Float(bitPattern: UInt32(truncatingIfNeeded: bits))
        }
        atomicMemoryFence(ordering: .acquiringAndReleasing)
        return version.load(ordering: .sequentiallyConsistent) == snapshot ? .samples(frame: frame, sampleRate: sampleRate) : .retry
    }

    private static func frame(at time: CMTime, sampleRate: Double) -> Int64? {
        guard time.isNumeric, sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 768_000 else { return nil }
        return Int64(exactly: (time.seconds * sampleRate).rounded())
    }
}
