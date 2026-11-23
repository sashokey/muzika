import Darwin
import Foundation

nonisolated struct AudioAlbumKey: Hashable, Sendable {
    let title: String
    let artist: String
}

nonisolated struct AudioTrack: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let url: URL
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let genre: String
    let discNumber: Int
    let trackNumber: Int
    let year: Int?
    let duration: Double
    let codec: String
    let bitDepth: Int?
    let sampleRate: Double?
    let bitrate: Int?
    let channels: Int?
    let addedAt: Date
    var isTemporary: Bool
    var trackTotal: Int? = nil
    var discTotal: Int? = nil

    var albumKey: AudioAlbumKey {
        AudioAlbumKey(title: Self.artistKey(album), artist: Self.artistKey(albumArtist.isEmpty ? artist : albumArtist))
    }

    var codecTitle: String { codec == "Audio" ? String(localized: "Audio") : codec }

    var formattedBitDepth: String? {
        bitDepth.map { String(localized: "\($0)-bit") }
    }

    var formattedSampleRate: String? {
        sampleRate.map {
            let rate = ($0 / 1_000).formatted(.number.precision(.fractionLength(0...3)))
            return String(localized: "\(rate) kHz")
        }
    }

    var formattedBitrate: String? {
        bitrate.map { String(localized: "\($0 / 1_000) kbps") }
    }

    var quality: String {
        [codecTitle, formattedBitDepth ?? formattedBitrate, formattedSampleRate]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func artistKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    func matches(_ query: String) -> Bool {
        matches(tokens: Self.artistKey(query).split(whereSeparator: \.isWhitespace).map(String.init))
    }

    func matches(tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let fields = Self.artistKey([title, artist, album, albumArtist, genre, url.lastPathComponent].joined(separator: "\n"))
        return tokens.allSatisfy { fields.contains($0) }
    }
}

nonisolated struct LibrarySource: Identifiable, Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case ready = "Ready"
        case unavailable = "Unavailable"

        var title: String {
            switch self {
            case .ready: String(localized: "Ready")
            case .unavailable: String(localized: "Unavailable")
            }
        }
    }

    let id: UUID
    private(set) var url: URL
    private var bookmark: Data?
    private(set) var status: Status
    private(set) var trackCount: Int

    var name: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    init(url: URL) {
        let lease = SecurityScopeLease(url: url)
        self.id = UUID()
        self.url = url.canonicalized
        self.bookmark = SecurityScopeLease.bookmark(for: url)
        self.status = .ready
        self.trackCount = 0
        withExtendedLifetime(lease) {}
    }

    mutating func open() -> SecurityScopeLease? {
        guard let bookmark else { return SecurityScopeLease(url: url) }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), let lease = SecurityScopeLease(url: resolved) else {
            return SecurityScopeLease(url: url)
        }
        url = resolved.canonicalized
        if stale, let renewed = SecurityScopeLease.bookmark(for: resolved) {
            self.bookmark = renewed
        }
        return lease
    }

    mutating func report(_ status: Status, count: Int) {
        self.status = status
        self.trackCount = count
    }
}

nonisolated final class SecurityScopeLease: Sendable {
    private let url: URL
    private let scoped: Bool

    init?(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        guard scoped || FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        self.url = url
        self.scoped = scoped
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    deinit {
        if scoped {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

nonisolated extension URL {
    var canonicalized: URL { standardizedFileURL.resolvingSymlinksInPath() }

    var needsDownload: Bool {
        let values = try? resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        return needsDownload(status: values?.ubiquitousItemDownloadingStatus)
    }

    func needsDownload(status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        if status == .notDownloaded { return true }
        return withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            var info = stat()
            return stat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
        }
    }

    func containsFile(atPath filePath: String) -> Bool {
        let root = path.hasSuffix("/") ? path : path + "/"
        return filePath.hasPrefix(root)
    }
}
