import AVFAudio
import Foundation

@MainActor
final class PCMPlayback: PlaybackTransport {
    enum Mode { case realtime, offline }

    struct Source {
        let id: UUID
        let url: URL
        let lease: SecurityScopeLease?
    }

    private final class Segment {
        let source: Source
        let startFrame: AVAudioFramePosition
        var initialPosition: Double
        var decoder: PCMStream?
        var finalFrame: AVAudioFramePosition?

        init(source: Source, startFrame: AVAudioFramePosition, position: Double) {
            self.source = source
            self.startFrame = startFrame
            self.initialPosition = position
        }
    }

    private let engine: AVAudioEngine?
    private let player: AVAudioPlayerNode?
    private let spatialOutput: SpatialPCMOutput?
    private let mode: Mode
    private let spectrumMailbox = SpectrumMailbox()
    private lazy var analyzer = FrequencySpectrum(mailbox: spectrumMailbox)
    private var tapInstalled = false
    private var spatialSpectrumEnabled = false
    private var spatialSpectrumFrames: [(start: AVAudioFramePosition, buffer: AVAudioPCMBuffer)] = []
    private var lastSpectrumFrame: AVAudioFramePosition = 0
    private static let bufferedFrames: Int64 = 48_000
    private static let startupFrames: Int64 = 12_000
    private var segments: [Segment] = []
    private var pendingRead: Task<Void, Never>?
    private var scheduledFrame: AVAudioFramePosition = 0
    private var reportedFrame: AVAudioFramePosition = 0
    private var manualStartFrame: AVAudioFramePosition = 0
    private var requestedPlayback = false
    private var started = false
    private var streamEnded = false
    private var failed = Set<UUID>()
    private var completedPosition: Double?

    var successor: ((UUID, Set<UUID>) -> Source?)?
    var onTransition: ((UUID) -> Void)?
    var onAdvance: ((UUID, Double) -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((UUID, Error) -> Void)?

    init(mode: Mode = .realtime, spatial: Bool = false) throws {
        self.mode = mode
        if mode == .realtime, spatial {
            spatialOutput = SpatialPCMOutput()
            engine = nil
            player = nil
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        self.engine = engine
        self.player = player
        spatialOutput = nil
        engine.attach(player)
        try engine.connectNode(player, to: engine.mainMixerNode, format: PCMStreamFormat.format)
        if mode == .offline {
            try engine.enableManualRenderingMode(.offline, format: PCMStreamFormat.format, maximumFrameCount: 4096)
        }
    }

    var volume: Double {
        get { spatialOutput?.volume ?? Double(engine?.mainMixerNode.outputVolume ?? 1) }
        set {
            spatialOutput?.volume = newValue
            engine?.mainMixerNode.outputVolume = Float(newValue)
        }
    }

    func setSpectrumEnabled(_ enabled: Bool) {
        if spatialOutput != nil {
            guard spatialSpectrumEnabled != enabled else { return }
            spatialSpectrumEnabled = enabled
            if !enabled { spatialSpectrumFrames.removeAll(keepingCapacity: true) }
            analyzer.enable(enabled)
            return
        }
        guard let player else { return }
        guard enabled || tapInstalled else { return }
        if enabled, !tapInstalled {
            let mailbox = spectrumMailbox
            do {
                try player.installAudioTap(onBus: 0, bufferSize: 4800, format: nil) { buffer, _ in
                    mailbox.capture(buffer)
                }
                tapInstalled = true
            } catch {
                return
            }
        }
        analyzer.enable(enabled)
        if !enabled, tapInstalled {
            player.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    func spectrum() -> [Float] {
        if spatialSpectrumEnabled {
            let frame = renderedFrame
            if frame > lastSpectrumFrame, let chunk = spatialSpectrumFrames.first(where: {
                $0.start < frame && frame <= $0.start + Int64($0.buffer.frameLength)
            }), let channels = chunk.buffer.floatChannelData {
                let count = min(SpectrumMailbox.frameCount, Int(frame - chunk.start))
                let start = Int(frame - chunk.start) - count
                if count == SpectrumMailbox.frameCount {
                    spectrumMailbox.capture(channels[0] + start, right: channels[1] + start, stride: 1, frames: count)
                    lastSpectrumFrame = frame
                }
            }
        }
        return analyzer.read()
    }

    var isRendering: Bool {
        (spatialOutput?.isPlaying ?? player?.isPlaying ?? false) && renderedFrame < scheduledFrame
    }

    var livePosition: Double? {
        guard let segment = segments.first else { return completedPosition }
        let frame = min(renderedFrame, segment.finalFrame ?? scheduledFrame)
        return segment.initialPosition + Double(max(0, frame - segment.startFrame)) / PCMStreamFormat.sampleRate
    }

    private var renderedFrame: AVAudioFramePosition {
        guard started else { return reportedFrame }
        if let spatialOutput {
            return min(scheduledFrame, max(reportedFrame, spatialOutput.renderedFrame ?? reportedFrame))
        }
        if mode == .offline, let engine {
            return min(scheduledFrame, max(reportedFrame, engine.manualRenderingSampleTime - manualStartFrame))
        }
        guard let nodeTime = player?.lastRenderTime, nodeTime.isSampleTimeValid,
              let time = player?.playerTime(forNodeTime: nodeTime), time.isSampleTimeValid,
              time.sampleRate > 0 else { return reportedFrame }
        let sample = AVAudioFramePosition(Double(time.sampleTime) * PCMStreamFormat.sampleRate / time.sampleRate)
        return min(scheduledFrame, max(reportedFrame, sample))
    }

    var readyForOfflineRender: Bool {
        player?.isPlaying == true && (streamEnded || scheduledFrame - renderedFrame >= 512)
    }

    func render(_ frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let engine else { throw PCMStreamError.unsupportedFormat }
        let buffer = AVAudioPCMBuffer(pcmFormat: PCMStreamFormat.format, frameCapacity: frameCount)!
        _ = try engine.renderOffline(frameCount, to: buffer)
        return buffer
    }

    func begin(_ source: Source, position: Double, play: Bool) {
        reset()
        requestedPlayback = play
        segments = [Segment(source: source, startFrame: 0, position: position)]
        if play { fill() }
    }

    func play() {
        guard !segments.isEmpty else { return }
        requestedPlayback = true
        fill()
        startIfReady()
    }

    func pause() {
        requestedPlayback = false
        player?.pause()
        spatialOutput?.pause()
        updateRenderedProgress()
        if mode == .realtime { engine?.pause() }
    }

    func reset() {
        requestedPlayback = false
        pendingRead?.cancel()
        pendingRead = nil
        player?.stop()
        if mode == .realtime, engine?.isRunning == true { engine?.stop() }
        spatialOutput?.reset()
        if tapInstalled || spatialSpectrumEnabled { analyzer.reset() }
        spatialSpectrumFrames.removeAll(keepingCapacity: true)
        lastSpectrumFrame = 0
        segments.removeAll()
        streamEnded = false
        failed.removeAll()
        started = false
        scheduledFrame = 0
        reportedFrame = 0
        completedPosition = nil
    }

    func refreshSuccessor() {
        updateRenderedProgress()
        guard let current = segments.first else { return }
        let candidate = successor?(current.source.id, failed)
        if segments.count > 1, segments[1].source.id != candidate?.id {
            begin(current.source, position: livePosition ?? current.initialPosition, play: requestedPlayback)
            return
        }
        streamEnded = false
        fill()
    }

    func poll() {
        if requestedPlayback || started { updateRenderedProgress() }
        if mode == .realtime, requestedPlayback, started, engine?.isRunning == false,
           let current = segments.first {
            begin(current.source, position: livePosition ?? current.initialPosition, play: true)
        } else {
            fill()
        }
    }

    private func updateRenderedProgress() {
        guard started else { return }
        let now = renderedFrame
        if spatialSpectrumEnabled {
            spatialSpectrumFrames.removeAll { $0.start + Int64($0.buffer.frameLength) < now }
        }
        while let segment = segments.first {
            let end = segment.finalFrame ?? scheduledFrame
            let consumed = min(end, now)
            if consumed > reportedFrame {
                let interval = Double(consumed - reportedFrame) / PCMStreamFormat.sampleRate
                reportedFrame = consumed
                onAdvance?(segment.source.id, interval)
            }
            guard let final = segment.finalFrame, now >= final else { return }
            if segments.count > 1 {
                let following = segments[1]
                if following.finalFrame == nil && following.startFrame == scheduledFrame { return }
                segments.removeFirst()
                if spatialSpectrumEnabled {
                    lastSpectrumFrame = following.startFrame
                    spatialSpectrumFrames.removeAll { $0.start + Int64($0.buffer.frameLength) <= following.startFrame }
                }
                if tapInstalled || spatialSpectrumEnabled { analyzer.reset() }
                onTransition?(following.source.id)
                continue
            }
            guard streamEnded else { return }
            finish()
            return
        }
    }

    private func fill() {
        guard requestedPlayback, !streamEnded, pendingRead == nil,
              var segment = segments.last, scheduledFrame - renderedFrame < Self.bufferedFrames else { return }
        if segment.finalFrame != nil {
            guard segments.count < 2 else { return }
            guard let next = successor?(segment.source.id, failed) else {
                streamEnded = true
                startIfReady()
                updateRenderedProgress()
                return
            }
            segment = Segment(source: next, startFrame: scheduledFrame, position: 0)
            segments.append(segment)
        }
        pendingRead = Task { [weak self, segment] in
            let result: Result<PCMChunk?, Error>
            do {
                let stream: PCMStream
                if let decoder = segment.decoder {
                    stream = decoder
                } else {
                    let url = segment.source.url
                    let position = segment.initialPosition
                    stream = try await Self.openStream(url: url, position: position)
                    guard !Task.isCancelled else { return }
                    segment.decoder = stream
                    segment.initialPosition = stream.initialPosition
                }
                result = .success(try await stream.read())
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            receive(result, for: segment)
        }
    }

    @concurrent
    private static func openStream(url: URL, position: Double) async throws -> PCMStream {
        try PCMStream(url: url, position: position)
    }

    private func receive(_ result: Result<PCMChunk?, Error>, for segment: Segment) {
        pendingRead = nil
        guard segments.last === segment else { return }
        switch result {
        case .success(let chunk?):
            do {
                if let spatialOutput {
                    if try !spatialOutput.enqueue(chunk.buffer, at: scheduledFrame) {
                        updateRenderedProgress()
                        if let current = segments.first {
                            begin(current.source, position: livePosition ?? current.initialPosition, play: requestedPlayback)
                        }
                        return
                    }
                    if spatialSpectrumEnabled { spatialSpectrumFrames.append((scheduledFrame, chunk.buffer)) }
                } else {
                    player?.scheduleBuffer(chunk.buffer, at: nil, options: [], completionHandler: nil)
                }
                scheduledFrame += Int64(chunk.buffer.frameLength)
            } catch {
                onError?(segment.source.id, error)
                finish()
                return
            }
        case .success(nil):
            segment.finalFrame = scheduledFrame
            segment.decoder = nil
        case .failure(let error):
            failed.insert(segment.source.id)
            onError?(segment.source.id, error)
            segment.decoder = nil
            if scheduledFrame == segment.startFrame, segments.count > 1 {
                segments.removeLast()
            } else {
                segment.finalFrame = scheduledFrame
            }
        }
        startIfReady()
        fill()
    }

    private func startIfReady() {
        guard requestedPlayback, player?.isPlaying != true, spatialOutput?.isPlaying != true else { return }
        let hasSamples = scheduledFrame > renderedFrame
        let enough = started || scheduledFrame >= Self.startupFrames || streamEnded || segments.count > 1
        guard hasSamples, enough else {
            if streamEnded, !hasSamples {
                finish()
            }
            return
        }
        do {
            if let engine, let player {
                if !engine.isRunning {
                    engine.prepare()
                    try engine.start()
                }
                if mode == .offline, !started { manualStartFrame = engine.manualRenderingSampleTime }
                try player.playAudio()
            } else {
                spatialOutput?.play()
            }
            started = true
        } catch {
            let id = segments.first?.source.id
            if let id { onError?(id, error) }
            finish()
        }
    }

    private func finish() {
        let position = livePosition
        reset()
        completedPosition = position
        onEnd?()
    }
}
