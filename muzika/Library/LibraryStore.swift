import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    private(set) var tracks: [AudioTrack] = []
    private(set) var sources: [LibrarySource] = []
    private(set) var isScanning = false
    private(set) var isScanPaused = false
    private(set) var scanProgress: LibraryScanProgress?
    private(set) var scanError: String?
    private(set) var scanIssues: [LibraryScanIssue] = []
    private(set) var lastCompletedScan: Date?
    private(set) var revision = 0
    private(set) var temporaryError: String?
    private(set) var artworkCacheBytes = 0
    private(set) var artworkCacheCount = 0

    @ObservationIgnored private let storageURL: URL
    private var files: [String: IndexedAudioFile] = [:]
    private var temporaryFiles: [String: TemporaryAudioFile] = [:]
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var scanTask: Task<LibraryScanReport, Never>?
    @ObservationIgnored private var scanControl: LibraryScanControl?
    @ObservationIgnored private var sourceWatcher: LibrarySourceWatcher?
    @ObservationIgnored private var volumesGeneration = 0
    @ObservationIgnored private var automaticScanTask: Task<Void, Never>?
    @ObservationIgnored private var automaticScanPending = false
    @ObservationIgnored private var artworkCache = ArtworkCache()
    @ObservationIgnored private var artworkGeneration = 0
    @ObservationIgnored private var unsupportedVersion: Int?

    var hasIndexedTracks: Bool { !files.isEmpty }

    var sessionTracks: [AudioTrack] {
        guard !temporaryFiles.isEmpty else { return tracks }
        let opened = temporaryFiles.compactMap { id, record in
            files[id] == nil ? record.file.track : nil
        }
        return tracks + Self.newestFirst(opened)
    }

    private nonisolated struct Snapshot: Codable {
        let version: Int?
        let sources: [LibrarySource]
        let files: [IndexedAudioFile]
        let lastCompletedScan: Date?
        let issues: [LibraryScanIssue]?
    }

    private nonisolated struct SnapshotHeader: Decodable {
        let version: Int?
    }

    convenience init() {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let store = URL.applicationSupportDirectory
            .appending(path: "muzika", directoryHint: .isDirectory)
            .appending(path: "library.json")
        self.init(storageURL: store, watchSources: true)
    }

    init(storageURL: URL, watchSources: Bool = false) {
        self.storageURL = storageURL
        restore()
        if watchSources { startWatchingSources() }
    }

    func addSource(_ url: URL) async {
        guard url.isFileURL, let lease = SecurityScopeLease(url: url),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            scanError = String(localized: "Select a readable local folder.")
            return
        }
        let source = LibrarySource(url: url, lease: lease)
        guard !sources.contains(where: { $0.url.path == source.url.path }) else { return }
        sources.append(source)
        sourceWatcher?.watch(sources)
        persist()
        await rescan()
        withExtendedLifetime(lease) {}
    }

    func removeSource(_ source: LibrarySource) {
        guard sources.contains(where: { $0.id == source.id }) else { return }
        sources.removeAll { $0.id == source.id }
        scanIssues.removeAll { $0.sourceID == source.id }
        sourceWatcher?.watch(sources)
        publish(files.filter { containsRegisteredTrack($0.key) })
        if sources.isEmpty {
            cancelScan()
            scanError = nil
        }
        persist()
    }

    func rescan(force: Bool = false) async {
        await runScan(mode: force ? .force : .index)
    }

    func cleanupMissingFiles() async {
        await runScan(mode: .cleanup)
    }

    func pauseScan() {
        guard let scanControl, isScanning else { return }
        scanControl.pause()
        isScanPaused = true
    }

    func resumeScan() {
        scanControl?.resume()
        isScanPaused = false
    }

    func cancelScan() {
        automaticScanTask?.cancel()
        automaticScanTask = nil
        automaticScanPending = false
        stopScan()
    }

    private func stopScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        resumeScan()
        scanControl = nil
        isScanning = false
        scanProgress = nil
    }

    private func runScan(mode: LibraryScanMode) async {
        stopScan()
        scanError = nil
        guard !sources.isEmpty else { return }
        isScanning = true
        let generation = scanGeneration
        let startingVolumesGeneration = volumesGeneration
        let registeredSources = sources
        let previous = files
        let control = LibraryScanControl()
        scanControl = control
        scanProgress = LibraryScanProgress(totalSources: registeredSources.count)
        let onProgress: @Sendable (LibraryScanProgress) async -> Void = { [weak self] progress in
            await self?.updateProgress(progress, generation: generation)
        }
        let task = Task.detached(priority: .utility) {
            await LibraryScanner.scan(registeredSources, reusing: previous, mode: mode, control: control, onProgress: onProgress)
        }
        scanTask = task
        let report = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            control.resume()
        }
        guard generation == scanGeneration else { return }
        let canPublish = await control.checkpoint()
        guard generation == scanGeneration else { return }
        guard canPublish else {
            stopScan()
            return
        }

        let currentIDs = Set(sources.map(\.id))
        var scannedSources = report.sources.filter { currentIDs.contains($0.id) }
        if startingVolumesGeneration != volumesGeneration {
            scannedSources = sourcesCheckingAvailability(scannedSources)
        }
        let indexedFiles = report.files.filter { path, _ in
            scannedSources.contains { $0.url.containsFile(atPath: path) }
        }
        let issues = report.errors.issues.filter { $0.sourceID.map(currentIDs.contains) ?? true }
        let completedAt = mode == .cleanup ? lastCompletedScan : Date()
        let snapshot = Snapshot(version: 1, sources: scannedSources, files: Array(indexedFiles.values),
                                lastCompletedScan: completedAt, issues: issues)
        scanError = report.errors.summary
        guard persist(snapshot) else {
            stopScan()
            if automaticScanPending { scheduleAutomaticScan() }
            return
        }
        sources = scannedSources
        if mode == .force { clearArtworkCache() }
        publish(indexedFiles)
        scanIssues = issues
        lastCompletedScan = completedAt
        isScanning = false
        scanProgress = nil
        scanTask = nil
        scanControl = nil
        sourceWatcher?.watch(sources)
        if automaticScanPending { scheduleAutomaticScan() }
    }

    private func updateProgress(_ progress: LibraryScanProgress, generation: Int) {
        guard generation == scanGeneration else { return }
        scanProgress = progress
    }

    func clearIndex() {
        cancelScan()
        for index in sources.indices {
            sources[index].report(sources[index].status, count: 0)
        }
        publish([:])
        scanError = nil
        scanIssues = []
        persist()
    }

    func indexTemporary(_ urls: [URL]) async -> [AudioTrack] {
        temporaryError = nil
        let (records, errors) = await LibraryScanner.scanTemporary(urls, permanent: files)
        guard !Task.isCancelled else { return [] }
        temporaryError = errors.summary
        return records.map { record in
            let id = record.file.track.id
            if let current = files[id] { return current.track }
            var track = record.file.track
            track.isTemporary = true
            let sessionFile = IndexedAudioFile(
                track: track, stamp: record.file.stamp, metadataVersion: record.file.metadataVersion
            )
            temporaryFiles[id] = TemporaryAudioFile(file: sessionFile, lease: record.lease)
            return track
        }
    }

    func track(id: String) -> AudioTrack? {
        files[id]?.track ?? temporaryFiles[id]?.file.track
    }

    func matchingTracks(_ query: String) -> [AudioTrack] {
        let tokens = AudioTrack.artistKey(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return tracks.filter { $0.matches(tokens: tokens) }
    }

    func access(_ track: AudioTrack) -> SecurityScopeLease? {
        let result = Self.resolveAccess(to: track, sources: sources, temporaryLease: temporaryFiles[track.id]?.lease)
        applySourceUpdates(result.updates)
        return result.lease
    }

    func artwork(for track: AudioTrack) async -> Data? {
        if let cached = artworkCache.value(for: track.id) { return cached }
        let generation = artworkGeneration
        let (artwork, updates) = await Self.readArtwork(
            for: track, sources: sources, temporaryLease: temporaryFiles[track.id]?.lease
        )
        guard !Task.isCancelled else { return nil }
        applySourceUpdates(updates)
        if let artwork, generation == artworkGeneration {
            artworkCache.insert(artwork, for: track.id)
            updateArtworkCacheStats()
        }
        return artwork
    }

    private typealias SourceUpdate = (previous: LibrarySource, current: LibrarySource)

    private nonisolated static func resolveAccess(
        to track: AudioTrack, sources: [LibrarySource], temporaryLease: SecurityScopeLease?
    ) -> (lease: SecurityScopeLease?, updates: [SourceUpdate]) {
        guard MusicLibraryAccess.currentUser.permittedURL(track.url) != nil else { return (nil, []) }
        let path = track.url.path
        var updates: [SourceUpdate] = []
        for previous in sources where previous.url.containsFile(atPath: path) {
            var source = previous
            let lease = source.open()
            if source != previous { updates.append((previous, source)) }
            if let lease, FileManager.default.isReadableFile(atPath: path), !track.url.needsDownload {
                return (lease, updates)
            }
        }
        if let temporaryLease, FileManager.default.isReadableFile(atPath: path), !track.url.needsDownload {
            return (temporaryLease, updates)
        }
        let lease = SecurityScopeLease(url: track.url)
        return (lease != nil && !track.url.needsDownload ? lease : nil, updates)
    }

    @concurrent
    private static func readArtwork(
        for track: AudioTrack, sources: [LibrarySource], temporaryLease: SecurityScopeLease?
    ) async -> (Data?, [SourceUpdate]) {
        guard !Task.isCancelled else { return (nil, []) }
        let result = resolveAccess(to: track, sources: sources, temporaryLease: temporaryLease)
        guard let lease = result.lease, !Task.isCancelled else { return (nil, result.updates) }
        defer { withExtendedLifetime(lease) {} }
        return (await AudioFileMetadata.artwork(at: track.url), result.updates)
    }

    private func applySourceUpdates(_ updates: [SourceUpdate]) {
        var changed = false
        for update in updates {
            guard let index = sources.firstIndex(of: update.previous) else { continue }
            sources[index] = update.current
            changed = true
        }
        if changed { persist() }
    }

    func clearArtworkCache() {
        artworkGeneration += 1
        artworkCache = ArtworkCache()
        updateArtworkCacheStats()
    }

    private func updateArtworkCacheStats() {
        artworkCacheBytes = artworkCache.byteCount
        artworkCacheCount = artworkCache.ids.count
    }

    func lyrics(for track: AudioTrack) async throws -> LyricsDocument? {
        guard let lease = access(track) else { return nil }
        defer { withExtendedLifetime(lease) {} }
        return try await LyricsLoader.load(audioURL: track.url, relatedFileAccess: track.isTemporary)
    }

    func rawLyrics(for track: AudioTrack) async -> [String] {
        guard let lease = access(track) else { return [] }
        defer { withExtendedLifetime(lease) {} }
        return (try? await LyricsLoader.indexedText(audioURL: track.url, relatedFileAccess: track.isTemporary)) ?? []
    }

    private func containsRegisteredTrack(_ path: String) -> Bool {
        sources.contains { $0.url.containsFile(atPath: path) }
    }

    private func publish(_ files: [String: IndexedAudioFile]) {
        revision &+= 1
        artworkGeneration += 1
        for id in artworkCache.ids where self.files[id] != nil &&
            (files[id] == nil || self.files[id]?.stamp != files[id]?.stamp) {
            artworkCache.remove(id)
        }
        updateArtworkCacheStats()
        self.files = files
        let deepestFirst = sources.sorted { $0.url.path.count > $1.url.path.count }
        tracks = Self.newestFirst(files.compactMap { id, file in
            guard !MusicLibraryAccess.currentUser.contains(file.track.url) else { return nil }
            let source = deepestFirst.first { $0.url.containsFile(atPath: id) }
            return source?.status == .ready ? file.track : nil
        })
    }

    private static func newestFirst(_ tracks: [AudioTrack]) -> [AudioTrack] {
        tracks.sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    private func restore() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            let version = try decoder.decode(SnapshotHeader.self, from: data).version ?? 0
            guard (0...1).contains(version) else {
                unsupportedVersion = version
                scanError = String(localized: "Unsupported library index version \(version).")
                return
            }
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            sources = snapshot.sources
            lastCompletedScan = snapshot.lastCompletedScan
            scanIssues = snapshot.issues ?? []
            _ = checkUnavailableSources()
            publish(Dictionary(snapshot.files.map { ($0.track.id, $0) }, uniquingKeysWith: { first, _ in first }))
            if version == 0 { persist() }
        } catch {
            scanError = String(localized: "Could not read the library index. \(error.localizedDescription)")
        }
    }

    private func persist() {
        let snapshot = Snapshot(version: 1, sources: sources, files: Array(files.values),
                                lastCompletedScan: lastCompletedScan, issues: scanIssues)
        _ = persist(snapshot)
    }

    private func persist(_ snapshot: Snapshot) -> Bool {
        if let unsupportedVersion {
            scanError = String(localized: "Unsupported library index version \(unsupportedVersion).")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: storageURL, options: [.atomic])
            return true
        } catch {
            let persistenceError = String(localized: "Could not save the library index. \(error.localizedDescription)")
            scanError = [scanError, persistenceError].compactMap { $0 }.joined(separator: "\n")
            return false
        }
    }

    private func startWatchingSources() {
        let watcher = LibrarySourceWatcher { [weak self] in
            self?.scheduleAutomaticScan()
        } onVolumesChanged: { [weak self] in
            guard let self else { return }
            self.volumesGeneration &+= 1
            if self.checkUnavailableSources() { self.publish(self.files) }
            self.sourceWatcher?.watch(self.sources)
            self.scheduleAutomaticScan()
        }
        sourceWatcher = watcher
        watcher.watch(sources)
    }

    private func scheduleAutomaticScan() {
        guard sourceWatcher != nil, !sources.isEmpty else { return }
        automaticScanPending = true
        automaticScanTask?.cancel()
        automaticScanTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self else { return }
            self.automaticScanTask = nil
            guard !self.isScanning, self.automaticScanPending else { return }
            self.automaticScanPending = false
            self.clearArtworkCache()
            await self.runScan(mode: .index)
        }
    }

    private func checkUnavailableSources() -> Bool {
        let checked = sourcesCheckingAvailability(sources)
        guard checked != sources else { return false }
        sources = checked
        return true
    }

    private func sourcesCheckingAvailability(_ registered: [LibrarySource]) -> [LibrarySource] {
        var checked = registered
        for index in checked.indices {
            var source = checked[index]
            if let lease = source.open(), source.url.path == checked[index].url.path,
               FileManager.default.isReadableFile(atPath: source.url.path),
               (try? source.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                source.report(.ready, count: source.trackCount)
                checked[index] = source
                withExtendedLifetime(lease) {}
            } else {
                checked[index].report(.unavailable, count: checked[index].trackCount)
            }
        }
        return checked
    }
}

private nonisolated struct ArtworkCache {
    private static let maxBytes = 24 * 1_024 * 1_024
    private static let maxCount = 192

    private var dataByID: [String: Data] = [:]
    private(set) var ids: [String] = []
    private(set) var byteCount = 0

    mutating func value(for id: String) -> Data? {
        guard let data = dataByID[id] else { return nil }
        ids.removeAll { $0 == id }
        ids.append(id)
        return data
    }

    mutating func insert(_ data: Data, for id: String) {
        guard !data.isEmpty, data.count <= Self.maxBytes else { return }
        remove(id)
        while let oldest = ids.first, ids.count >= Self.maxCount || byteCount + data.count > Self.maxBytes {
            remove(oldest)
        }
        dataByID[id] = data
        ids.append(id)
        byteCount += data.count
    }

    mutating func remove(_ id: String) {
        guard let data = dataByID.removeValue(forKey: id) else { return }
        byteCount -= data.count
        ids.removeAll { $0 == id }
    }
}
