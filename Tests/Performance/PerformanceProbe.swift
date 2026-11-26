import AppKit
import AVFAudio
import CoreImage
import Darwin
import Foundation
import Metal
import OSLog
import QuartzCore
import ScreenCaptureKit
import SwiftUI
import Synchronization

struct GPUSlice: Sendable {
    let start: Double
    let end: Double
}

enum PerformanceGPU {
    private static let slices = Mutex<[GPUSlice]>([])
    private static let presentations = Mutex<[Double]>([])

    static func observe(_ drawable: any MTLDrawable) {
        drawable.addPresentedHandler { drawable in
            if drawable.presentedTime > 0 {
                presentations.withLock { $0.append(drawable.presentedTime) }
            }
        }
    }

    static func presentedFrames(from lower: Double, to upper: Double) -> [Double] {
        presentations.withLock { times in
            let measured = times.filter { $0 >= lower && $0 <= upper }.sorted()
            times.removeAll { $0 <= upper }
            return measured
        }
    }

    static func record(_ buffer: any MTLCommandBuffer) {
        let start = buffer.gpuStartTime
        let end = buffer.gpuEndTime
        guard start > 0, end > start else { return }
        slices.withLock { $0.append(GPUSlice(start: start, end: end)) }
    }

    static func milliseconds(from lower: Double, to upper: Double) -> Double? {
        slices.withLock { slices in
            let durations = slices.compactMap { slice -> Double? in
                let overlap = min(upper, slice.end) - max(lower, slice.start)
                return overlap > 0 ? overlap * 1000 : nil
            }
            slices.removeAll { $0.end <= upper }
            return durations.isEmpty ? nil : durations.reduce(0, +)
        }
    }
}

final class BenchmarkDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func data(forKey defaultName: String) -> Data? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

enum BenchmarkPaths {
    static var scratch: URL {
        URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
    }

    static var library: URL { scratch.appending(path: "library.json") }
    static var history: URL { scratch.appending(path: "history.json") }
}

func benchmarkWindowOrigin(window: CGSize, in screen: CGRect) -> CGPoint {
    let margin: CGFloat = 18
    return CGPoint(x: max(screen.minX, screen.maxX - window.width - margin),
                   y: screen.minY + min(margin, max(0, screen.height - window.height)))
}

private final class PerformanceWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct BenchmarkSample: Codable {
    let action: String
    let iteration: Int
    let actionWallMilliseconds: Double
    let sampledWallMilliseconds: Double
    let cpuMilliseconds: Double
    let appMetalMilliseconds: Double?
    let ramBeforeMiB: Double
    let ramAfterMiB: Double
    let sampledPeakRAMMiB: Double
    let windowVisible: Bool
    let displayMaximumHz: Int
    let lowPowerMode: Bool
    let macOS: String
    let playbackMode: String
    let metalPresentedFrames: Int
    let metalFrameIntervalP95Milliseconds: Double?

    enum CodingKeys: String, CodingKey {
        case action, iteration, actionWallMilliseconds, sampledWallMilliseconds
        case cpuMilliseconds, appMetalMilliseconds, ramBeforeMiB, ramAfterMiB, sampledPeakRAMMiB
        case windowVisible, displayMaximumHz, lowPowerMode, macOS, playbackMode
        case metalPresentedFrames, metalFrameIntervalP95Milliseconds
    }

    func encode(to encoder: Encoder) throws {
        var data = encoder.container(keyedBy: CodingKeys.self)
        try data.encode(action, forKey: .action)
        try data.encode(iteration, forKey: .iteration)
        try data.encode(actionWallMilliseconds, forKey: .actionWallMilliseconds)
        try data.encode(sampledWallMilliseconds, forKey: .sampledWallMilliseconds)
        try data.encode(cpuMilliseconds, forKey: .cpuMilliseconds)
        try data.encode(appMetalMilliseconds, forKey: .appMetalMilliseconds)
        try data.encode(ramBeforeMiB, forKey: .ramBeforeMiB)
        try data.encode(ramAfterMiB, forKey: .ramAfterMiB)
        try data.encode(sampledPeakRAMMiB, forKey: .sampledPeakRAMMiB)
        try data.encode(windowVisible, forKey: .windowVisible)
        try data.encode(displayMaximumHz, forKey: .displayMaximumHz)
        try data.encode(lowPowerMode, forKey: .lowPowerMode)
        try data.encode(macOS, forKey: .macOS)
        try data.encode(playbackMode, forKey: .playbackMode)
        try data.encode(metalPresentedFrames, forKey: .metalPresentedFrames)
        try data.encode(metalFrameIntervalP95Milliseconds, forKey: .metalFrameIntervalP95Milliseconds)
    }
}

@main
@MainActor
enum PerformanceProbe {
    private static let signposts = OSSignposter(logHandle: OSLog(subsystem: "org.muzika.performance", category: .pointsOfInterest))

    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard showsWindow else {
            try await run()
            return
        }
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    private static func run() async throws {
        let report = URL(filePath: CommandLine.arguments[2])
        let repetitions = max(1, Int(CommandLine.arguments[3]) ?? 3)
        let mode = CommandLine.arguments.dropFirst(4).first ?? "suite"
        let stress = mode == "stress" || mode == "stress-compositor"
        var actions: [Action]
        if mode == "home" {
            actions = [
                Action("home.shuffle_scroll_down") { try await HomeScrollCheck.run(host: $0.host, window: $0.window, down: true) },
                Action("home.shuffle_scroll_up") { try await HomeScrollCheck.run(host: $0.host, window: $0.window, down: false) },
            ]
        } else if stress {
            actions = stressActions()
        } else {
            actions = try benchmarkActions()
        }
        if let filter = ProcessInfo.processInfo.environment["MUZIKA_PERFORMANCE_ACTIONS"] {
            let names = Set(filter.split(separator: ",").map(String.init))
            actions = actions.filter { names.contains($0.name) }
            guard !actions.isEmpty, actions.count == names.count else {
                throw HomeScrollCheck.Failure("Invalid performance action selection")
            }
        }
        var results: [BenchmarkSample] = []
        for iteration in 1...repetitions {
            let fixture = try Fixture(stress: stress)
            try await Task.sleep(for: .milliseconds(showsWindow ? 500 : 150))
            fixture.host.layoutSubtreeIfNeeded()
            try await fixture.waitForVisibility()
            for action in actions {
                results.append(try await measure(action, iteration: iteration, fixture: fixture))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: report, options: .atomic)
        print("\(actions.count) actions × \(repetitions) repeats, \(results.filter { $0.appMetalMilliseconds != nil }.count) samples with timed Metal commands")
    }

    private static var showsWindow: Bool {
        ProcessInfo.processInfo.environment["MUZIKA_PERFORMANCE_VISIBLE"] == "1"
    }

    private static var checksWrappedLyrics: Bool {
        ProcessInfo.processInfo.environment["MUZIKA_TEST_WRAPPED_LYRICS"] == "1"
    }

    private static func measure(_ action: Action, iteration: Int, fixture: Fixture) async throws -> BenchmarkSample {
        try fixture.checkVisibility()
        let playbackMode = fixture.state.playback.playing ? "offline" : "idle"
        let interval = signposts.beginInterval("Action", id: signposts.makeSignpostID(), "\(action.name, privacy: .public)")
        defer { signposts.endInterval("Action", interval) }

        let clock = ContinuousClock()
        let started = clock.now
        let gpuStart = CACurrentMediaTime()
        let cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let memoryBefore = try footprint()
        var memoryPeak = memoryBefore

        try await action.run(fixture)
        fixture.host.layoutSubtreeIfNeeded()
        let work = milliseconds(started.duration(to: clock.now))
        if !action.name.hasPrefix("home.shuffle_scroll_") {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(45))
                fixture.host.layoutSubtreeIfNeeded()
                memoryPeak = max(memoryPeak, try footprint())
            }
        }
        try fixture.checkVisibility()
        let memoryAfter = try footprint()
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart) / 1_000_000
        let frameEnd = CACurrentMediaTime()
        let gpu = PerformanceGPU.milliseconds(from: gpuStart, to: frameEnd)
        let frames = PerformanceGPU.presentedFrames(from: gpuStart, to: frameEnd)
        let intervals = zip(frames, frames.dropFirst()).map { ($1 - $0) * 1_000 }.sorted()
        let p95 = intervals.isEmpty ? nil : intervals[Int(ceil(Double(intervals.count) * 0.95)) - 1]
        return BenchmarkSample(
            action: action.name, iteration: iteration, actionWallMilliseconds: work,
            sampledWallMilliseconds: milliseconds(started.duration(to: clock.now)),
            cpuMilliseconds: cpu, appMetalMilliseconds: gpu,
            ramBeforeMiB: memoryBefore, ramAfterMiB: memoryAfter, sampledPeakRAMMiB: max(memoryPeak, memoryAfter),
            windowVisible: fixture.window.occlusionState.contains(.visible),
            displayMaximumHz: fixture.window.screen?.maximumFramesPerSecond ?? 0,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            playbackMode: playbackMode, metalPresentedFrames: frames.count, metalFrameIntervalP95Milliseconds: p95
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private static func footprint() throws -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw CocoaError(.fileReadUnknown) }
        return Double(info.phys_footprint) / 1_048_576
    }

    private struct Action {
        let name: String
        let run: (Fixture) async throws -> Void

        init(_ name: String, _ run: @escaping (Fixture) async throws -> Void) {
            self.name = name
            self.run = run
        }
    }

    private static func stressActions() -> [Action] {
        let scrollingPages: [(String, LibraryRoute)] = [
            ("search", .search), ("recently_added", .recentlyAdded), ("artists", .artists),
            ("albums", .albums), ("songs", .songs), ("genres", .genres), ("history", .history),
        ]
        let lists = scrollingPages.map { name, route in
            Action("stress.\(name)") { fixture in
                fixture.state.navigate(route)
                try await fixture.scrollLargePage(name)
            }
        }
        let detailPages = ["artist", "album", "genre"].map { name in
            Action("stress.\(name)_tracks") { fixture in
                guard let route = fixture.largeGroupRoutes[name] else {
                    throw HomeScrollCheck.Failure("Missing \(name) fixture with 5,000 tracks")
                }
                try await fixture.navigateAndScroll(route, name: name, table: true)
            }
        }
        let summaryPages: [(String, LibraryRoute)] = [
            ("home", .home), ("library_sources", .folders), ("statistics", .statistics),
            ("rewind", .rewind), ("settings", .settings),
        ]
        let summaries = summaryPages.map { name, route in Action("stress.\(name)") { $0.state.navigate(route) } }
        let settings = PreferencesPage.allCases.map { page in
            Action("stress.settings.\(page.rawValue)") { $0.state.settingsPage = page }
        }
        return lists + detailPages + [
            Action("stress.folders") { fixture in
                try await fixture.navigateAndScroll(.folder(fixture.rootFolder), name: "Folders", table: false)
            },
            Action("stress.folder_tracks") { fixture in
                let folder = fixture.rootFolder.appending(path: "Large Collection")
                try await fixture.navigateAndScroll(.folder(folder), name: "Folder tracks", table: true)
            },
        ] + summaries + settings + [
            Action("stress.now_playing.lyrics_timed") { fixture in
                let track = fixture.media[0]
                try await fixture.validateLyrics(track, timed: true)
                fixture.playPaused(track, in: [track])
                fixture.state.togglePanel(.lyrics)
                let view = try await StressScrollCheck.longScroll(in: fixture.host, name: "Timed Lyrics") {
                    $0 is TimedLyricsScrollView
                }
                try await StressScrollCheck.scroll(view, name: "Timed Lyrics")
            },
            Action("stress.now_playing.lyrics_seek") { fixture in
                let view = try await StressScrollCheck.longScroll(in: fixture.host, name: "Timed Lyrics") {
                    $0 is TimedLyricsScrollView
                }
                fixture.state.playback.seek(to: 45)
                try await Task.sleep(for: .milliseconds(550))
                guard view.contentView.bounds.minY >= 20_000 else {
                    throw HomeScrollCheck.Failure("Lyrics did not reveal the late cue after seeking")
                }
            },
            Action("stress.now_playing.lyrics_untimed") { fixture in
                let track = fixture.media[1]
                try await fixture.validateLyrics(track, timed: false)
                fixture.playPaused(track, in: [track])
                let view = try await StressScrollCheck.longScroll(in: fixture.host, name: "Untimed Lyrics") {
                    !($0 is TimedLyricsScrollView)
                }
                try await StressScrollCheck.scroll(view, name: "Untimed Lyrics")
                if checksWrappedLyrics {
                    let initialWidth = view.contentSize.width
                    fixture.window.setContentSize(NSSize(width: 860, height: 860))
                    if let screen = fixture.window.screen {
                        fixture.window.setFrameOrigin(benchmarkWindowOrigin(window: fixture.window.frame.size,
                                                                           in: screen.visibleFrame))
                    }
                    try await Task.sleep(for: .milliseconds(550))
                    let resized = try await StressScrollCheck.longScroll(in: fixture.host, name: "Wrapped Lyrics after resize") {
                        !($0 is TimedLyricsScrollView) && $0.contentSize.width < initialWidth - 40
                    }
                    try await StressScrollCheck.scroll(resized, name: "Wrapped Lyrics after resize")
                }
            },
            Action("stress.now_playing.up_next") { fixture in
                let previous = Set(StressScrollCheck.scrollViews(in: fixture.host).map(ObjectIdentifier.init))
                let current = fixture.media[0]
                let upcoming = fixture.state.library.tracks.lazy.filter { $0.id != current.id }
                    .prefix(StressScrollCheck.itemCount)
                fixture.playPaused(current, in: [current] + Array(upcoming))
                let queue = fixture.state.playback
                guard let currentEntry = queue.queue.first,
                      queue.currentEntryID == currentEntry.id,
                      queue.queue.count == StressScrollCheck.itemCount + 1 else {
                    throw HomeScrollCheck.Failure("Up Next did not load 5,000 upcoming tracks")
                }
                fixture.state.togglePanel(.queue)
                guard fixture.state.showingPlayer, fixture.state.panel == .queue else {
                    throw HomeScrollCheck.Failure("Up Next did not become the active panel")
                }
                let scroll = try await StressScrollCheck.longScroll(in: fixture.host, name: "Up Next") { scroll in
                    guard !previous.contains(ObjectIdentifier(scroll)), !(scroll is TimedLyricsScrollView),
                          scroll.convert(scroll.bounds, to: fixture.host).minX >= fixture.host.bounds.width * 0.4
                    else { return false }
                    if let table = scroll.documentView as? NSTableView {
                        return table.numberOfRows >= StressScrollCheck.itemCount
                    }
                    return true
                }
                try await StressScrollCheck.scroll(scroll, name: "Up Next")
            },
            Action("stress.now_playing.up_next_move") { fixture in
                let queue = fixture.state.playback
                guard let last = queue.queue.last else { throw HomeScrollCheck.Failure("Up Next is empty") }
                queue.move(from: IndexSet(integer: queue.queue.count - 1), to: 1)
                guard queue.queue[1].id == last.id else {
                    throw HomeScrollCheck.Failure("Up Next did not reorder the last of 5,000 upcoming tracks")
                }
            },
        ]
    }

    private static func benchmarkActions() throws -> [Action] {
        let routes: [(String, LibraryRoute)] = [
            ("home", .home), ("search", .search), ("recently_added", .recentlyAdded),
            ("artists", .artists), ("albums", .albums), ("songs", .songs), ("genres", .genres),
            ("folders", .folders), ("history", .history), ("statistics", .statistics),
            ("rewind", .rewind), ("settings", .settings)
        ]
        let navigation = routes.map { name, route in Action("navigate.\(name)") { $0.state.navigate(route) } }
        let settings = PreferencesPage.allCases.map { page in
            Action("settings.\(page.rawValue)") { $0.state.settingsPage = page }
        }
        return navigation + settings + [
            Action("navigate.artist_albums") { fixture in
                guard let artist = BrowseGroup.artists(fixture.state.library.tracks).max(by: { $0.tracks.count < $1.tracks.count })
                else { throw CocoaError(.validationMissingMandatoryProperty) }
                fixture.state.navigate(artist.route)
            },
            Action("genres.artwork_hover_animation") { fixture in try await verifyGenreArtworkHover(fixture) },
            Action("songs.artwork_cache_size") { fixture in try await verifySongsArtworkCache(fixture) },
            Action("artwork.shared_thumbnail_cache") { fixture in try await verifySharedThumbnailCache(fixture) },
            Action("queue.header_and_current_track_raster") { fixture in try await verifyQueueRaster(fixture) },
            Action("navigation.back") { $0.state.back() },
            Action("navigation.forward") { $0.state.forward() },
            Action("search.query") { fixture in
                fixture.consume(fixture.groupIndex.tracksMatching("édition 1", in: fixture.state.library))
            },
            Action("sort.duration") { $0.consume(BrowseSort.duration.sorted($0.state.library.tracks)) },
            Action("sort.duration_reverse") { $0.consume(BrowseSort.duration.sorted($0.state.library.tracks, descending: true)) },
            Action("filter.metadata") { fixture in
                let tracks = fixture.state.library.tracks
                fixture.consume(tracks.filter { !$0.artist.isEmpty && !$0.album.isEmpty })
            },
            Action("queue.add") { $0.state.playback.addToQueue($0.media, next: false) },
            Action("queue.play_next") { $0.state.playback.addToQueue([$0.media[0]], next: true) },
            Action("queue.move") { $0.state.playback.move(from: IndexSet(integer: 1), to: 3) },
            Action("queue.remove") { fixture in
                if let last = fixture.state.playback.queue.last { fixture.state.playback.remove(last) }
            },
            Action("queue.lock") { $0.state.playback.queueLocked.toggle() },
            Action("playback.play") { $0.state.playback.play($0.media[0], in: $0.media) },
            Action("playback.seek") { $0.state.playback.seek(to: 0.6) },
            Action("playback.pause") { if $0.state.playback.playing { $0.state.playback.togglePlayback() } },
            Action("playback.resume") { if !$0.state.playback.playing { $0.state.playback.togglePlayback() } },
            Action("playback.next") { $0.state.playback.next() },
            Action("playback.previous") { $0.state.playback.previous() },
            Action("playback.shuffle") { $0.state.playback.shuffle.toggle() },
            Action("playback.repeat") { $0.state.playback.repeatMode = .all },
            Action("playback.volume") { $0.state.setVolume(0.35) },
            Action("player.open") { $0.state.showPlayer() },
            Action("player.audio_info_spectrum_width") { _ in try verifyAudioInfoSpectrumWidth() },
            Action("player.audio_info_spectrum_timing") { _ in try await verifyAudioInfoSpectrumTiming() },
            Action("player.audio_info_spectrum_high_sample_rate") { _ in try verifyAudioInfoSpectrumAtHighSampleRate() },
            Action("player.track_credit_visibility") { try verifyTrackCreditVisibility($0.media[0]) },
            Action("player.lyrics") { $0.state.togglePanel(.lyrics) },
            Action("lyrics.auto_follow") { fixture in
                let scroll = try fixture.lyricsScrollView()
                let before = scroll.contentView.bounds.origin.y
                fixture.state.playback.seek(to: 1.45)
                try await Task.sleep(for: .milliseconds(290))
                guard abs(scroll.contentView.bounds.origin.y - before) > 10 else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
            },
            Action("lyrics.visible_active_line") { fixture in
                try fixture.verifyVisibleLyricInk()
            },
            Action("lyrics.follow_during_playback") { fixture in
                let playback = fixture.state.playback
                let scroll = try fixture.lyricsScrollView()
                let startTime = playback.livePosition
                let startY = scroll.contentView.bounds.minY
                for _ in 0..<75 {
                    for _ in 0..<6 {
                        if try !playback.renderOffline() { break }
                    }
                    try await Task.sleep(for: .milliseconds(16))
                    if playback.livePosition >= startTime + 0.75 { break }
                }
                try await Task.sleep(for: .milliseconds(250))
                guard playback.livePosition >= startTime + 0.75,
                      abs(scroll.contentView.bounds.minY - startY) > 10 else {
                    throw HomeScrollCheck.Failure("Lyrics did not follow advancing offline playback")
                }
            },
            Action("lyrics.manual_scroll") { fixture in
                let scroll = try fixture.lyricsScrollView()
                let before = scroll.contentView.bounds.origin
                scroll.contentView.scroll(to: CGPoint(x: before.x, y: before.y + 240))
                scroll.reflectScrolledClipView(scroll.contentView)
                guard scroll.contentView.bounds.origin.y > before.y else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
            },
            Action("player.queue") { $0.state.togglePanel(.queue) },
            Action("player.close") { $0.state.closePlayer() },
            Action("lyrics.lookup") { fixture in
                let document = try await fixture.state.library.lyrics(for: fixture.media[0])
                fixture.checksum = document?.activeLine(at: 0.6)?.id ?? -1
            },
            Action("artwork.decode") { fixture in
                let image = try Data(contentsOf: fixture.artwork)
                let cover = await CoverDecoding.image(image, limit: 480)
                fixture.checksum = cover?.width ?? -1
            },
            Action("waves.frame") { try $0.renderWave() },
            Action("library.scan") { await $0.state.library.addSource($0.importFolder) },
            Action("cache.artwork_clear") { $0.state.library.clearArtworkCache() },
            Action("playback.dismiss") { $0.state.dismissPlayback() },
        ]
    }

    private final class HoverCheckWindow: NSWindow {
        var pointer = CGPoint(x: -100, y: -100)
        override var isKeyWindow: Bool { true }
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    }

    private static func verifyQueueRaster(_ fixture: Fixture) async throws {
        let tracks = fixture.media + Array(fixture.state.library.tracks.prefix(24))
        fixture.state.playback.addToQueue(tracks, next: false)
        fixture.state.togglePanel(.queue)
        defer {
            fixture.state.closePlayer()
            fixture.state.playback.dismiss()
        }
        for _ in 0..<10 {
            fixture.host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(35))
        }
        let host = fixture.host
        guard let scroll = StressScrollCheck.scrollViews(in: host).first(where: {
            $0.convert($0.bounds, to: host).minX >= host.bounds.width * 0.4
        }) else { throw HomeScrollCheck.Failure("Up Next list did not appear") }
        let rect = scroll.convert(scroll.bounds, to: host)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else {
            throw HomeScrollCheck.Failure("Up Next list raster was unavailable")
        }
        host.cacheDisplay(in: rect, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / rect.width
        func pixels(_ points: CGFloat) -> Int { Int((points * scale).rounded()) }
        func color(x: Int, y: Int) -> NSColor? { bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
        for headerEnd in [28.0, 104.0] {
            let edge = bitmap.pixelsWide - 1
            let y = pixels(headerEnd) - 1
            if let mark = color(x: edge, y: y), let interior = color(x: edge - 1, y: y),
               mark.redComponent - interior.redComponent > 0.025,
               mark.greenComponent - interior.greenComponent > 0.025 {
                throw HomeScrollCheck.Failure("Up Next header has an isolated pixel at its trailing edge")
            }
        }
        var bars = 0
        var previous = false
        for x in (bitmap.pixelsWide - pixels(64))..<(bitmap.pixelsWide - pixels(36)) {
            let filled = (pixels(39)..<pixels(63)).contains { y in
                guard let color = color(x: x, y: y) else { return false }
                return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.55
            }
            if filled && !previous { bars += 1 }
            previous = filled
        }
        guard bars == 5 else { throw HomeScrollCheck.Failure("Up Next current track has \(bars) visible visualizer bars") }
    }

    private static func verifySongsArtworkCache(_ fixture: Fixture) async throws {
        let track = fixture.media[0]
        let window = HoverCheckWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 240),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BrowseTrackTable(
            library: fixture.state.library, tracks: [track], playback: fixture.state.playback, usesSongsArtwork: true
        ))
        window.contentView = host
        for _ in 0..<25 {
            host.layoutSubtreeIfNeeded()
            if let image = BrowseArtwork.cachedThumbnail(for: track, pixelSize: 44) {
                guard max(image.width, image.height) == 44 else {
                    throw HomeScrollCheck.Failure("Songs cached larger artwork than its 22 pt cell needs at 2×")
                }
                return
            }
            if let image = BrowseArtwork.cachedThumbnail(for: track, pixelSize: 64) {
                throw HomeScrollCheck.Failure("Songs cached \(image.width)×\(image.height) instead of 44 px artwork")
            }
            try await Task.sleep(for: .milliseconds(35))
        }
        throw HomeScrollCheck.Failure("Could not load the Songs artwork fixture")
    }

    private static func verifySharedThumbnailCache(_ fixture: Fixture) async throws {
        let track = fixture.media[0]
        let library = fixture.state.library
        guard let queueImage = await BrowseArtwork.loadThumbnail(for: track, in: library, pixelSize: 88) else {
            throw HomeScrollCheck.Failure("Could not prefetch the Up Next artwork fixture")
        }
        let window = HoverCheckWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 240),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        let groups = BrowseGroup.genres([track])
        let host = NSHostingView(rootView: BrowseGroupGrid(groups: groups, library: library,
            playback: fixture.state.playback, open: { _ in }, presentation: .list
        ).dynamicTypeSize(.large).environment(\.layoutDirection, .leftToRight))
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 520, height: 240))
        host.frame = scrollView.bounds
        scrollView.documentView = host
        window.contentView = scrollView
        func usesCachedImage(_ layer: CALayer) -> Bool {
            (layer.contents as AnyObject?) === queueImage || (layer.sublayers ?? []).contains { usesCachedImage($0) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for _ in 0..<25 {
            host.layoutSubtreeIfNeeded()
            if descendants(host).compactMap({ $0 as? NativeGroupCard }).contains(where: {
                $0.layer.map(usesCachedImage) == true
            }) { return }
            if BrowseArtwork.cachedThumbnail(for: track, pixelSize: 96) != nil {
                throw HomeScrollCheck.Failure("Genres decoded a 96 px copy of the cached Up Next thumbnail")
            }
            try await Task.sleep(for: .milliseconds(35))
        }
        throw HomeScrollCheck.Failure("Genres did not display the prefetched Up Next thumbnail")
    }

    private static func verifyGenreArtworkHover(_ fixture: Fixture) async throws {
        let window = HoverCheckWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 240),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        let groups = BrowseGroup.genres(fixture.media)
        let host = NSHostingView(rootView: BrowseGroupGrid(
            groups: groups, library: fixture.state.library, playback: fixture.state.playback,
            open: { _ in }, presentation: .list
        ).dynamicTypeSize(.large).environment(\.layoutDirection, .leftToRight))
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 520, height: 240))
        host.frame = scrollView.bounds
        scrollView.documentView = host
        window.contentView = scrollView
        let capturesFrames = ProcessInfo.processInfo.environment["MUZIKA_CHECK_GENRES_FRAMES"] == "1"
        if capturesFrames {
            window.ignoresMouseEvents = true
            window.orderBack(nil)
        }
        defer { window.orderOut(nil) }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let row = descendants(host).compactMap({ $0 as? NativeGroupCard }).first(where: { !$0.isHidden }),
              let viewport = row.superview else {
            throw HomeScrollCheck.Failure("Could not lay out a native Genres row")
        }
        let center = CGPoint(x: row.frame.minX + 18, y: row.frame.midY - 0.5)
        let location = viewport.convert(center, to: nil)
        if capturesFrames {
            let titleLocation = viewport.convert(CGPoint(x: row.frame.minX + 85, y: row.frame.midY - 0.5), to: nil)
            try await verifyPresentedGenreHover(window: window, viewport: viewport, artwork: location, title: titleLocation)
            return
        }

        func move(to point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0,
                                                pressure: 0) else {
                throw HomeScrollCheck.Failure("Could not create the Genres pointer event")
            }
            window.pointer = point
            viewport.mouseMoved(with: event)
        }

        try move(to: location)
        guard let overlay = viewport.subviews.first(where: {
            $0 !== row && $0.frame == row.frame && !$0.isHidden && ($0.layer?.opacity ?? 1) > 0.99
        }) else { throw HomeScrollCheck.Failure("Genres did not show the playback overlay on the hovered artwork") }

        try move(to: CGPoint(x: -100, y: -100))
        for _ in 0..<40 {
            if overlay.isHidden || overlay.superview == nil { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HomeScrollCheck.Failure("Genres kept the playback overlay visible after pointer exit")
    }

    private static func verifyPresentedGenreHover(window: HoverCheckWindow, viewport: NSView,
                                                  artwork: NSPoint, title: NSPoint) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw HomeScrollCheck.Failure("The Genres test window was not available for capture")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let crop = CGRect(x: artwork.x.rounded() - 6,
                          y: window.frame.height - artwork.y.rounded() - 6, width: 13, height: 13)

        func move(_ point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 0, pressure: 0) else {
                throw HomeScrollCheck.Failure("Could not create the pointer movement")
            }
            window.pointer = point
            viewport.mouseMoved(with: event)
        }

        func capture() async throws -> [Double] {
            let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let region = frame.cropping(to: crop),
                  let context = CGContext(data: nil, width: region.width, height: region.height, bitsPerComponent: 8,
                                          bytesPerRow: region.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
                throw HomeScrollCheck.Failure("Could not read the artwork pixels from the presented window")
            }
            context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
            return (0..<(region.width * region.height)).map { index in
                let offset = index * 4
                return Double(Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 765
            }
        }

        func transition(to point: NSPoint) async throws -> [[Double]] {
            try move(point)
            let until = ContinuousClock.now + .milliseconds(420)
            var frames: [[Double]] = []
            repeat {
                frames.append(try await capture())
                try await Task.sleep(for: .milliseconds(8))
            } while ContinuousClock.now < until
            return frames
        }

        try await Task.sleep(for: .milliseconds(180))
        let resting = try await capture()
        let entering = try await transition(to: artwork)
        let leavingArtwork = try await transition(to: title)
        let reentering = try await transition(to: artwork)
        let leavingRow = try await transition(to: CGPoint(x: -100, y: -100))
        let shown = entering.last ?? resting
        let glyph = resting.indices.filter { shown[$0] - resting[$0] > 0.23 }
        guard glyph.count >= 6 else { throw HomeScrollCheck.Failure("Play did not appear in the captured window") }
        let scale = glyph.reduce(0) { $0 + shown[$1] - resting[$1] }
        let transitions = [("enter row at artwork", entering), ("leave artwork for title", leavingArtwork),
                           ("enter artwork from title", reentering), ("leave row", leavingRow)]
        var allAnimated = true
        for (name, frames) in transitions {
            let progress = frames.map { frame in glyph.reduce(0) { $0 + frame[$1] - resting[$1] } / scale }
            let intermediate = progress.filter { (0.14...0.86).contains($0) }.count
            print("Genres \(name): \(progress.map { Int(($0 * 100).rounded()) })")
            allAnimated = allAnimated && intermediate >= 2
        }
        guard allAnimated else { throw HomeScrollCheck.Failure("A presented Play transition skipped its intermediate frames") }
    }

    private static func verifyAudioInfoSpectrumTiming() async throws {
        let url = BenchmarkPaths.scratch.appending(path: "spectrum-\(UUID().uuidString).caf")
        let format = PCMStreamFormat.format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        let channels = buffer.floatChannelData!
        for frame in 0..<Int(buffer.frameLength) {
            let frequency: Float = (7500..<8192).contains(frame) ? 1000 : 0
            let level: Float = 0.5 * sin(2 * Float.pi * frequency * Float(frame) / 48_000)
            channels[0][frame] = level
            channels[1][frame] = -level
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }

        let playback = try PCMPlayback(mode: .offline)
        let source = PCMPlayback.Source(id: UUID(), url: url, lease: nil)
        playback.begin(source, position: 0, play: true)
        for _ in 0..<200 {
            playback.poll()
            if playback.readyForOfflineRender { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard playback.readyForOfflineRender else {
            throw HomeScrollCheck.Failure("Spectrum fixture did not start")
        }
        for _ in 0..<64 {
            _ = try playback.render(128)
            playback.poll()
        }
        playback.setAudioInfoSpectrumEnabled(true)
        let levels = playback.audioInfoSpectrum()
        guard levels.count == 16, levels[7] > 0.75,
              levels[7] == levels.max(), levels[7] - levels[15] > 0.4 else {
            throw HomeScrollCheck.Failure("Audio info did not read the scheduled tone at the playback position: \(levels)")
        }
        playback.begin(source, position: 0.4, play: true)
        guard playback.audioInfoSpectrum().allSatisfy({ $0 == 0 }) else {
            throw HomeScrollCheck.Failure("Audio info retained the previous spectrum after seeking")
        }
    }

    private static func verifyAudioInfoSpectrumAtHighSampleRate() throws {
        let sampleRate = 96_000.0
        let analyzer = AudioInfoSpectrum(sampleRate: sampleRate)
        let levels = analyzer.read { left, right in
            for index in left.indices {
                let value = 0.5 * sin(2 * Float.pi * 72 * Float(index) / Float(sampleRate))
                left[index] = value
                right[index] = -value
            }
            return .samples(frame: 96_000, sampleRate: sampleRate)
        }
        guard levels.count == 16, levels[0] > 0.75, levels[0] == levels.max() else {
            throw HomeScrollCheck.Failure("Audio info lost the bass band at 96 kHz: \(levels)")
        }
    }

    private static func verifyAudioInfoSpectrumWidth() throws {
        for scale: CGFloat in [1, 2] {
            let quiet = try spectrumBarPixels(heights: Array(repeating: 3.9255, count: 16), scale: scale)
            let varying = try spectrumBarPixels(heights: (0..<16).map { 3.9255 + 17 * CGFloat($0) / 15 }, scale: scale)
            let widths = quiet.map(\.width) + varying.map(\.width)
            let gaps = [quiet, varying].flatMap { bars in
                zip(bars, bars.dropFirst()).map { left, right in right.start - left.start - left.width }
            }
            guard quiet.count == 16, varying.count == 16, Set(widths).count == 1,
                  Set(gaps).count == 1, varying[15].height > quiet[15].height * 2 else {
                throw HomeScrollCheck.Failure("Audio info spectrum dimensions differ at \(scale)×: widths \(widths), gaps \(gaps)")
            }
        }
    }

    private static func spectrumBarPixels(heights: [CGFloat], scale: CGFloat) throws -> [(start: Int, width: Int, height: Int)] {
        let renderer = ImageRenderer(content: AudioInfoSpectrumBars(heights: heights, width: 105, peakHeight: 21)
            .foregroundStyle(.white).environment(\.displayScale, scale))
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw HomeScrollCheck.Failure("Could not render Audio info spectrum")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var bars: [(start: Int, width: Int, height: Int)] = []
        var run = (start: 0, width: 0, height: 0)
        for x in 0..<image.width {
            let height = (0..<image.height).count { bytes[$0 * context.bytesPerRow + x * 4 + 3] >= 128 }
            if height > 0 {
                if run.width == 0 { run.start = x }
                run.width += 1
                run.height = max(run.height, height)
            } else if run.width > 0 {
                bars.append(run)
                run = (0, 0, 0)
            }
        }
        if run.width > 0 { bars.append(run) }
        return bars
    }

    private static func verifyTrackCreditVisibility(_ track: AudioTrack) throws {
        func size(album: Bool, year: Bool, maxWidth: CGFloat = 450) -> CGSize {
            let renderer = ImageRenderer(content: PlayingTrackCredits(
                track: track, showsAlbum: album, showsReleaseYear: year, navigate: { _ in }
            ))
            renderer.proposedSize = ProposedViewSize(width: maxWidth, height: nil)
            var size = CGSize.zero
            renderer.render { rendered, _ in size = rendered }
            return size
        }

        let both = size(album: true, year: true)
        let album = size(album: true, year: false)
        let year = size(album: false, year: true)
        let artist = size(album: false, year: false)
        guard artist.width > 0, both.width > album.width, both.width > year.width,
              album.width > artist.width, year.width > artist.width,
              abs(both.width + artist.width - album.width - year.width) < 2 else {
            throw HomeScrollCheck.Failure("Now Playing must show the album and year independently")
        }
        let narrow = size(album: true, year: true, maxWidth: 110)
        guard narrow.width <= 110, narrow.height > both.height else {
            throw HomeScrollCheck.Failure("The visible Now Playing credits must fit a narrow layout")
        }
    }

    @MainActor
    private final class Fixture {
        let state: AppState
        let media: [AudioTrack]
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let groupIndex = LibraryGroupIndex()
        let importFolder: URL
        let artwork: URL
        let rootFolder: URL
        let largeGroupRoutes: [String: LibraryRoute]
        var checksum = 0

        init(stress: Bool) throws {
            let manager = FileManager.default
            let dir = BenchmarkPaths.scratch.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            rootFolder = dir
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
            importFolder = dir.appending(path: "import", directoryHint: .isDirectory)
            try manager.createDirectory(at: importFolder, withIntermediateDirectories: true)
            try Fixture.waveFile().write(to: importFolder.appending(path: "New.wav"))
            artwork = dir.appending(path: "Cover.png")
            try Fixture.coverImage().write(to: artwork)
            let count = StressScrollCheck.itemCount
            func trackURL(_ index: Int) -> URL {
                let ext = index < 4 ? "wav" : "flac"
                let folder = stress ? dir.appending(path: index < count ? "Collection \(index)" : "Large Collection") : dir
                return folder.appending(path: "Fixture-\(index).\(ext)")
            }
            for index in 0..<4 {
                let audio = trackURL(index)
                try manager.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Fixture.waveFile(seconds: stress && index == 0 ? 55 : 12).write(to: audio)
            }
            let timedLyrics = (0..<(stress ? count : 40)).map { index -> String in
                let timestamp = index * (stress ? 1 : 25)
                return String(format: "[00:%02d.%02d]Fixture lyric line %d", timestamp / 100, timestamp % 100, index)
            }.joined(separator: "\n")
            try timedLyrics.write(
                to: trackURL(0).deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8
            )
            if stress {
                let untimed = (0..<count).map { index in
                    let text = "Untimed fixture lyric line \(index)"
                    return PerformanceProbe.checksWrappedLyrics && index.isMultiple(of: 3)
                        ? text + String(repeating: " — Édition 🎵 عربية Русский", count: 8) : text
                }.joined(separator: "\n")
                try untimed.write(to: trackURL(1).deletingPathExtension().appendingPathExtension("lrc"),
                                  atomically: true, encoding: .utf8)
            }
            let tracks = (0..<(stress ? count * 2 : 1_590)).map { index in
                let url = trackURL(index)
                let artist = stress ? min(index, count) : index % 231
                let album = stress ? min(index, count) : index % 302
                let genre = stress ? min(index, count) : index % 15
                return AudioTrack(
                    id: url.path, url: url, title: stress ? "Stress Track \(index)" : "Track \(index) Édition",
                    artist: "Artist \(artist)", album: "Album \(album)", albumArtist: "Artist \(artist)",
                    genre: "Genre \(genre)", discNumber: 1, trackNumber: index % 17 + 1,
                    year: 2022, duration: index < 4 ? (stress && index == 0 ? 55 : 12) : Double(180 + index % 151),
                    codec: index < 4 ? "PCM" : "FLAC", bitDepth: 16, sampleRate: 48_000, bitrate: nil,
                    channels: 1, addedAt: .distantPast.addingTimeInterval(Double(index)), isTemporary: false
                )
            }
            media = Array(tracks.prefix(4))
            let contents = Snapshot(
                sources: [LibrarySource(url: dir)],
                files: tracks.map { IndexedAudioFile(track: $0, stamp: nil) }
            )
            try JSONEncoder().encode(contents).write(to: BenchmarkPaths.library, options: .atomic)
            let history = stress ? tracks.prefix(count).enumerated().map { index, track in
                ListeningEvent(trackID: track.id, timestamp: .now.addingTimeInterval(-Double(index)),
                               title: track.title, artist: track.artist, seconds: 25, started: true)
            } : []
            try JSONEncoder().encode(history).write(to: BenchmarkPaths.history, options: .atomic)
            state = AppState()
            if stress {
                guard let snapshot = LibraryBrowseSnapshot(tracks: state.library.tracks),
                      snapshot.songs.count == count * 2, state.history.events.count == count,
                      snapshot.recentAlbums.count >= count else {
                    throw HomeScrollCheck.Failure("Stress fixture did not restore the large library and history")
                }
                var routes: [String: LibraryRoute] = [:]
                for (name, groups) in [("artist", snapshot.artists), ("album", snapshot.albums), ("genre", snapshot.genres)] {
                    guard groups.count >= count, let large = groups.first(where: { $0.tracks.count == count }) else {
                        throw HomeScrollCheck.Failure("Stress fixture did not provide 5,000 \(name) groups and a 5,000-track group")
                    }
                    routes[name] = large.route
                }
                let folders = Set(state.library.tracks.map { $0.url.deletingLastPathComponent() })
                guard folders.count >= count else {
                    throw HomeScrollCheck.Failure("Stress fixture did not provide 5,000 folder entries")
                }
                largeGroupRoutes = routes
            } else {
                largeGroupRoutes = [:]
            }
            host = NSHostingView(rootView: AnyView(
                MainWindow(state: state)
                    .environment(\.scenePhase, PerformanceProbe.showsWindow ? .active : .inactive)
            ))
            let size = NSSize(width: 1250, height: 860)
            window = PerformanceWindow(contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: true)
            window.contentView = host
            window.setContentSize(size)
            host.frame.size = size
            window.title = "MUZIKA? Performance Fixture"
            window.ignoresMouseEvents = true
            if PerformanceProbe.showsWindow {
                window.alphaValue = 1
                window.level = .floating
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            } else {
                window.alphaValue = 0
            }
            window.center()
            if let screen = window.screen ?? NSScreen.main {
                window.setFrameOrigin(benchmarkWindowOrigin(window: window.frame.size, in: screen.visibleFrame))
            }
            window.orderFrontRegardless()
        }

        isolated deinit { window.orderOut(nil) }

        func waitForVisibility() async throws {
            guard PerformanceProbe.showsWindow else { return }
            for _ in 0..<20 where !window.occlusionState.contains(.visible) {
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(100))
            }
            try checkVisibility()
        }

        func checkVisibility() throws {
            if PerformanceProbe.showsWindow,
               (!window.occlusionState.contains(.visible) || window.isKeyWindow) {
                throw HomeScrollCheck.Failure(
                    "Performance window: ordered=\(window.isVisible), visible=\(window.occlusionState.contains(.visible)), key=\(window.isKeyWindow), frame=\(window.frame), screen=\(String(describing: window.screen?.visibleFrame))"
                )
            }
        }

        func consume(_ tracks: [AudioTrack]) { checksum = tracks.first?.id.hashValue ?? tracks.count }

        func scrollLargePage(_ name: String) async throws {
            let scroll = try await StressScrollCheck.longScroll(in: host, name: name)
            try await StressScrollCheck.scroll(scroll, name: name)
        }

        func validateLyrics(_ track: AudioTrack, timed: Bool) async throws {
            let lyrics = try await state.library.lyrics(for: track)
            guard lyrics?.lines.count == StressScrollCheck.itemCount, lyrics?.isTimed == timed else {
                throw HomeScrollCheck.Failure("Lyrics did not load the \(timed ? "timed" : "untimed") 5,000-line fixture")
            }
        }

        func navigateAndScroll(_ route: LibraryRoute, name: String, table: Bool) async throws {
            let previous = Set(StressScrollCheck.scrollViews(in: host).map(ObjectIdentifier.init))
            state.navigate(route)
            let scroll = try await StressScrollCheck.longScroll(in: host, name: name) { scroll in
                guard !previous.contains(ObjectIdentifier(scroll)) else { return false }
                let rows = (scroll.documentView as? NSTableView)?.numberOfRows
                return table ? rows == StressScrollCheck.itemCount : rows == nil
            }
            try await StressScrollCheck.scroll(scroll, name: name)
        }

        func playPaused(_ track: AudioTrack, in queue: [AudioTrack]) {
            state.playback.play(track, in: queue)
            if state.playback.playing { state.playback.togglePlayback() }
        }

        func lyricsScrollView() throws -> NSScrollView {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).last(where: {
                $0.convert($0.bounds, to: host).minX >= host.bounds.width * 0.4 && !($0.documentView is NSTableView)
            }) else { throw CocoaError(.validationMissingMandatoryProperty) }
            return scroll
        }

        func verifyVisibleLyricInk() throws {
            let clip = try lyricsScrollView().contentView
            guard let layer = clip.layer else { throw CocoaError(.validationMissingMandatoryProperty) }
            let width = Int(clip.bounds.width.rounded(.down))
            let height = Int(clip.bounds.height.rounded(.down))
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
            layer.render(in: context)
            for y in Int(Double(height) * 0.27)..<Int(Double(height) * 0.53) {
                let row = bytes + y * context.bytesPerRow
                if stride(from: 3, to: width * 4, by: 4).contains(where: { row[$0] >= 240 }) { return }
            }
            throw CocoaError(.validationMissingMandatoryProperty)
        }

        func renderWave() throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let buffer = queue.makeCommandBuffer() else { throw CocoaError(.featureUnsupported) }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 768, height: 432, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw CocoaError(.featureUnsupported) }
            let context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
            let extent = CGRect(x: 0, y: 0, width: 768, height: 432)
            var scene = WaveScene()
            let image = scene.frame(palette: .defaultPalette, spectrum: Array(repeating: 0.8, count: 32),
                                    delta: 1.0 / 60, extent: extent)
            context.render(image, to: texture, commandBuffer: buffer, bounds: extent, colorSpace: WaveScene.colorSpace)
            buffer.commit()
            buffer.waitUntilCompleted()
            guard buffer.status == .completed else { throw CocoaError(.fileReadUnknown) }
            PerformanceGPU.record(buffer)
        }


        private struct Snapshot: Encodable {
            let version = 1
            let sources: [LibrarySource]
            let files: [IndexedAudioFile]
        }

        private static func coverImage() throws -> Data {
            let color = CGColorSpace(name: CGColorSpace.sRGB)!
            let shades: [CGColor] = [CGColor(red: 0.8, green: 0.22, blue: 0.12, alpha: 1),
                CGColor(red: 0.12, green: 0.22, blue: 0.8, alpha: 1)]
            guard let gradient = CGGradient(colorsSpace: color, colors: shades as CFArray, locations: nil),
                  let canvas = CGContext(data: nil, width: 320, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                    space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            canvas.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 320, y: 320), options: [])
            guard let image = canvas.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            return png
        }

        private static func waveFile(seconds: UInt32 = 12) -> Data {
            let byteCount = 48_000 * seconds * 2
            var output = Data()
            func text(_ value: String) { output.append(contentsOf: value.utf8) }
            func number<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
            }
            text("RIFF")
            number(byteCount + 36)
            text("WAVEfmt ")
            number(UInt32(16))
            number(UInt16(1))
            number(UInt16(1))
            number(UInt32(48_000))
            number(UInt32(96_000))
            number(UInt16(2))
            number(UInt16(16))
            text("data")
            number(byteCount)
            output.append(Data(count: Int(byteCount)))
            return output
        }
    }
}
