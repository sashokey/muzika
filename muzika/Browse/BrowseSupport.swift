import AppKit
import ImageIO
import SwiftUI

enum LibraryRoute: Hashable {
    case home
    case search
    case recentlyAdded
    case artists
    case albums
    case songs
    case genres
    case folders
    case settings
    case artist(String)
    case album(String)
    case genre(String)
    case folder(URL)
    case history
    case statistics
    case rewind

    var sidebarRoute: Self {
        switch self {
        case .artist: .artists
        case .album: .albums
        case .genre: .genres
        case .folder: .folders
        case .history, .statistics, .rewind: .home
        default: self
        }
    }

    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .search: String(localized: "Search")
        case .recentlyAdded: String(localized: "Recently Added")
        case .artists: String(localized: "Artists")
        case .albums: String(localized: "Albums")
        case .songs: String(localized: "Songs")
        case .genres: String(localized: "Genres")
        case .folders: String(localized: "Folders")
        case .settings: String(localized: "Settings")
        case .artist: String(localized: "Artist")
        case .album: String(localized: "Album")
        case .genre: String(localized: "Genre")
        case .folder(let url): url.lastPathComponent
        case .history: String(localized: "Listening History")
        case .statistics: String(localized: "Listening Statistics")
        case .rewind: String(localized: "Rewind")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .recentlyAdded: "clock"
        case .artists, .artist: "music.mic"
        case .albums, .album: "square.stack"
        case .songs: "music.note"
        case .genres, .genre: "guitars"
        case .folders, .folder: "folder"
        case .settings: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .statistics: "chart.bar"
        case .rewind: "backward.end"
        }
    }
}

enum BrowseSort: String, CaseIterable, Identifiable {
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case recentlyAdded = "Date Added"
    case quality = "Quality"
    case duration = "Duration"
    case trackNumber = "Track Number"

    var id: Self { self }

    var displayTitle: LocalizedStringResource {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .recentlyAdded: "Date Added"
        case .quality: "Quality"
        case .duration: "Duration"
        case .trackNumber: "Track Number"
        }
    }

    func compare(_ lhs: AudioTrack, _ rhs: AudioTrack) -> ComparisonResult {
        switch self {
        case .title:
            lhs.title.localizedStandardCompare(rhs.title)
        case .artist:
            lhs.artist.localizedStandardCompare(rhs.artist)
        case .album:
            lhs.album.localizedStandardCompare(rhs.album)
        case .recentlyAdded:
            rhs.addedAt.compare(lhs.addedAt)
        case .quality:
            lhs.quality.localizedStandardCompare(rhs.quality)
        case .duration:
            lhs.duration < rhs.duration ? .orderedAscending : lhs.duration > rhs.duration ? .orderedDescending : .orderedSame
        case .trackNumber:
            compareAlbumTracks(lhs, rhs)
        }
    }

    private func compareAlbumTracks(_ lhs: AudioTrack, _ rhs: AudioTrack) -> ComparisonResult {
        let leftDisc = max(1, lhs.discNumber)
        let rightDisc = max(1, rhs.discNumber)
        if lhs.trackNumber <= 0 && rhs.trackNumber <= 0 {
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
        }
        if lhs.trackNumber <= 0 { return .orderedDescending }
        if rhs.trackNumber <= 0 { return .orderedAscending }
        if leftDisc != rightDisc {
            return leftDisc < rightDisc ? .orderedAscending : .orderedDescending
        }
        if lhs.trackNumber != rhs.trackNumber {
            return lhs.trackNumber < rhs.trackNumber ? .orderedAscending : .orderedDescending
        }
        return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
    }

    func sorted(_ tracks: [AudioTrack], descending: Bool = false) -> [AudioTrack] {
        tracks.sorted { lhs, rhs in
            let result = compare(lhs, rhs)
            if result == .orderedSame {
                let title = lhs.title.localizedStandardCompare(rhs.title)
                return title == .orderedSame ? lhs.id < rhs.id : title == .orderedAscending
            }
            return result == (descending ? .orderedDescending : .orderedAscending)
        }
    }
}

struct BrowseGroup: Identifiable {
    private static let artistSeparator = try! NSRegularExpression(
        pattern: #"\s*(?:,|;|&)\s*|\s+x\s+|\s+(?:feat(?:uring|ured|ure)?|ft|with)\.?(?=\s|$)\s*"#,
        options: .caseInsensitive
    )

    let route: LibraryRoute
    let title: String
    let subtitle: String
    let tracks: [AudioTrack]
    let latest: Date

    var id: LibraryRoute { route }
    var artworkTrack: AudioTrack? { tracks.first }

    init(route: LibraryRoute, title: String, subtitle: String, tracks: [AudioTrack]) {
        self.route = route
        self.title = title
        self.subtitle = subtitle
        self.tracks = tracks
        self.latest = tracks.lazy.map(\.addedAt).max() ?? .distantPast
    }

    static func albumRoute(_ key: AudioAlbumKey) -> LibraryRoute {
        .album("\(key.title.utf8.count):\(key.title)\(key.artist)")
    }

    static func albums(_ tracks: [AudioTrack]) -> [Self] {
        Dictionary(grouping: tracks, by: \.albumKey).map { key, group in
            let tracks = BrowseSort.trackNumber.sorted(group)
            let first = tracks[0]
            let owner = first.albumArtist.isEmpty ? first.artist : first.albumArtist
            return Self(
                route: albumRoute(key),
                title: albumDisplayName(first.album),
                subtitle: artistDisplayName(owner),
                tracks: tracks
            )
        }.sorted(by: byTitle)
    }

    static func artists(_ tracks: [AudioTrack]) -> [Self] {
        var credits: [String: (name: String, tracks: [AudioTrack])] = [:]
        for track in tracks {
            var seen = Set<String>()
            for name in artistCredits(track) {
                let key = AudioTrack.artistKey(name)
                if seen.insert(key).inserted {
                    credits[key, default: (name, [])].tracks.append(track)
                }
            }
        }
        return credits.map { key, group in
            Self(
                route: .artist(key),
                title: artistDisplayName(group.name),
                subtitle: trackCount(group.tracks.count),
                tracks: group.tracks
            )
        }.sorted(by: byTitle)
    }

    static func artistCredits(_ track: AudioTrack) -> [String] {
        artistNames(track.artist.isEmpty ? track.albumArtist : track.artist)
    }

    static func artistNames(_ value: String) -> [String] {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var start = value.startIndex
        var names: [String] = []
        for match in artistSeparator.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let range = Range(match.range, in: value) else { continue }
            if start < range.lowerBound { names.append(String(value[start..<range.lowerBound])) }
            start = range.upperBound
        }
        if start < value.endIndex { names.append(String(value[start...])) }
        return names.isEmpty ? [value] : names
    }

    static func recentAlbumRepresentatives(_ tracks: [AudioTrack]) -> [AudioTrack] {
        var seen = Set<AudioAlbumKey>()
        return tracks.filter { $0.album.isEmpty || seen.insert($0.albumKey).inserted }
    }

    static func genres(_ tracks: [AudioTrack]) -> [Self] {
        Dictionary(grouping: tracks) { AudioTrack.artistKey($0.genre) }.map { key, group in
            Self(
                route: .genre(key),
                title: group[0].genre.isEmpty ? String(localized: "Unknown Genre") : group[0].genre,
                subtitle: trackCount(group.count),
                tracks: group
            )
        }.sorted(by: byTitle)
    }

    private static func byTitle(_ lhs: Self, _ rhs: Self) -> Bool {
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        if comparison == .orderedSame {
            return lhs.subtitle.localizedStandardCompare(rhs.subtitle) == .orderedAscending
        }
        return comparison == .orderedAscending
    }
}

func albumDisplayName(_ name: String) -> String {
    name.isEmpty ? String(localized: "Unknown Album") : name
}

func artistDisplayName(_ name: String) -> String {
    name.isEmpty ? String(localized: "Unknown Artist") : name
}

func trackCount(_ count: Int) -> String {
    String(localized: "Songs: \(count)")
}

func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
    let seconds = Int(seconds.rounded(.down))
    if seconds >= 3600 {
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

struct OfflineTrackFilters: Equatable {
    enum Quality: String, CaseIterable {
        case all = "All"
        case highResolution = "Hi-Res"
        case cd = "Lossless"
        case lossy = "Lossy"

        var displayTitle: LocalizedStringResource {
            switch self {
            case .all: "All"
            case .highResolution: "Hi-Res"
            case .cd: "Lossless"
            case .lossy: "Lossy"
            }
        }

        func matches(_ track: AudioTrack) -> Bool {
            if self == .all { return true }
            let knownLossless = ["FLAC", "ALAC", "PCM", "WAV", "WAVE", "AIFF", "AIF", "AIFC", "CAF",
                                 "APE", "WV", "WAVPACK", "TTA"]
            let knownLossy = ["MP3", "MP2", "AAC", "AC-3", "E-AC-3", "OPUS", "VORBIS", "OGG", "MPC", "WMA"]
            let codec = track.codec.uppercased()
            let lossless = knownLossless.contains(codec)
            let highResolution = lossless && ((track.bitDepth ?? 0) > 16 || (track.sampleRate ?? 0) > 48_000)
            switch self {
            case .all: return true
            case .highResolution: return highResolution
            case .cd: return lossless
            case .lossy: return knownLossy.contains(codec)
            }
        }
    }

    enum Metadata: String, CaseIterable {
        case all = "All"
        case complete = "Complete"
        case missingAny = "Missing Metadata"
        case artist = "Missing Artist"
        case album = "Missing Album"
        case albumArtist = "Missing Album Artist"
        case genre = "Missing Genre"
        case year = "Missing Year"
        case trackNumber = "Missing Track Number"
        case discNumber = "Missing Disc Number"

        var displayTitle: LocalizedStringResource {
            switch self {
            case .all: "All"
            case .complete: "Complete"
            case .missingAny: "Missing Metadata"
            case .artist: "Missing Artist"
            case .album: "Missing Album"
            case .albumArtist: "Missing Album Artist"
            case .genre: "Missing Genre"
            case .year: "Missing Year"
            case .trackNumber: "Missing Track Number"
            case .discNumber: "Missing Disc Number"
            }
        }

        func matches(_ track: AudioTrack) -> Bool {
            switch self {
            case .all: return true
            case .complete: return !Metadata.missingAny.matches(track)
            case .missingAny:
                return [Metadata.artist, .album, .albumArtist, .genre, .year, .trackNumber, .discNumber]
                    .contains { $0.matches(track) }
            case .artist: return track.artist.isEmpty
            case .album: return track.album.isEmpty
            case .albumArtist: return track.albumArtist.isEmpty
            case .genre: return track.genre.isEmpty
            case .year: return track.year == nil
            case .trackNumber: return track.trackNumber <= 0
            case .discNumber: return track.discNumber <= 0
            }
        }
    }

    var quality: Quality = .all
    var format: String?
    var metadata: Metadata = .all

    func matches(_ track: AudioTrack) -> Bool {
        quality.matches(track) && metadata.matches(track) &&
            (format == nil || format == track.url.pathExtension.lowercased())
    }
}

enum AlbumCompleteness: String, CaseIterable {
    case complete = "Complete"
    case incomplete = "Incomplete"
    case unknown = "Unknown Completeness"

    var displayTitle: LocalizedStringResource {
        switch self {
        case .complete: "Complete"
        case .incomplete: "Incomplete"
        case .unknown: "Unknown Completeness"
        }
    }

    init(tracks: [AudioTrack], unavailable: [LibrarySource]) {
        guard !tracks.isEmpty, !tracks.contains(where: { track in
            track.trackNumber <= 0 || track.discNumber < 0 ||
                (track.discNumber == 0 && (track.discTotal ?? 0) > 1) ||
                unavailable.contains { $0.url.containsFile(atPath: track.url.path) }
        }) else {
            self = .unknown
            return
        }
        let discs = Dictionary(grouping: tracks) { max(1, $0.discNumber) }
        let discTotals = Set(tracks.compactMap(\.discTotal))
        let maxDisc = discs.keys.max() ?? 1
        let declaredDiscs = discTotals.first
        guard discTotals.count <= 1, declaredDiscs.map({ $0 >= maxDisc }) ?? true else {
            self = .unknown
            return
        }
        var present = 0
        var counts: [Int] = []
        var incompleteDisc = false
        for disc in discs.values {
            let slots = Dictionary(grouping: disc, by: \.trackNumber)
            let totals = Set(disc.compactMap(\.trackTotal))
            guard totals.count == 1, let total = totals.first, (slots.keys.max() ?? 0) <= total,
                  slots.values.allSatisfy({ Set($0.map { AudioTrack.artistKey($0.title) }).count == 1 }) else {
                self = .unknown
                return
            }
            counts.append(total)
            present += slots.count
            incompleteDisc = incompleteDisc || slots.count < total
        }
        if let declaredDiscs, declaredDiscs > discs.count {
            self = .incomplete
        } else if maxDisc == 1 || (declaredDiscs == discs.count && Set(counts).count > 1) {
            self = incompleteDisc ? .incomplete : .complete
        } else if present < (counts.max() ?? 0) {
            self = .incomplete
        } else {
            self = .unknown
        }
    }
}

@MainActor
struct BrowseArtwork: View {
    static let cardHoverOutset = CGSize(width: 4, height: 3)

    let library: LibraryStore
    let track: AudioTrack?
    var symbol = "music.note"
    var pixelSize = 320
    var circular = false

    @State private var image: NSImage?

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    var body: some View {
        Color(nsColor: .controlBackgroundColor)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    GeometryReader { proxy in
                        Image(systemName: symbol)
                            .font(.system(size: max(14, proxy.size.width * 0.29), weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: circular ? 512 : 9))
            .overlay {
                RoundedRectangle(cornerRadius: circular ? 512 : 9)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
            .accessibilityHidden(true)
            .task(id: track?.id) {
                image = nil
                guard let track else { return }
                let key = "\(pixelSize):\(track.id)" as NSString
                if let cached = Self.cache.object(forKey: key) {
                    image = cached
                    return
                }
                guard let data = await library.artwork(for: track), !Task.isCancelled else { return }
                let size = pixelSize
                let thumbnail = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                    let options = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: size
                    ] as CFDictionary
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
                }.value
                guard let thumbnail, !Task.isCancelled else { return }
                let artwork = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
                Self.cache.setObject(artwork, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
                image = artwork
            }
    }
}

struct BrowseHeading<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var back: (() -> Void)? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let back {
                Button("Back", systemImage: "chevron.left", action: back)
                    .labelStyle(.iconOnly)
                    .buttonStyle(GlassHoverButtonStyle(iconOnly: true))
                    .help("Back")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            actions()
        }
        .padding(.top, 21)
        .padding(.bottom, 12)
    }
}

extension View {
    func browseHoverGutter(_ edges: Edge.Set = .horizontal) -> some View {
        let gutter: CGFloat = 7
        return contentMargins(edges, gutter, for: .scrollContent)
            .padding(edges, -gutter)
    }

    func browseGlassHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        modifier(BrowseGlassHeader(header: header()))
    }
}

private struct BrowseGlassHeader<Header: View>: ViewModifier {
    let header: Header
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.safeAreaBar(edge: .top, spacing: 0) {
            let bar = header.frame(maxWidth: .infinity, alignment: .leading)
            if reduceTransparency {
                bar.background(Color(nsColor: .windowBackgroundColor))
            } else {
                bar.glassEffect(.regular, in: Rectangle())
            }
        }
    }
}

struct BrowseEmpty: View {
    let title: LocalizedStringResource
    let symbol: String
    var detail: LocalizedStringResource? = nil

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
        } description: {
            if let detail { Text(detail) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
