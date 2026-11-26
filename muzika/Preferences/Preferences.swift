import Foundation
import Observation

enum PreferencesPage: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case playback = "Playback"
    case lyrics = "Lyrics"
    case localLibrary = "Local Library"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case storage = "Storage & Cache"
    case about = "About"

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: String(localized: "Appearance")
        case .playback: String(localized: "Playback")
        case .lyrics: String(localized: "Lyrics")
        case .localLibrary: String(localized: "Local Library")
        case .keyboardShortcuts: String(localized: "Keyboard Shortcuts")
        case .storage: String(localized: "Storage & Cache")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .playback: "play.circle"
        case .lyrics: "quote.bubble"
        case .localLibrary: "folder"
        case .keyboardShortcuts: "keyboard"
        case .storage: "internaldrive"
        case .about: "info.circle"
        }
    }
}

enum PreferencesItem: String, CaseIterable, Identifiable {
    case heroAnimations = "Hero animations"
    case blurEffects = "Always use blur effects"
    case nowPlayingAudioSpectrum = "Now Playing audio spectrum"
    case interfaceSize = "Interface size"
    case historyView = "History View"
    case continueListening = "Continue listening"
    case loudVolume = "Confirm loud volume"
    case loudVolumeThreshold = "Ask above"
    case gapless = "Gapless playback"
    case noDuplicates = "No duplicates in queue"
    case lockQueue = "Lock queue"
    case spatialAudio = "Spatial audio"
    case coverArt = "Cover art"
    case listeningStatistics = "Listening statistics"
    case lyricsSize = "Lyrics text size"
    case lyricsBlur = "Lyrics blur"
    case animatedWordHighlighting = "Animated word highlighting"
    case lyricsTiming = "Lyrics timing"
    case defaultView = "Default view"
    case audioQuality = "Audio quality"
    case songTap = "Tapping a song"
    case autoScan = "Auto Scan"
    case addFolder = "Add library folder"
    case scanStatus = "Scan Status"
    case scanLibrary = "Scan Library"
    case forceScan = "Force Full Scan"
    case cleanupMissing = "Cleanup Missing Files"
    case unreadableFiles = "Unreadable files"
    case clearLibrary = "Clear Library"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case coverCache = "Library cover cache"
    case clearCache = "Clear cache"
    case version = "Version"
    case bundleVersion = "Bundle Version"
    case license = "GNU General Public License Version 3"

    var id: Self { self }

    var title: String {
        switch self {
        case .heroAnimations: String(localized: "Hero animations")
        case .blurEffects: String(localized: "Always use blur effects")
        case .nowPlayingAudioSpectrum: String(localized: "Now Playing audio spectrum")
        case .interfaceSize: String(localized: "Interface size")
        case .historyView: String(localized: "History View")
        case .continueListening: String(localized: "Continue listening")
        case .loudVolume: String(localized: "Confirm loud volume")
        case .loudVolumeThreshold: String(localized: "Ask above")
        case .gapless: String(localized: "Gapless playback")
        case .noDuplicates: String(localized: "No duplicates in queue")
        case .lockQueue: String(localized: "Lock queue")
        case .spatialAudio: String(localized: "Spatial audio")
        case .coverArt: String(localized: "Cover art")
        case .listeningStatistics: String(localized: "Listening statistics")
        case .lyricsSize: String(localized: "Lyrics text size")
        case .lyricsBlur: String(localized: "Lyrics blur")
        case .animatedWordHighlighting: String(localized: "Animated word highlighting")
        case .lyricsTiming: String(localized: "Lyrics timing")
        case .defaultView: String(localized: "Default view")
        case .audioQuality: String(localized: "Audio quality")
        case .songTap: String(localized: "Tapping a song")
        case .autoScan: String(localized: "Auto Scan")
        case .addFolder: String(localized: "Add library folder")
        case .scanStatus: String(localized: "Scan Status")
        case .scanLibrary: String(localized: "Scan Library")
        case .forceScan: String(localized: "Force Full Scan")
        case .cleanupMissing: String(localized: "Cleanup Missing Files")
        case .unreadableFiles: String(localized: "Unreadable files")
        case .clearLibrary: String(localized: "Clear Library")
        case .keyboardShortcuts: String(localized: "Keyboard Shortcuts")
        case .coverCache: String(localized: "Library cover cache")
        case .clearCache: String(localized: "Clear cache")
        case .version: String(localized: "Version")
        case .bundleVersion: String(localized: "Bundle Version")
        case .license: String(localized: "GNU General Public License Version 3")
        }
    }

    var page: PreferencesPage {
        switch self {
        case .heroAnimations, .blurEffects, .nowPlayingAudioSpectrum, .interfaceSize, .historyView, .continueListening:
            .appearance
        case .loudVolume, .loudVolumeThreshold, .gapless, .noDuplicates, .lockQueue, .spatialAudio,
             .coverArt, .listeningStatistics:
            .playback
        case .lyricsSize, .lyricsBlur, .animatedWordHighlighting, .lyricsTiming:
            .lyrics
        case .defaultView, .audioQuality, .songTap, .autoScan, .addFolder, .scanStatus, .scanLibrary, .forceScan,
             .cleanupMissing, .unreadableFiles, .clearLibrary:
            .localLibrary
        case .keyboardShortcuts:
            .keyboardShortcuts
        case .coverCache, .clearCache:
            .storage
        case .version, .bundleVersion, .license:
            .about
        }
    }

    private var searchTerms: String {
        switch self {
        case .interfaceSize: String(localized: "scale smaller larger")
        case .historyView: String(localized: "list album grid")
        case .loudVolumeThreshold: String(localized: "volume threshold")
        case .coverArt: String(localized: "card full screen artwork")
        case .lyricsSize: String(localized: "font size reset")
        case .lyricsTiming: String(localized: "offset sync earlier later reset")
        case .audioQuality: String(localized: "format bit depth sample rate bitrate")
        case .songTap: String(localized: "open details play song")
        case .autoScan: String(localized: "schedule daily weekly app open")
        case .addFolder: String(localized: "source manage remove folder")
        case .scanStatus: String(localized: "scan library progress pause resume cancel last scanned")
        case .unreadableFiles: String(localized: "skipped unavailable read errors")
        case .license: String(localized: "GPL-3.0")
        default: ""
        }
    }

    static func matching(_ query: String) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let normalized = terms.joined(separator: " ")
        var exactMatches: [Self] = []
        var titleMatches: [Self] = []
        var relatedMatches: [Self] = []
        for item in allCases {
            let title = item.title
            let keywords = "\(title) \(item.page.title) \(item.searchTerms) \(item.rawValue) \(item.page.rawValue)"
            if title.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                exactMatches.append(item)
            } else if terms.allSatisfy(title.localizedStandardContains) {
                titleMatches.append(item)
            } else if terms.allSatisfy(keywords.localizedStandardContains) {
                relatedMatches.append(item)
            }
        }
        return exactMatches + titleMatches + relatedMatches
    }
}

enum AutoScan: String, CaseIterable, Identifiable {
    case off = "Off"
    case opening = "Every app open"
    case daily = "Daily"
    case weekly = "Weekly"

    var id: Self { self }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .opening: String(localized: "Every app open")
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off, .opening: nil
        case .daily: 86_400
        case .weekly: 604_800
        }
    }

    func due(last: Date?, now: Date) -> Bool {
        guard self != .opening else { return true }
        guard let interval else { return false }
        return last.map { now.timeIntervalSince($0) >= interval } ?? true
    }
}

enum CoverStyle: String, CaseIterable, Identifiable {
    case card = "Card"
    case fullscreen = "Full screen"

    var id: Self { self }

    var title: String {
        switch self {
        case .card: String(localized: "Card")
        case .fullscreen: String(localized: "Full screen")
        }
    }
}

@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var heroAnimations: Bool {
        didSet { defaults.set(heroAnimations, forKey: "appearance.heroAnimations") }
    }
    var forceBlur: Bool {
        didSet { defaults.set(forceBlur, forKey: "appearance.forceBlur") }
    }
    var showsNowPlayingAudioSpectrum: Bool {
        didSet { defaults.set(showsNowPlayingAudioSpectrum, forKey: "appearance.nowPlayingAudioSpectrum") }
    }
    var largerInterface: Bool {
        didSet { defaults.set(largerInterface, forKey: "appearance.largerInterface") }
    }
    var historyGrid: Bool {
        didSet { defaults.set(historyGrid, forKey: "appearance.historyGrid") }
    }
    var confirmLoudVolume: Bool {
        didSet { defaults.set(confirmLoudVolume, forKey: "playback.confirmVolume") }
    }
    var loudVolumeLevel: Double {
        didSet { defaults.set(loudVolumeLevel, forKey: "playback.loudVolumeLevel") }
    }
    var coverStyle: CoverStyle {
        didSet { defaults.set(coverStyle.rawValue, forKey: "playback.coverStyle") }
    }
    var lyricsSize: Double {
        didSet { defaults.set(lyricsSize, forKey: "lyrics.size") }
    }
    var lyricsBlur: Bool {
        didSet { defaults.set(lyricsBlur, forKey: "lyrics.blur") }
    }
    var animatesWordHighlighting: Bool {
        didSet { defaults.set(animatesWordHighlighting, forKey: "lyrics.animatesWordHighlighting") }
    }
    var lyricsOffset: Double {
        didSet { defaults.set(lyricsOffset, forKey: "lyrics.offset") }
    }
    var defaultView: LibraryDefaultView {
        didSet { defaults.set(defaultView.rawValue, forKey: "library.defaultView") }
    }
    var audioQuality: QualityDisplay {
        didSet { defaults.set(audioQuality.rawValue, forKey: "library.audioQuality") }
    }
    var songTap: SongTap {
        didSet { defaults.set(songTap.rawValue, forKey: "library.songTap") }
    }
    var lastLibraryView: LibraryDefaultView {
        get { LibraryDefaultView(rawValue: defaults.string(forKey: "library.lastView") ?? "") ?? .recentlyAdded }
        set { defaults.set(newValue.rawValue, forKey: "library.lastView") }
    }

    var autoScan: AutoScan {
        didSet { defaults.set(autoScan.rawValue, forKey: "library.autoScan") }
    }
    var lastScan: Date? {
        didSet { defaults.set(lastScan, forKey: "library.lastScan") }
    }

    init() {
        let defaults = UserDefaults.standard
        heroAnimations = defaults.object(forKey: "appearance.heroAnimations") as? Bool ?? true
        forceBlur = defaults.bool(forKey: "appearance.forceBlur")
        showsNowPlayingAudioSpectrum = defaults.object(forKey: "appearance.nowPlayingAudioSpectrum") as? Bool ?? true
        largerInterface = defaults.bool(forKey: "appearance.largerInterface")
        historyGrid = defaults.object(forKey: "appearance.historyGrid") as? Bool ?? true
        confirmLoudVolume = defaults.bool(forKey: "playback.confirmVolume")
        loudVolumeLevel = defaults.object(forKey: "playback.loudVolumeLevel") as? Double ?? 0.8
        coverStyle = CoverStyle(rawValue: defaults.string(forKey: "playback.coverStyle") ?? "") ?? .card
        lyricsSize = defaults.object(forKey: "lyrics.size") as? Double ?? 1
        lyricsBlur = defaults.object(forKey: "lyrics.blur") as? Bool ?? true
        animatesWordHighlighting = defaults.object(forKey: "lyrics.animatesWordHighlighting") as? Bool ?? true
        lyricsOffset = defaults.object(forKey: "lyrics.offset") as? Double ?? 0
        defaultView = LibraryDefaultView(rawValue: defaults.string(forKey: "library.defaultView") ?? "") ?? .lastUsed
        audioQuality = QualityDisplay(rawValue: defaults.string(forKey: "library.audioQuality") ?? "") ?? .fileFormat
        songTap = SongTap(rawValue: defaults.string(forKey: "library.songTap") ?? "") ?? .play
        autoScan = AutoScan(rawValue: defaults.string(forKey: "library.autoScan") ?? "") ?? .off
        lastScan = defaults.object(forKey: "library.lastScan") as? Date
    }
}

enum LibraryDefaultView: String, CaseIterable, Identifiable {
    case lastUsed = "Last used"
    case recentlyAdded = "Recently Added"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case genres = "Genres"
    case folders = "Folders"

    var id: Self { self }

    var title: String {
        switch self {
        case .lastUsed: String(localized: "Last used")
        case .recentlyAdded: String(localized: "Recently Added")
        case .artists: String(localized: "Artists")
        case .albums: String(localized: "Albums")
        case .songs: String(localized: "Songs")
        case .genres: String(localized: "Genres")
        case .folders: String(localized: "Folders")
        }
    }

    var route: LibraryRoute? {
        switch self {
        case .lastUsed: nil
        case .recentlyAdded: .recentlyAdded
        case .artists: .artists
        case .albums: .albums
        case .songs: .songs
        case .genres: .genres
        case .folders: .folders
        }
    }

    init?(route: LibraryRoute) {
        guard let value = Self.allCases.first(where: { $0.route == route.sidebarRoute }) else { return nil }
        self = value
    }
}

enum QualityDisplay: String, CaseIterable, Identifiable {
    case fileFormat = "File format"
    case bitDepth = "Bit Depth"
    case sampleRate = "Sample Rate"
    case bitrate = "Bitrate"

    var id: Self { self }

    var title: String {
        switch self {
        case .fileFormat: String(localized: "File format")
        case .bitDepth: String(localized: "Bit Depth")
        case .sampleRate: String(localized: "Sample Rate")
        case .bitrate: String(localized: "Bitrate")
        }
    }

    func value(for track: AudioTrack) -> String {
        switch self {
        case .fileFormat: track.codecTitle
        case .bitDepth: track.formattedBitDepth ?? "—"
        case .sampleRate: track.formattedSampleRate ?? "—"
        case .bitrate: track.formattedBitrate ?? "—"
        }
    }
}

enum SongTap: String, CaseIterable, Identifiable {
    case details = "Open details"
    case play = "Play song"

    var id: Self { self }

    var title: String {
        switch self {
        case .details: String(localized: "Open details")
        case .play: String(localized: "Play song")
        }
    }
}
