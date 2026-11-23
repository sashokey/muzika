import AVFoundation
import Foundation

nonisolated enum LyricsLoader {
    private static let maximumSize = 8 * 1_024 * 1_024

    @concurrent
    static func load(audioURL: URL, relatedFileAccess: Bool = false) async throws -> LyricsDocument? {
        try Task.checkCancellation()
        guard audioURL.isFileURL, (try? audioURL.checkResourceIsReachable()) == true else { return nil }

        let embedded = try? await AudioFileMetadata.embeddedLyrics(at: audioURL)
        try Task.checkCancellation()
        var base = document(from: embedded)
        if base == nil, audioURL.pathExtension.lowercased() != "flac" {
            let asset = AVURLAsset(url: audioURL)
            let lyrics = try? await asset.load(.lyrics)
            try Task.checkCancellation()
            base = document(from: lyrics)
        }
        if base == nil {
            base = document(from: readSidecar(at: audioURL, extension: "lrc", related: relatedFileAccess))
        }

        try Task.checkCancellation()
        let saved = document(from: readSidecar(at: audioURL, extension: "mlrc", related: relatedFileAccess))
        let result = saved.map { LyricsParser.merge(base: base, saved: $0) } ?? base
        try Task.checkCancellation()
        return result
    }

    @concurrent
    static func indexedText(audioURL: URL, relatedFileAccess: Bool = false) async throws -> [String] {
        let document = try await load(audioURL: audioURL, relatedFileAccess: relatedFileAccess)
        return document?.lines.flatMap { [$0.text, $0.translation, $0.pronunciation].compactMap { $0 } } ?? []
    }

    private static func document(from text: String?) -> LyricsDocument? {
        guard let text, text.utf8.count <= maximumSize else { return nil }
        return LyricsParser.parse(text)
    }

    private static func readSidecar(at audioURL: URL, extension suffix: String, related: Bool) -> String? {
        let stem = audioURL.deletingPathExtension()
        for name in [suffix, suffix.uppercased()] {
            guard !Task.isCancelled else { return nil }
            let file = stem.appendingPathExtension(name)
            let data = related ? coordinatedData(at: file, relatedTo: audioURL) : readData(at: file)
            guard let data else { continue }
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                if let text = String(data: data, encoding: .utf16) { return text }
            }
            if let text = String(data: data, encoding: .utf8) { return text }
            if suffix == "lrc", let text = String(data: data, encoding: .windowsCP1252) { return text }
        }
        return nil
    }

    private static func coordinatedData(at file: URL, relatedTo audioURL: URL) -> Data? {
        let presenter = RelatedLyricsPresenter(sidecarURL: file, audioURL: audioURL)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        var data: Data?
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        coordinator.coordinate(readingItemAt: file, options: .withoutChanges, error: nil) { coordinatedURL in
            if !Task.isCancelled { data = readData(at: coordinatedURL) }
        }
        return data
    }

    private static func readData(at file: URL) -> Data? {
        guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size > 0, size <= maximumSize,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumSize + 1), data.count <= maximumSize else { return nil }
        return data
    }
}

private nonisolated final class RelatedLyricsPresenter: NSObject, NSFilePresenter {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    init(sidecarURL: URL, audioURL: URL) {
        primaryPresentedItemURL = audioURL
        presentedItemURL = sidecarURL
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
    }
}
