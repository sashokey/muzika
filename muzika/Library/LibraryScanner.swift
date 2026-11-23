import Foundation
import Synchronization

nonisolated struct LibraryFileStamp: Codable, Equatable, Sendable {
    let modifiedAt: Date
    let size: Int
}

nonisolated struct IndexedAudioFile: Codable, Sendable {
    let track: AudioTrack
    let stamp: LibraryFileStamp?
    var metadataVersion: Int? = nil
}

nonisolated struct LibraryScanReport: Sendable {
    var sources: [LibrarySource] = []
    var files: [String: IndexedAudioFile] = [:]
    var errors = LibraryReadErrors()
}

nonisolated struct LibraryScanProgress: Equatable, Sendable {
    var completedSources = 0
    let totalSources: Int
    var checkedFiles = 0
    var currentSourceName: String?
}

nonisolated enum LibraryScanMode: Equatable, Sendable {
    case index, force, cleanup
}

nonisolated final class LibraryScanControl: Sendable {
    private struct State {
        var isPaused = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func pause() {
        state.withLock { $0.isPaused = true }
    }

    func resume() {
        let waiter = state.withLock { state in
            state.isPaused = false
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func checkpoint() async -> Bool {
        while state.withLock({ $0.isPaused }) && !Task.isCancelled {
            await withCheckedContinuation { continuation in
                let willWait = state.withLock { state in
                    guard state.isPaused else { return false }
                    state.waiter = continuation
                    return true
                }
                if !willWait { continuation.resume() }
            }
        }
        return !Task.isCancelled
    }
}

nonisolated struct TemporaryAudioFile: Sendable {
    let file: IndexedAudioFile
    let lease: SecurityScopeLease
}

nonisolated struct LibraryScanIssue: Identifiable, Codable, Equatable, Sendable {
    let sourceID: UUID?
    let sourceName: String?
    let url: URL
    let message: String

    var id: String { [sourceID?.uuidString ?? "", url.path, message].joined(separator: "\u{0}") }

    var localizedMessage: String { Self.localize(message) }

    static func localize(_ message: String) -> String {
        switch message {
        case "The item is not available offline.":
            String(localized: "The item is not available offline.")
        case "The folder is unavailable.":
            String(localized: "The folder is unavailable.")
        case "The item is unavailable.":
            String(localized: "The item is unavailable.")
        case "Unsupported audio file type.":
            String(localized: "Unsupported audio file type.")
        case "Select a local audio file or folder.":
            String(localized: "Select a local audio file or folder.")
        case "The folder could not be read.":
            String(localized: "The folder could not be read.")
        case "The file does not contain a playable audio stream.":
            String(localized: "The file does not contain a playable audio stream.")
        default:
            if let status = audioStatus(in: message) {
                String(localized: "The audio file could not be opened (\(status)).")
            } else {
                message
            }
        }
    }

    private static func audioStatus(in message: String) -> Int? {
        let prefix = "The audio file could not be opened ("
        let suffix = ")."
        guard message.hasPrefix(prefix), message.hasSuffix(suffix) else { return nil }
        return Int(message.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

nonisolated struct LibraryReadErrors: Sendable {
    var source: LibrarySource?
    private(set) var issues: [LibraryScanIssue] = []
    private(set) var offlineItems: Set<URL> = []
    var count: Int { issues.count }

    mutating func add(_ url: URL, _ message: String) {
        issues.append(LibraryScanIssue(sourceID: source?.id, sourceName: source?.name, url: url, message: message))
    }

    mutating func add(_ url: URL, _ error: any Error) {
        add(url, (error as? AudioFileMetadata.ReadError)?.message ?? error.localizedDescription)
    }

    mutating func skipOffline(_ url: URL) {
        if offlineItems.insert(url.canonicalized).inserted {
            add(url, "The item is not available offline.")
        }
    }

    var summary: String? {
        guard count > 0 else { return nil }
        let header = count == 1 ? String(localized: "Could not read 1 item.")
            : String(localized: "Could not read \(count) items.")
        let examples = issues.prefix(3).map { String(localized: "\($0.url.lastPathComponent): \($0.localizedMessage)") }
        return ([header] + examples).joined(separator: "\n")
    }
}

nonisolated enum LibraryScanner {
    static func scan(
        _ sources: [LibrarySource],
        reusing previous: [String: IndexedAudioFile],
        mode: LibraryScanMode = .index,
        control: LibraryScanControl = LibraryScanControl(),
        onProgress: @Sendable (LibraryScanProgress) async -> Void = { _ in }
    ) async -> LibraryScanReport {
        var report = LibraryScanReport()
        var seenPaths: Set<String> = []
        var readableRoots: [URL] = []
        var protectedRoots: [URL] = []
        var progress = LibraryScanProgress(totalSources: sources.count)
        let clock = ContinuousClock()
        var lastUpdate = clock.now
        let scannedAt = Date()
        for var source in sources {
            guard await control.checkpoint() else { return report }
            report.errors.source = source
            progress.currentSourceName = source.name
            await onProgress(progress)
            let originalURL = source.url
            if let lease = source.open(),
               FileManager.default.isReadableFile(atPath: source.url.path),
               (try? source.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let previousReadErrorCount = report.errors.count - report.errors.offlineItems.count
                let children = await audioFiles(in: source.url, errors: &report.errors, control: control)
                if previousReadErrorCount == report.errors.count - report.errors.offlineItems.count {
                    readableRoots.append(source.url)
                } else {
                    protectedRoots.append(source.url)
                }
                for candidate in children {
                    guard await control.checkpoint() else { return report }
                    let id = candidate.url.path
                    guard source.url.containsFile(atPath: id), seenPaths.insert(id).inserted else { continue }
                    if mode != .cleanup {
                        do {
                            report.files[id] = try await indexed(
                                candidate,
                                previous: previous[id],
                                addedAt: scannedAt,
                                isTemporary: false,
                                force: mode == .force
                            )
                        } catch is CancellationError {
                            return report
                        } catch {
                            report.errors.add(candidate.url, error)
                        }
                    }
                    progress.checkedFiles += 1
                    let now = clock.now
                    if lastUpdate.duration(to: now) >= .milliseconds(200) {
                        lastUpdate = now
                        await onProgress(progress)
                    }
                }
                source.report(.ready, count: 0)
                withExtendedLifetime(lease) {}
            } else {
                protectedRoots.append(originalURL)
                source.report(.unavailable, count: 0)
                report.errors.add(originalURL, "The folder is unavailable.")
            }
            report.sources.append(source)
            progress.completedSources += 1
        }
        guard await control.checkpoint() else { return report }
        func fullyReadable(_ id: String) -> Bool {
            let readableDepth = readableRoots.lazy.filter { $0.containsFile(atPath: id) }.map { $0.path.count }.max() ?? -1
            let protectedDepth = protectedRoots.lazy.filter { $0.containsFile(atPath: id) }.map { $0.path.count }.max() ?? -1
            return readableDepth > protectedDepth
        }
        if mode == .cleanup {
            report.files = previous.filter { id, _ in
                seenPaths.contains(id) || !fullyReadable(id)
            }
        } else if !protectedRoots.isEmpty {
            for (id, indexedFile) in previous where report.files[id] == nil {
                if protectedRoots.contains(where: { $0.containsFile(atPath: id) }),
                   !fullyReadable(id) {
                    report.files[id] = indexedFile
                }
            }
        }
        if !report.errors.offlineItems.isEmpty {
            report.files = report.files.filter { id, _ in
                !report.errors.offlineItems.contains { $0.path == id || $0.containsFile(atPath: id) }
            }
        }
        for index in report.sources.indices {
            let source = report.sources[index]
            let count = report.files.keys.count { source.url.containsFile(atPath: $0) }
            report.sources[index].report(source.status, count: count)
        }
        progress.currentSourceName = nil
        await onProgress(progress)
        return report
    }

    @concurrent
    static func scanTemporary(
        _ urls: [URL],
        permanent: [String: IndexedAudioFile]
    ) async -> ([TemporaryAudioFile], LibraryReadErrors) {
        var files: [TemporaryAudioFile] = []
        var errors = LibraryReadErrors()
        var seen: Set<String> = []
        let openedAt = Date()
        for url in urls {
            if Task.isCancelled { break }
            guard url.isFileURL, let lease = SecurityScopeLease(url: url) else {
                errors.add(url, "The item is unavailable.")
                continue
            }
            guard !url.needsDownload else {
                errors.skipOffline(url)
                continue
            }
            if let permanentFile = permanent[url.canonicalized.path] {
                if seen.insert(permanentFile.track.id).inserted {
                    files.append(TemporaryAudioFile(file: permanentFile, lease: lease))
                }
                continue
            }
            let children = await audioFiles(in: url.canonicalized, errors: &errors)
            for candidate in children {
                if Task.isCancelled { break }
                let id = candidate.url.path
                guard seen.insert(id).inserted else { continue }
                do {
                    let file: IndexedAudioFile
                    if let permanentFile = permanent[id] {
                        file = permanentFile
                    } else {
                        file = try await indexed(candidate, previous: nil, addedAt: openedAt, isTemporary: true)
                    }
                    files.append(TemporaryAudioFile(file: file, lease: lease))
                } catch is CancellationError {
                    break
                } catch {
                    errors.add(candidate.url, error)
                }
            }
        }
        return (files, errors)
    }

    private struct Candidate {
        let url: URL
        let stamp: LibraryFileStamp?
    }

    private static func audioFiles(
        in root: URL,
        errors: inout LibraryReadErrors,
        control: LibraryScanControl? = nil
    ) async -> [Candidate] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        do {
            let values = try root.resourceValues(forKeys: keys)
            guard !root.needsDownload(status: values.ubiquitousItemDownloadingStatus) else {
                errors.skipOffline(root)
                return []
            }
            if values.isRegularFile == true {
                guard AudioFileMetadata.supportedExtensions.contains(root.pathExtension.lowercased()) else {
                    errors.add(root, "Unsupported audio file type.")
                    return []
                }
                return [candidate(at: root, values: values)]
            }
            guard values.isDirectory == true else {
                errors.add(root, "Select a local audio file or folder.")
                return []
            }
        } catch {
            errors.add(root, error)
            return []
        }

        var traversalErrors: [(URL, Error)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                traversalErrors.append((url, error))
                return true
            }
        ) else {
            errors.add(root, "The folder could not be read.")
            return []
        }

        var candidates: [Candidate] = []
        var seen: Set<String> = []
        var visited = 0
        while let child = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            visited += 1
            if visited.isMultiple(of: 128), let control, !(await control.checkpoint()) { break }
            do {
                let values = try child.resourceValues(forKeys: keys)
                let isAudio = values.isRegularFile == true &&
                    AudioFileMetadata.supportedExtensions.contains(child.pathExtension.lowercased())
                guard isAudio || values.isDirectory == true else { continue }
                if child.needsDownload(status: values.ubiquitousItemDownloadingStatus) {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    errors.skipOffline(child)
                    continue
                }
                guard isAudio else { continue }
                let candidate = candidate(at: child, values: values)
                if seen.insert(candidate.url.path).inserted { candidates.append(candidate) }
            } catch {
                errors.add(child, error)
            }
        }
        for (url, error) in traversalErrors {
            errors.add(url, error)
        }
        return candidates.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    private static func candidate(at url: URL, values: URLResourceValues) -> Candidate {
        let stamp: LibraryFileStamp?
        if let modifiedAt = values.contentModificationDate, let size = values.fileSize {
            stamp = LibraryFileStamp(modifiedAt: modifiedAt, size: size)
        } else {
            stamp = nil
        }
        return Candidate(url: url.canonicalized, stamp: stamp)
    }

    private static func indexed(
        _ candidate: Candidate,
        previous: IndexedAudioFile?,
        addedAt: Date,
        isTemporary: Bool,
        force: Bool = false
    ) async throws -> IndexedAudioFile {
        if !force, let previous, previous.metadataVersion == 1,
           let stamp = candidate.stamp, stamp == previous.stamp {
            return previous
        }
        let track = try await AudioFileMetadata.read(
            candidate.url,
            addedAt: previous?.track.addedAt ?? addedAt,
            isTemporary: isTemporary
        )
        return IndexedAudioFile(track: track, stamp: candidate.stamp, metadataVersion: 1)
    }
}
