#if MUZIKA_DEV_LOGS
import OSLog
#endif

enum MuzikaDiagnostics {
    static func report(_ message: @autoclosure () -> String) {
        #if MUZIKA_DEV_LOGS
        let event = message()
        Logger(subsystem: "app.muzika.local", category: "Application").debug("\(event, privacy: .private)")
        #endif
    }
}

#if MUZIKA_DEV_LOGS
enum MuzikaTrace {
    static let subsystem = "app.muzika.local"

    enum Area: String, CaseIterable, Sendable {
        case app = "Application"
        case lyrics = "Lyrics"
        case queue = "Queue"
        case player = "NowPlaying"
        case controls = "PlayerControls"
        case library = "Library"
        case window = "Window"
    }

    private static let loggers = Dictionary(uniqueKeysWithValues: Area.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })

    static func event(_ area: Area, _ name: StaticString, _ fields: @autoclosure () -> String = "") {
        guard let logger = loggers[area] else { return }
        let details = fields()
        logger.notice("\(String(describing: name), privacy: .public) \(details, privacy: .public)")
    }

    static func routeName(_ route: LibraryRoute) -> String {
        switch route {
        case .home: "home"
        case .search: "search"
        case .recentlyAdded: "recently-added"
        case .artists: "artists"
        case .albums: "albums"
        case .songs: "songs"
        case .genres: "genres"
        case .folders: "folders"
        case .settings: "settings"
        case .artist: "artist"
        case .album: "album"
        case .genre: "genre"
        case .folder: "folder"
        case .history: "history"
        case .statistics: "statistics"
        case .rewind: "rewind"
        }
    }

    static func panelName(_ panel: PlayerPanel?) -> String {
        switch panel {
        case .lyrics: "lyrics"
        case .queue: "queue"
        case nil: "closed"
        }
    }
}

struct MuzikaFrameMetrics {
    private var started: Double?
    private var previous: Double?
    private var previousPosition: Double?
    private var frames = 0
    private var gapsOver50ms = 0
    private var heldPositions = 0
    private var longestGap = 0.0
    private var largestStep = 0.0

    mutating func record(at timestamp: Double, position: Double? = nil) {
        if started == nil { started = timestamp }
        if let previous {
            let gap = max(0, timestamp - previous)
            longestGap = max(gap, longestGap)
            if gap > 0.05 { gapsOver50ms += 1 }
        }
        if let previousPosition, let position {
            let step = abs(position - previousPosition)
            if step < 0.0001 { heldPositions += 1 }
            largestStep = max(largestStep, step)
        }
        previous = timestamp
        previousPosition = position
        frames += 1
    }

    var summary: String {
        let elapsed = max(0, (previous ?? 0) - (started ?? 0))
        return "callbacks=\(frames) elapsed_ms=\((elapsed * 1000).rounded()) longest_gap_ms=\((longestGap * 1000).rounded()) gaps_over_50ms=\(gapsOver50ms) held_positions=\(heldPositions) largest_position_step=\(largestStep)"
    }

    mutating func reportIfReady(_ area: MuzikaTrace.Area, _ name: StaticString) {
        guard let started, let previous, previous - started >= 1 else { return }
        MuzikaTrace.event(area, name, summary)
        self = MuzikaFrameMetrics()
        record(at: previous)
    }
}
#endif
