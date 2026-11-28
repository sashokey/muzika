import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum PlayerPanel {
    case lyrics
    case queue
}

@MainActor
@Observable
final class AppState {
    let library = LibraryStore()
    let history = HistoryStore()
    let preferences = Preferences()
    let playback: PlaybackController
    @ObservationIgnored private let system: SystemPlayback

    private(set) var route = LibraryRoute.home
    private var backRoutes: [LibraryRoute] = []
    private var forwardRoutes: [LibraryRoute] = []
    private(set) var showingPlayer = false
    var panel: PlayerPanel?
    var settingsPage: PreferencesPage?
    var showingInfo = false
    var pendingVolume: Double?
    var message: String?
    private(set) var importing = false
    @ObservationIgnored private var imported: [URL] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var volumeConfirmed = false

    init() {
        playback = PlaybackController(library: library)
        system = SystemPlayback(library: library, playback: playback)
        playback.onTrackStarted = { [weak history] track in history?.started(track) }
        playback.onListen = { [weak history] track, seconds in history?.listened(track, seconds: seconds) }
        playback.onNowPlayingChange = { [weak system] in system?.update() }
    }

    var canGoBack: Bool { !backRoutes.isEmpty || settingsPage != nil || showingPlayer }
    var canGoForward: Bool { !forwardRoutes.isEmpty }
    var scanSchedule: LibraryScanSchedule {
        LibraryScanSchedule(
            interval: preferences.autoScan.interval,
            lastCompletion: library.lastCompletedScan ?? preferences.lastScan,
            hasSources: !library.sources.isEmpty
        )
    }

    func start() {
        guard !started else { return }
        started = true
        playback.restore()
        if preferences.autoScan == .opening {
            Task { await scan() }
        }
    }

    func runScheduledScans(_ schedule: LibraryScanSchedule) async {
        guard let delay = schedule.delay(now: .now) else { return }
        do {
            try await Task.sleep(for: delay)
            while schedule == scanSchedule {
                if !library.isScanning { await scan() }
                guard schedule == scanSchedule else { return }
                try await Task.sleep(for: .seconds(900))
            }
        } catch {}
    }

    func navigate(_ destination: LibraryRoute) {
        closePlayer()
        if destination != route {
            backRoutes.append(route)
            forwardRoutes.removeAll()
            route = destination
            if let last = LibraryDefaultView(route: destination) { preferences.lastLibraryView = last }
            settingsPage = nil
        }
        if destination == .search {
            NotificationCenter.default.post(name: .focusLibrarySearch, object: nil)
        }
    }

    func openLibrary() {
        navigate(preferences.defaultView.route ?? preferences.lastLibraryView.route ?? .recentlyAdded)
    }

    func back() {
        if showingPlayer {
            closePlayer()
        } else if settingsPage != nil {
            settingsPage = nil
        } else if let previous = backRoutes.popLast() {
            forwardRoutes.append(route)
            route = previous
        }
    }

    func forward() {
        if let next = forwardRoutes.popLast() {
            closePlayer()
            settingsPage = nil
            backRoutes.append(route)
            route = next
        }
    }

    func togglePanel(_ tab: PlayerPanel) {
        guard playback.current != nil else { return }
        if showingPlayer {
            panel = panel == tab ? nil : tab
        } else {
            panel = tab
            showingPlayer = true
        }
    }

    func showPlayer() {
        guard playback.current != nil else { return }
        showingPlayer = true
    }

    func closePlayer() {
        if showingPlayer { showingPlayer = false }
        if showingInfo { showingInfo = false }
    }

    func dismiss() {
        if showingInfo { showingInfo = false }
        else if showingPlayer { closePlayer() }
        else if settingsPage != nil { settingsPage = nil }
        else { back() }
    }

    func dismissPlayback() {
        closePlayer()
        panel = nil
        playback.dismiss()
    }

    func setVolume(_ proposed: Double) {
        let value = min(max(proposed, 0), 1)
        if value <= preferences.loudVolumeLevel { volumeConfirmed = false }
        if preferences.confirmLoudVolume, !volumeConfirmed,
           value > preferences.loudVolumeLevel, value > playback.volume {
            pendingVolume = value
        } else {
            playback.volume = value
        }
    }

    func acceptVolume() {
        if let pendingVolume {
            volumeConfirmed = true
            playback.volume = pendingVolume
        }
        pendingVolume = nil
    }

    func chooseFiles(folder: Bool = false, appendSource: Bool = false) {
        Task {
            let panel = NSOpenPanel()
            panel.canChooseFiles = !folder
            panel.canChooseDirectories = folder
            panel.allowsMultipleSelection = !folder
            panel.canCreateDirectories = false
            if !folder {
                panel.allowedContentTypes = AudioFileMetadata.supportedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
            }
            panel.prompt = appendSource ? String(localized: "Add") : String(localized: "Open")
            if await panel.begin() == .OK {
                if appendSource, let url = panel.url {
                    await library.addSource(url)
                } else {
                    open(panel.urls)
                }
            }
        }
    }

    func open(_ urls: [URL]) {
        imported.append(contentsOf: urls.filter(\.isFileURL))
        guard !importing, !imported.isEmpty else { return }
        importing = true
        Task {
            defer { importing = false }
            while !imported.isEmpty {
                let urls = imported
                imported.removeAll()
                let tracks = await library.indexTemporary(urls)
                if let first = tracks.first {
                    playback.play(first, in: tracks)
                }
                if let error = library.temporaryError {
                    message = error
                } else if tracks.isEmpty {
                    message = String(localized: "No supported audio files were found.")
                }
            }
        }
    }

    func scan(force: Bool = false) async {
        guard !library.sources.isEmpty else { return }
        await library.rescan(force: force)
    }

    func refresh() {
        if route == .search {
            NotificationCenter.default.post(name: .refreshLibraryPage, object: nil)
        } else {
            Task { await scan() }
        }
    }
}
