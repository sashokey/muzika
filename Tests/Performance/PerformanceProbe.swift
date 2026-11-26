import AppKit
import CoreImage
import Darwin
import Foundation
import Metal
import OSLog
import QuartzCore
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
        let homeOnly = CommandLine.arguments.dropFirst(4).first == "home"
        let actions: [Action] = homeOnly ? [
            Action("home.shuffle_scroll_down") { try await HomeScrollCheck.run(host: $0.host, window: $0.window, down: true) },
            Action("home.shuffle_scroll_up") { try await HomeScrollCheck.run(host: $0.host, window: $0.window, down: false) },
        ] : try benchmarkActions()
        var results: [BenchmarkSample] = []
        for iteration in 1...repetitions {
            let fixture = try Fixture()
            try await Task.sleep(for: .milliseconds(showsWindow ? 500 : 150))
            fixture.host.layoutSubtreeIfNeeded()
            try fixture.checkVisibility()
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

    private static func verifyAudioInfoSpectrumWidth() throws {
        for scale: CGFloat in [1, 2] {
            let quiet = try spectrumBarPixels(heights: Array(repeating: 3.9255, count: 16), scale: scale)
            let varying = try spectrumBarPixels(heights: (0..<16).map { 3.9255 + 17 * CGFloat($0) / 15 }, scale: scale)
            let widths = quiet.map(\.width) + varying.map(\.width)
            guard quiet.count == 16, varying.count == 16, Set(widths).count == 1,
                  varying[15].height > quiet[15].height * 2 else {
                throw HomeScrollCheck.Failure("Audio info spectrum widths or heights differ from expectations at \(scale)×: \(widths)")
            }
        }
    }

    private static func spectrumBarPixels(heights: [CGFloat], scale: CGFloat) throws -> [(width: Int, height: Int)] {
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
        var bars: [(width: Int, height: Int)] = []
        var run = (width: 0, height: 0)
        for x in 0..<image.width {
            let height = (0..<image.height).count { bytes[$0 * context.bytesPerRow + x * 4 + 3] >= 128 }
            if height > 0 {
                run.width += 1
                run.height = max(run.height, height)
            } else if run.width > 0 {
                bars.append(run)
                run = (0, 0)
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
        var checksum = 0

        init() throws {
            let manager = FileManager.default
            let dir = BenchmarkPaths.scratch.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
            importFolder = dir.appending(path: "import", directoryHint: .isDirectory)
            try manager.createDirectory(at: importFolder, withIntermediateDirectories: true)
            try Fixture.waveFile().write(to: importFolder.appending(path: "New.wav"))
            artwork = dir.appending(path: "Cover.png")
            try Fixture.coverImage().write(to: artwork)
            for index in 0..<4 {
                try Fixture.waveFile().write(to: dir.appending(path: "Fixture-\(index).wav"))
            }
            let timedLyrics = (0..<40).map { index -> String in
                let timestamp = index * 25
                return String(format: "[00:%02d.%02d]Fixture lyric line %d", timestamp / 100, timestamp % 100, index)
            }.joined(separator: "\n")
            try timedLyrics.write(
                to: dir.appending(path: "Fixture-0.lrc"), atomically: true, encoding: .utf8
            )
            let tracks = (0..<1590).map { index in
                let ext = index < 4 ? "wav" : "flac"
                let url = dir.appending(path: "Fixture-\(index).\(ext)")
                return AudioTrack(
                    id: url.path, url: url, title: "Track \(index) Édition", artist: "Artist \(index % 231)",
                    album: "Album \(index % 302)", albumArtist: "Artist \(index % 231)",
                    genre: "Genre \(index % 15)", discNumber: 1, trackNumber: index % 17 + 1,
                    year: 2022, duration: index < 4 ? 12 : Double(180 + index % 151),
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
            try Data("[]".utf8).write(to: BenchmarkPaths.history, options: .atomic)
            state = AppState()
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
                window.collectionBehavior.insert(.canJoinAllSpaces)
            } else {
                window.alphaValue = 0
            }
            window.center()
            window.orderFrontRegardless()
        }

        isolated deinit { window.orderOut(nil) }

        func checkVisibility() throws {
            if PerformanceProbe.showsWindow,
               (!window.occlusionState.contains(.visible) || window.isKeyWindow) {
                throw HomeScrollCheck.Failure(
                    "Performance window: ordered=\(window.isVisible), visible=\(window.occlusionState.contains(.visible)), key=\(window.isKeyWindow)"
                )
            }
        }

        func consume(_ tracks: [AudioTrack]) { checksum = tracks.first?.id.hashValue ?? tracks.count }

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

        private static func waveFile() -> Data {
            let byteCount: UInt32 = 48_000 * 12 * 2
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
