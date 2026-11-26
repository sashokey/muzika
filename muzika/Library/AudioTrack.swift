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

    init(url: URL, lease existingLease: SecurityScopeLease? = nil) {
        let lease = existingLease ?? SecurityScopeLease(url: url)
        self.id = UUID()
        self.url = lease?.canonicalURL ?? url
        self.bookmark = lease?.bookmark()
        self.status = lease == nil ? .unavailable : .ready
        self.trackCount = 0
        withExtendedLifetime(lease) {}
    }

    mutating func open() -> SecurityScopeLease? {
        guard !MusicLibraryAccess.currentUser.contains(url) else { return nil }
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
        url = lease.canonicalURL
        if stale, let renewed = lease.bookmark() {
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
    let canonicalURL: URL
    private let url: URL
    private let scoped: Bool

    init?(url: URL) {
        guard let canonicalURL = MusicLibraryAccess.currentUser.permittedURL(url) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        guard scoped || FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        self.canonicalURL = canonicalURL
        self.url = url
        self.scoped = scoped
    }

    func bookmark() -> Data? {
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

nonisolated struct MusicLibraryAccess: Sendable {
    static let currentUser = Self(home: accountHome() ?? .homeDirectory)

    private let roots: [String]

    init(home: URL) {
        roots = ["Music/Music", "Music/iTunes", "Library/Containers/com.apple.Music"].map {
            Self.lexicalPath(home.appending(path: $0).path)
        }
    }

    func contains(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = Self.lexicalPath(url.path)
        if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        guard path.contains(".musiclibrary") else { return false }
        return path.split(separator: "/").contains { $0.hasSuffix(".musiclibrary") }
    }

    func permittedURL(_ url: URL) -> URL? {
        guard url.isFileURL, !contains(url) else { return nil }
        let resolved = url.canonicalized
        return contains(resolved) ? nil : resolved
    }

    private static func accountHome() -> URL? {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        var buffer = [CChar](repeating: 0, count: max(suggestedSize, 4_096))
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &record, bytes.baseAddress, bytes.count, &result) == 0,
                  let home = result?.pointee.pw_dir else { return nil }
            return URL(filePath: String(cString: home), directoryHint: .isDirectory)
        }
    }

    private static func lexicalPath(_ value: String) -> String {
        let path = value.lowercased()
        guard path.contains("/./") || path.contains("/../") || path.contains("//") ||
                path.hasSuffix("/.") || path.hasSuffix("/..") || path.hasSuffix("/") else { return path }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
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
