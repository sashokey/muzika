import Foundation
import Observation

nonisolated struct QueueEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let track: AudioTrack

    init(id: UUID = UUID(), track: AudioTrack) {
        self.id = id
        self.track = track
    }
}

nonisolated enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off, all, one
}

@MainActor
protocol PlaybackTransport: AnyObject {
    var volume: Double { get set }
    var livePosition: Double? { get }
    var isRendering: Bool { get }
    var successor: ((UUID, Set<UUID>) -> PCMPlayback.Source?)? { get set }
    var onTransition: ((UUID) -> Void)? { get set }
    var onAdvance: ((UUID, Double) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    var onError: ((UUID, Error) -> Void)? { get set }

    func begin(_ source: PCMPlayback.Source, position: Double, play: Bool)
    func play()
    func pause()
    func reset()
    func poll()
    func refreshSuccessor()
    func setSpectrumEnabled(_ enabled: Bool)
    func spectrum() -> [Float]
    func setAudioInfoSpectrumEnabled(_ enabled: Bool)
    func audioInfoSpectrum() -> [Float]
}

@MainActor
@Observable
final class PlaybackController {
    private(set) var current: AudioTrack?
    private(set) var queue: [QueueEntry] = []
    private(set) var currentEntryID: UUID?
    private(set) var position = 0.0
    private(set) var playing = false
    private(set) var playbackError: String?
    #if MUZIKA_DEV_LOGS
    private(set) var diagnosticQueueRevision: UInt64 = 0
    #endif

    @ObservationIgnored var onTrackStarted: ((AudioTrack) -> Void)?
    @ObservationIgnored var onListen: ((AudioTrack, Double) -> Void)?
    @ObservationIgnored var onNowPlayingChange: (() -> Void)?

    private var outputVolume = 1.0
    private var shuffleEnabled = false
    private var currentRepeatMode = RepeatMode.off
    private var lockEnabled = false
    private var deduplicationEnabled = false
    private var gaplessEnabled = true
    private var spatialEnabled = false

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let mode: PCMPlayback.Mode
    @ObservationIgnored private var transport: (any PlaybackTransport)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var originalOrder: [UUID] = []
    @ObservationIgnored private var playingOccurrenceStarted = false
    @ObservationIgnored private var endedOccurrence = false
    @ObservationIgnored private var pendingListen = 0.0
    @ObservationIgnored private var lastAutosave = ContinuousClock.now
    @ObservationIgnored private var spectrumClients: Set<UUID> = []
    @ObservationIgnored private var audioInfoSpectrumClients: Set<UUID> = []
    @ObservationIgnored private var didDismiss = false
    @ObservationIgnored private var reportedRendering = false

    private static let settingsKey = "muzika.playback.settings.v1"
    private static let sessionKey = "muzika.playback.session.v1"

    private struct Settings: Codable {
        let volume: Double
        let shuffle: Bool
        let repeatMode: RepeatMode
        let locked: Bool
        let preventDuplicates: Bool
        let gapless: Bool?
        let spatialAudio: Bool?
    }

    private struct SavedEntry: Codable {
        let id: UUID
        let trackID: String
    }

    private struct Session: Codable {
        let entries: [SavedEntry]
        let originalOrder: [UUID]
        let current: UUID
        let position: Double
        let ended: Bool?
    }

    init(library: LibraryStore, defaults: UserDefaults = .standard, mode: PCMPlayback.Mode = .realtime) {
        self.library = library
        self.defaults = defaults
        self.mode = mode
        if let data = defaults.data(forKey: Self.settingsKey),
           let settings = try? JSONDecoder().decode(Settings.self, from: data) {
            outputVolume = min(1, max(0, settings.volume))
            shuffleEnabled = settings.shuffle
            currentRepeatMode = settings.repeatMode
            lockEnabled = settings.locked
            deduplicationEnabled = settings.preventDuplicates
            gaplessEnabled = settings.gapless ?? true
            spatialEnabled = settings.spatialAudio ?? false
        }
    }

    var volume: Double {
        get { outputVolume }
        set {
            guard newValue.isFinite else { return }
            outputVolume = min(1, max(0, newValue))
            transport?.volume = outputVolume
            saveSettings()
            notifyNowPlaying()
        }
    }

    var shuffle: Bool {
        get { shuffleEnabled }
        set {
            guard shuffleEnabled != newValue else { return }
            shuffleEnabled = newValue
            reorderUpcoming()
            saveSettings()
            queueChanged()
        }
    }

    var repeatMode: RepeatMode {
        get { currentRepeatMode }
        set {
            guard currentRepeatMode != newValue else { return }
            currentRepeatMode = newValue
            saveSettings()
            queueChanged()
        }
    }

    var queueLocked: Bool {
        get { lockEnabled }
        set {
            lockEnabled = newValue
            #if MUZIKA_DEV_LOGS
            MuzikaTrace.event(.queue, "queue.lock", "locked=\(newValue) count=\(queue.count)")
            #endif
            saveSettings()
        }
    }

    var preventDuplicates: Bool {
        get { deduplicationEnabled }
        set {
            deduplicationEnabled = newValue
            saveSettings()
        }
    }

    var gapless: Bool {
        get { gaplessEnabled }
        set {
            guard gaplessEnabled != newValue else { return }
            gaplessEnabled = newValue
            saveSettings()
            reloadTransport()
        }
    }

    var spatialAudio: Bool {
        get { spatialEnabled }
        set {
            guard spatialEnabled != newValue else { return }
            spatialEnabled = newValue
            saveSettings()
            reloadTransport()
        }
    }

    var livePosition: Double {
        boundedPosition(transport?.livePosition ?? position)
    }

    var isRendering: Bool { playing && transport?.isRendering == true }

    private var currentIndex: Int? {
        guard let currentEntryID else { return nil }
        return queue.firstIndex { $0.id == currentEntryID }
    }

    func play(_ track: AudioTrack, in tracks: [AudioTrack]) {
        let supplied = tracks.contains { $0.id == track.id } ? tracks : [track] + tracks
        replaceQueue(supplied, startingAt: track.id, shuffle: shuffleEnabled)
    }

    func play(_ tracks: [AudioTrack], shuffled: Bool) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = shuffled
        saveSettings()
        replaceQueue(tracks, startingAt: shuffled ? nil : tracks.first?.id, shuffle: shuffled)
    }

    func togglePlayback() {
        if playing {
            pause()
        } else {
            if current == nil, didDismiss { restore() }
            guard let index = currentIndex else { return }
            let duration = current?.duration ?? 0
            if endedOccurrence || (duration.isFinite && duration > 0 && livePosition >= duration) {
                load(queue[index], at: 0, start: true)
            } else if transport?.livePosition == nil {
                load(queue[index], at: position, start: true, newOccurrence: false)
            } else {
                playbackError = nil
                playing = true
                updateSpectrumRequests()
                transport?.play()
                startTicker()
                notifyNowPlaying()
            }
        }
    }

    func next() {
        transport?.poll()
        guard let index = currentIndex else { return }
        let next = index + 1
        if next < queue.count {
            load(queue[next], at: 0, start: true)
        } else if repeatMode == .all, let first = queue.first {
            load(first, at: 0, start: true)
        }
    }

    func previous() {
        transport?.poll()
        guard let index = currentIndex else { return }
        if livePosition > 3 {
            seek(to: 0)
        } else if index > 0 {
            load(queue[index - 1], at: 0, start: true)
        } else {
            seek(to: 0)
        }
    }

    func seek(to newPosition: Double) {
        guard newPosition.isFinite else { return }
        transport?.poll()
        guard let index = currentIndex else { return }
        let target = boundedPosition(newPosition)
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.controls, "seek.commit", "position_s=\(position) target_s=\(target) playing=\(playing)")
        #endif
        load(queue[index], at: target, start: playing, newOccurrence: false)
    }

    func dismiss() {
        pause()
        saveSession()
        transport?.reset()
        current = nil
        currentEntryID = nil
        position = 0
        queue = []
        originalOrder = []
        #if MUZIKA_DEV_LOGS
        traceQueueMutation("queue.dismiss")
        #endif
        didDismiss = true
        playbackError = nil
        notifyNowPlaying()
    }

    func addToQueue(_ tracks: [AudioTrack], next: Bool) {
        let additions = entryList(tracks, excluding: Set(queue.map(\.track.id)))
        guard !additions.isEmpty else { return }
        let target = next ? (currentIndex.map { $0 + 1 } ?? 0) : queue.endIndex
        queue.insert(contentsOf: additions, at: target)
        #if MUZIKA_DEV_LOGS
        traceQueueMutation("queue.insert", "inserted=\(additions.count) target=\(target) next=\(next)")
        #endif
        let logicalTarget = next
            ? currentEntryID.flatMap { originalOrder.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            : originalOrder.endIndex
        originalOrder.insert(contentsOf: additions.map(\.id), at: logicalTarget)
        if currentEntryID == nil, let first = queue.first {
            load(first, at: 0, start: false)
        } else {
            queueChanged()
        }
    }

    func select(_ entry: QueueEntry) {
        guard let matching = queue.first(where: { $0.id == entry.id }) else { return }
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.queue, "queue.select", "index=\(queue.firstIndex(of: matching) ?? -1) count=\(queue.count)")
        #endif
        load(matching, at: 0, start: true)
    }

    func remove(_ entry: QueueEntry) {
        guard !lockEnabled, let index = queue.firstIndex(where: { $0.id == entry.id }) else { return }
        let removesCurrent = entry.id == currentEntryID
        if removesCurrent {
            transport?.pause()
            flushHistory()
            transport?.reset()
        }
        queue.remove(at: index)
        originalOrder.removeAll { $0 == entry.id }
        #if MUZIKA_DEV_LOGS
        traceQueueMutation("queue.remove", "index=\(index) removed_current=\(removesCurrent)")
        #endif
        if !removesCurrent {
            queueChanged()
        } else if !queue.isEmpty {
            load(queue[min(index, queue.count - 1)], at: 0, start: playing)
        } else {
            clear()
        }
    }

    func move(from indexes: IndexSet, to destination: Int) {
        guard !lockEnabled, !indexes.isEmpty, destination >= 0, destination <= queue.count,
              indexes.allSatisfy({ queue.indices.contains($0) }) else { return }
        let entries = indexes.map { queue[$0] }
        let target = destination - indexes.filter { $0 < destination }.count
        for index in indexes.reversed() { queue.remove(at: index) }
        queue.insert(contentsOf: entries, at: target)
        originalOrder = queue.map(\.id)
        #if MUZIKA_DEV_LOGS
        traceQueueMutation("queue.move", "moved=\(indexes.count) first=\(indexes.first ?? -1) destination=\(destination) target=\(target)")
        #endif
        queueChanged()
    }

    func restore() {
        guard queue.isEmpty, let data = defaults.data(forKey: Self.sessionKey),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return }
        let tracks = accessibleTracks(for: Set(session.entries.map(\.trackID)))
        let entries: [QueueEntry] = session.entries.compactMap { saved in
            guard let track = tracks[saved.trackID] else { return nil }
            return QueueEntry(id: saved.id, track: track)
        }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let savedIndex = session.entries.firstIndex { $0.id == session.current } ?? 0
        let following = session.entries.dropFirst(savedIndex + 1).lazy.compactMap { byID[$0.id] }.first
        guard let entry = byID[session.current] ?? following ?? entries.first else { return }
        queue = entries
        #if MUZIKA_DEV_LOGS
        traceQueueMutation("queue.restore")
        #endif
        originalOrder = session.originalOrder.filter { byID[$0] != nil }
        let restoresSameItem = entry.id == session.current
        load(
            entry, at: restoresSameItem ? session.position : 0, start: false,
            ended: restoresSameItem && session.ended == true
        )
    }

    func reconcileLibrary() {
        guard !queue.isEmpty else { return }
        let oldQueue = queue
        let tracks = accessibleTracks(
            for: Set(oldQueue.map(\.track.id)),
            including: oldQueue.map(\.track).filter(\.isTemporary)
        )
        let available = oldQueue.compactMap { entry in
            tracks[entry.track.id].map { QueueEntry(id: entry.id, track: $0) }
        }
        guard available != oldQueue else { return }

        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pausedForRemoval = currentEntryID.map { byID[$0] == nil } ?? false
        if pausedForRemoval { transport?.pause() }
        let index = currentIndex ?? 0
        let resumed = playing
        queue = available
        #if MUZIKA_DEV_LOGS
        traceQueueMutation("queue.reconciled")
        #endif
        originalOrder.removeAll { byID[$0] == nil }

        if let id = currentEntryID, let retained = byID[id] {
            current = retained.track
            position = livePosition
            if pausedForRemoval, resumed { transport?.play() }
            queueChanged()
            return
        }
        let next = oldQueue.dropFirst(index + 1).lazy.compactMap { byID[$0.id] }.first
        let wraps = repeatMode == .all
        if let selected = next ?? (wraps ? available.first : available.last) {
            load(selected, at: 0, start: resumed && (next != nil || wraps))
        } else {
            flushHistory()
            clear()
        }
    }

    private func accessibleTracks(for ids: Set<String>, including temporary: [AudioTrack] = []) -> [String: AudioTrack] {
        var candidates = Dictionary(temporary.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for track in library.tracks where ids.contains(track.id) && !track.isTemporary {
            candidates[track.id] = track
        }
        return candidates.filter { _, track in
            guard let lease = library.access(track) else { return false }
            return withExtendedLifetime(lease) { FileManager.default.isReadableFile(atPath: track.url.path) }
        }
    }

    func setSpectrumEnabled(_ enabled: Bool, from client: UUID) {
        if enabled { spectrumClients.insert(client) }
        else { spectrumClients.remove(client) }
        updateSpectrumRequests()
    }

    func spectrum() -> [Float] {
        guard playing, let transport else { return [] }
        return transport.spectrum()
    }

    func setAudioInfoSpectrumEnabled(_ enabled: Bool, from client: UUID) {
        if enabled { audioInfoSpectrumClients.insert(client) }
        else { audioInfoSpectrumClients.remove(client) }
        updateSpectrumRequests()
    }

    func audioInfoSpectrum() -> [Float] {
        guard playing, let transport else { return [] }
        return transport.audioInfoSpectrum()
    }

    private func updateSpectrumRequests() {
        transport?.setSpectrumEnabled(playing && !spectrumClients.isEmpty)
        transport?.setAudioInfoSpectrumEnabled(playing && !audioInfoSpectrumClients.isEmpty)
    }

    func renderOffline() throws -> Bool {
        guard mode == .offline, let transport = transport as? PCMPlayback else { return false }
        transport.poll()
        guard transport.readyForOfflineRender else { return false }
        _ = try transport.render(128)
        tick()
        return true
    }

    private func replaceQueue(_ tracks: [AudioTrack], startingAt startID: String?, shuffle: Bool) {
        let entries = entryList(tracks)
        guard !entries.isEmpty else { return }
        transport?.pause()
        flushHistory()
        transport?.reset()
        originalOrder = entries.map(\.id)
        let start = startID.flatMap { id in entries.first { $0.track.id == id } }
        if shuffle, let start {
            queue = [start] + entries.filter { $0.id != start.id }.shuffled()
        } else {
            queue = shuffle ? entries.shuffled() : entries
        }
        #if MUZIKA_DEV_LOGS
        traceQueueMutation("queue.replace", "shuffled=\(shuffle)")
        #endif
        if let entry = start ?? queue.first { load(entry, at: 0, start: true) }
    }

    private func entryList(_ tracks: [AudioTrack], excluding existing: Set<String> = []) -> [QueueEntry] {
        var seen = existing
        return tracks.compactMap { track in
            guard !deduplicationEnabled || seen.insert(track.id).inserted else { return nil }
            return QueueEntry(track: track)
        }
    }

    private func reorderUpcoming() {
        let split = currentIndex.map { $0 + 1 } ?? 0
        let prefix = Array(queue.prefix(split))
        let upcoming = Array(queue.dropFirst(split))
        if shuffleEnabled {
            queue = prefix + upcoming.shuffled()
        } else {
            let ranks = Dictionary(uniqueKeysWithValues: originalOrder.enumerated().map { ($1, $0) })
            queue = prefix + upcoming.sorted {
                (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max)
            }
        }
        #if MUZIKA_DEV_LOGS
        traceQueueMutation("queue.order.changed", "shuffled=\(shuffleEnabled) upcoming=\(upcoming.count)")
        #endif
    }

    #if MUZIKA_DEV_LOGS
    private func traceQueueMutation(_ event: StaticString, _ fields: String = "") {
        diagnosticQueueRevision &+= 1
        MuzikaTrace.event(.queue, event, "revision=\(diagnosticQueueRevision) count=\(queue.count) \(fields)")
    }
    #endif

    private func queueChanged() {
        transport?.refreshSuccessor()
        saveSession()
        notifyNowPlaying()
    }

    private func pause() {
        guard playing else { return }
        transport?.pause()
        position = livePosition
        playing = false
        updateSpectrumRequests()
        flushHistory()
        saveSession()
        notifyNowPlaying()
    }

    func flush() {
        transport?.poll()
        position = livePosition
        flushHistory()
        saveSession()
    }

    private func reloadTransport() {
        guard let transport else { return }
        transport.pause()
        let time = livePosition
        let resume = playing
        transport.reset()
        self.transport = nil
        guard let index = currentIndex, !endedOccurrence else { return }
        load(queue[index], at: time, start: resume, newOccurrence: false)
    }

    private func clear() {
        transport?.reset()
        current = nil
        currentEntryID = nil
        position = 0
        playing = false
        playbackError = nil
        didDismiss = false
        defaults.set(nil, forKey: Self.sessionKey)
        notifyNowPlaying()
    }

    private func load(
        _ entry: QueueEntry, at seconds: Double, start: Bool,
        newOccurrence: Bool = true, ended: Bool = false
    ) {
        transport?.pause()
        flushHistory()
        transport?.reset()
        current = library.track(id: entry.track.id) ?? entry.track
        currentEntryID = entry.id
        position = boundedPosition(seconds)
        playing = false
        playbackError = nil
        didDismiss = false
        endedOccurrence = ended
        if newOccurrence { playingOccurrenceStarted = false }

        if start {
            do {
                let engine = try prepareEngine()
                guard let source = resolve(entry) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                playing = true
                engine.begin(source, position: position, play: true)
                updateSpectrumRequests()
                startTicker()
            } catch {
                report(error, id: entry.id)
            }
        }
        saveSession()
        notifyNowPlaying()
    }

    private func prepareEngine() throws -> any PlaybackTransport {
        if let transport { return transport }
        let engine: any PlaybackTransport = if gaplessEnabled || mode == .offline {
            try PCMPlayback(mode: mode, spatial: spatialEnabled)
        } else {
            QueuePlayback(spatial: spatialEnabled)
        }
        engine.volume = outputVolume
        engine.successor = { [weak self] id, failures in self?.successor(after: id, excluding: failures) }
        engine.onAdvance = { [weak self] id, time in self?.advance(entryID: id, seconds: time) }
        engine.onTransition = { [weak self] id in self?.transition(to: id) }
        engine.onEnd = { [weak self] in self?.ended() }
        engine.onError = { [weak self] id, error in self?.report(error, id: id) }
        transport = engine
        return engine
    }

    private func resolve(_ entry: QueueEntry) -> PCMPlayback.Source? {
        let track = library.track(id: entry.track.id) ?? entry.track
        guard let lease = library.access(track) else { return nil }
        return PCMPlayback.Source(id: entry.id, url: track.url, lease: lease)
    }

    private func successor(after id: UUID, excluding failures: Set<UUID>) -> PCMPlayback.Source? {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        if repeatMode == .one, !failures.contains(id) {
            return resolve(queue[index])
        }
        let later = queue.suffix(from: index + 1)
        let wrapped = repeatMode == .all ? queue.prefix(through: index) : queue.prefix(0)
        for candidate in later + wrapped where !failures.contains(candidate.id) {
            if let source = resolve(candidate) { return source }
        }
        return nil
    }

    private func transition(to id: UUID) {
        guard let entry = queue.first(where: { $0.id == id }) else { return }
        flushHistory()
        current = library.track(id: entry.track.id) ?? entry.track
        currentEntryID = id
        position = livePosition
        playbackError = nil
        playingOccurrenceStarted = false
        endedOccurrence = false
        saveSession()
        notifyNowPlaying()
    }

    private func advance(entryID: UUID, seconds: Double) {
        guard currentEntryID == entryID, let current, seconds > 0 else { return }
        if !playingOccurrenceStarted {
            playingOccurrenceStarted = true
            onTrackStarted?(current)
        }
        pendingListen += seconds
        if pendingListen >= 1 { flushHistory() }
    }

    private func flushHistory() {
        guard pendingListen > 0, let current else { return }
        let seconds = pendingListen
        pendingListen = 0
        onListen?(current, seconds)
    }

    private func ended() {
        flushHistory()
        position = boundedPosition(transport?.livePosition ?? current?.duration ?? position)
        playing = false
        updateSpectrumRequests()
        endedOccurrence = true
        saveSession()
        notifyNowPlaying()
    }

    private func report(_ error: Error, id: UUID) {
        guard let entry = queue.first(where: { $0.id == id }) else { return }
        playbackError = String(localized: "Couldn't play \(entry.track.title). \(error.localizedDescription)")
    }

    private func startTicker() {
        guard mode == .realtime, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, playing else { break }
                tick()
            }
            self?.ticker = nil
            if self?.playing == true { self?.startTicker() }
        }
    }

    private func tick() {
        transport?.poll()
        if playing { position = livePosition }
        if reportedRendering != isRendering { notifyNowPlaying() }
        let now = ContinuousClock.now
        if playing, now - lastAutosave >= .seconds(3) {
            lastAutosave = now
            saveSession()
        }
    }

    private func notifyNowPlaying() {
        reportedRendering = isRendering
        onNowPlayingChange?()
    }

    private func boundedPosition(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let duration = current?.duration ?? 0
        return duration.isFinite && duration > 0
            ? min(duration, max(0, seconds))
            : max(0, seconds)
    }

    private func saveSession() {
        guard let currentEntryID else { return }
        let saved = queue.filter { !$0.track.isTemporary }
        guard !saved.isEmpty else {
            defaults.set(nil, forKey: Self.sessionKey)
            return
        }
        let ids = Set(saved.map(\.id))
        let focus = ids.contains(currentEntryID)
            ? currentEntryID
            : queue.suffix(from: currentIndex ?? 0).first(where: { ids.contains($0.id) })?.id ?? saved[0].id
        let session = Session(
            entries: saved.map { SavedEntry(id: $0.id, trackID: $0.track.id) },
            originalOrder: originalOrder.filter { ids.contains($0) },
            current: focus,
            position: focus == currentEntryID ? livePosition : 0,
            ended: focus == currentEntryID && endedOccurrence
        )
        defaults.set(try? JSONEncoder().encode(session), forKey: Self.sessionKey)
    }

    private func saveSettings() {
        let settings = Settings(
            volume: outputVolume,
            shuffle: shuffleEnabled,
            repeatMode: currentRepeatMode,
            locked: lockEnabled,
            preventDuplicates: deduplicationEnabled,
            gapless: gaplessEnabled,
            spatialAudio: spatialEnabled
        )
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
    }
}
