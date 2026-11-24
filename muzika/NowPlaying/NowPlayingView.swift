import AppKit
import SwiftUI

struct NowPlayingView: View {
    @Bindable var state: AppState
    var openingAnimation: Animation?
    var reserveLibraryToolbar: (CGFloat?) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @State private var lyricsLoad: LyricsLoad?
    @State private var palette = WavePalette.defaultPalette
    @State private var paletteTrackID: AudioTrack.ID?
    @State private var editingTime: Double?
    @State private var windowPrepared = false
    @State private var visibleWindow = false
    @State private var fullscreenTopPadding: CGFloat?
    @State private var presentingAudioInfo = false
    private let panelControlsHeight: CGFloat = 40

    var body: some View {
        if let track = state.playback.current {
            let presentation = PlaybackPresentation(trackID: track.id, panel: state.panel)
            GeometryReader { proxy in
                if windowPrepared {
                    ZStack {
                        background(track: track)
                        playerLayout(track, size: proxy.size, windowTopInset: proxy.safeAreaInsets.top)
                    }
                    .transition(.opacity)
                }
            }
            .animation(openingAnimation, value: windowPrepared)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .onChange(of: state.playback.currentEntryID) { _, _ in editingTime = nil }
            .background {
                PlayerWindowProbe(
                    visibility: { visibleWindow = $0 }, topPadding: { fullscreenTopPadding = $0 },
                    reserveLibraryToolbar: reserveLibraryToolbar,
                    prepared: {
                        guard state.showingPlayer else { return false }
                        windowPrepared = true
                        return true
                    }
                )
            }
            .task(id: track.id) {
                var value = WavePalette.defaultPalette
                if let cover = await state.library.artwork(for: track) {
                    value = await WavePalette.fromArtwork(cover)
                }
                guard !Task.isCancelled else { return }
                palette = value
                paletteTrackID = track.id
            }
            .task(id: presentation) {
                guard presentation.panel == .lyrics else { return }
                if lyricsLoad?.trackID != track.id {
                    lyricsLoad = LyricsLoad(trackID: track.id, status: .loading)
                }
                do {
                    let document = try await state.library.lyrics(for: track)
                    if !Task.isCancelled { lyricsLoad = LyricsLoad(trackID: track.id, status: .ready(document)) }
                } catch {
                    if !Task.isCancelled { lyricsLoad = LyricsLoad(trackID: track.id, status: .failed) }
                }
            }
            .sheet(isPresented: $state.showingInfo) {
                TrackInfoView(library: state.library, track: track)
            }
        }
    }

    private var analyzing: Bool {
        state.playback.playing && visibleWindow && scenePhase != .background && !reduceMotion
    }

    private func background(track: AudioTrack) -> some View {
        let fullScreen = state.preferences.coverStyle == .fullscreen
        let softenedArtwork = state.preferences.forceBlur
        let scrim = reduceTransparency && !state.preferences.forceBlur ? 0.56 : 0.26
        return ZStack {
            Color.black
            if fullScreen || softenedArtwork {
                PlayingCover(library: state.library, track: track, maxPixels: 768)
                    .blur(radius: softenedArtwork ? 24 : 0, opaque: true)
                    .clipped()
                    .opacity(0.46)
            }
            LinearGradient(colors: [Color(palette.highlight), Color(palette.shadow)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(fullScreen || softenedArtwork ? 0.5 : 1)
                .animation(panelAnimation, value: palette)
            WaveBackground(palette: palette, isActive: analyzing && paletteTrackID == track.id, playback: state.playback)
                .opacity(fullScreen ? 0.50 : 0.86)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Color.black.opacity(state.panel == .lyrics ? max(0.48, scrim + 0.11) : scrim)
                .animation(panelAnimation, value: state.panel == .lyrics)
        }
        .ignoresSafeArea()
    }

    private var panelAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private func playerLayout(_ track: AudioTrack, size: CGSize, windowTopInset: CGFloat) -> some View {
        let horizontalInset: CGFloat = 23
        let topInset = 15 + (fullscreenTopPadding ?? 0)
        let usableWidth = max(0, size.width - horizontalInset * 2)
        let splitWidth = max(0, usableWidth - 32)
        let leftWidth = splitWidth * 5 / 11
        let hasPanel = state.panel != nil
        let artworkHeight = max(0, size.height - (fullscreenTopPadding ?? 0))
        let preferredArtworkSize = hasPanel
            ? max(126, min(size.width * 0.39 - 24, artworkHeight * 0.54, leftWidth))
            : min(max(210, artworkHeight * 0.53), max(220, size.width * 0.48))
        let artworkSize = min(preferredArtworkSize, max(126, artworkHeight - 300))

        return ZStack(alignment: .leading) {
            playerColumn(track: track, artworkSize: artworkSize)
                .frame(width: hasPanel ? leftWidth : usableWidth)
                .frame(maxHeight: .infinity)
                .padding(.top, topInset + 46)
                .padding(.bottom, 15)
            ZStack {
                if let panel = state.panel {
                    detailPanel(panel, trackID: track.id, windowTopInset: windowTopInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(panel)
                        .transition(.opacity)
                }
            }
            .frame(width: splitWidth - leftWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, horizontalInset)
        .overlay(alignment: .topLeading) {
            PlayerIcon("Close Now Playing", symbol: "xmark", action: state.closePlayer)
                .padding(5)
                .padding(.leading, horizontalInset)
                .padding(.top, topInset)
        }
        .overlay(alignment: .bottomTrailing) {
            panelControls
                .padding(.trailing, horizontalInset)
                .padding(.bottom, 15)
        }
        .animation(panelAnimation, value: state.panel)
    }

    private func playerColumn(track: AudioTrack, artworkSize: CGFloat) -> some View {
        let spacing: CGFloat = 13
        return VStack(alignment: .leading, spacing: spacing) {
            PlayingCover(library: state.library, track: track, maxPixels: 960)
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.26), radius: 22, y: 10)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Get Info") { state.showingInfo = true }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
                    Divider()
                    Button("Go to Album") { state.navigate(BrowseGroup.albumRoute(track.albumKey)) }
                        .disabled(track.isTemporary)
                    Button("Go to Artist") {
                        let artist = BrowseGroup.artistCredits(track).first ?? ""
                        state.navigate(.artist(AudioTrack.artistKey(artist)))
                    }
                    .disabled(track.isTemporary)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: PlayerIcon.size.width, height: PlayerIcon.size.height)
                .liquidGlassHover(in: Circle())
                .help("More")
                .accessibilityLabel("More")
            }
            Scrubber(playback: state.playback, duration: track.duration, editingTime: $editingTime)
            fullTimeAndFormat(track)
            TransportControls(playback: state.playback, compact: false)
                .padding(.top, 4)
        }
        .padding(.bottom, panelControlsHeight + spacing)
        .frame(width: artworkSize)
        .frame(maxWidth: .infinity)
    }

    private func fullTimeAndFormat(_ track: AudioTrack) -> some View {
        let position = editingTime ?? state.playback.position
        return HStack {
            Text(elapsedLabel(position)).monospacedDigit()
            Spacer(minLength: 2)
            Button {
                presentingAudioInfo.toggle()
            } label: {
                Label(track.quality, systemImage: "waveform").lineLimit(1)
            }
            .buttonStyle(.plain)
            .liquidGlassHover(in: Capsule(), outset: CGSize(width: 6, height: 3))
            .help("Audio info")
            .accessibilityLabel("Audio info, \(track.quality)")
            .popover(isPresented: $presentingAudioInfo) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Audio info").font(.headline)
                    Text(track.quality)
                    if let bitrate = track.bitrate, track.bitDepth != nil { Text("\(bitrate / 1_000) kbps") }
                    if let channels = track.channels { Text("\(channels) channels") }
                    Button("Get Info") {
                        presentingAudioInfo = false
                        state.showingInfo = true
                    }
                    .liquidGlassHover()
                }
                .padding(15)
                .frame(minWidth: 180)
            }
            Spacer(minLength: 2)
            Text("-" + elapsedLabel(max(0, track.duration - position))).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func detailPanel(_ panel: PlayerPanel, trackID: AudioTrack.ID, windowTopInset: CGFloat) -> some View {
        switch panel {
        case .lyrics:
            let clearance: CGFloat = windowTopInset > 0 ? 1 : 0
            lyricsPane(trackID: trackID, topOverflow: windowTopInset + clearance)
                .padding(.top, clearance)
                .ignoresSafeArea(.container, edges: .bottom)
        case .queue:
            QueuePanel(playback: state.playback, library: state.library)
                .padding(.top, 15 + (fullscreenTopPadding ?? 0))
                .padding(.bottom, 15 + panelControlsHeight + 8)
        }
    }

    private func lyricsPane(trackID: AudioTrack.ID, topOverflow: CGFloat) -> some View {
        let status = lyricsLoad?.trackID == trackID ? lyricsLoad?.status ?? .loading : .loading
        return ZStack {
            switch status {
            case .loading:
                ProgressView("Loading lyrics…").transition(.opacity)
            case .ready(let document):
                if let document {
                    LyricsPanel(
                        document: document, position: { state.playback.livePosition }, playing: state.playback.playing,
                        offset: state.preferences.lyricsOffset, textSize: state.preferences.lyricsSize,
                        blur: state.preferences.lyricsBlur && (!reduceTransparency || state.preferences.forceBlur),
                        seek: state.playback.seek(to:), topOverflow: topOverflow
                    )
                    .id(trackID)
                    .transition(.opacity)
                } else {
                    ContentUnavailableView("No Lyrics", systemImage: "quote.bubble", description: Text("No local lyrics were found for this song."))
                        .transition(.opacity)
                }
            case .failed:
                ContentUnavailableView("Lyrics Unavailable", systemImage: "quote.bubble", description: Text("The local lyrics could not be read."))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(panelAnimation, value: status)
    }

    private var panelControls: some View {
        HStack(spacing: 6) {
            PlayerVolumeButton(state: state, acceptsWheel: { state.showingPlayer })
            PlayerIcon("Lyrics", symbol: "quote.bubble", highlighted: state.panel == .lyrics) { state.togglePanel(.lyrics) }
            PlayerIcon("Up Next", symbol: "list.bullet", highlighted: state.panel == .queue) { state.togglePanel(.queue) }
        }
        .padding(6)
        .frame(height: panelControlsHeight)
        .glassEffect(.regular, in: .capsule)
    }

    private enum LyricsStatus: Equatable {
        case loading, ready(LyricsDocument?), failed
    }

    private struct LyricsLoad {
        let trackID: AudioTrack.ID
        let status: LyricsStatus
    }

    private struct PlaybackPresentation: Hashable {
        let trackID: String
        let panel: PlayerPanel?
    }
}

private struct QueuePanel: View {
    @Bindable var playback: PlaybackController
    let library: LibraryStore
    @ScaledMetric(relativeTo: .caption) private var headerHeight = 28.0

    var body: some View {
        let upcoming = visibleQueue
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Up Next")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                PlayerIcon("Lock Queue", symbol: playback.queueLocked ? "lock.fill" : "lock.open", highlighted: playback.queueLocked) {
                    playback.queueLocked.toggle()
                }
            }
            ScrollViewReader { proxy in
                List {
                    if let current = playback.current {
                        Section {
                            queueLabel(current, symbol: playback.playing ? "speaker.wave.2.fill" : "pause.fill")
                                .id(playback.currentEntryID)
                        } header: {
                            sectionHeader("Now Playing")
                        }
                    }
                    Section {
                        ForEach(upcoming) { entry in
                            Button {
                                playback.select(entry)
                            } label: {
                                queueLabel(entry.track)
                            }
                            .buttonStyle(.plain)
                            .liquidGlassHover()
                            .contextMenu {
                                Button("Play") { playback.select(entry) }
                                Button("Move up") { move(entry, delta: -1) }
                                    .disabled(playback.queueLocked || entry.id == upcoming.first?.id)
                                Button("Move down") { move(entry, delta: 1) }
                                    .disabled(playback.queueLocked || entry.id == upcoming.last?.id)
                                Button("Remove from Queue", role: .destructive) { playback.remove(entry) }
                                    .disabled(playback.queueLocked)
                            }
                        }
                        .onMove { offsets, destination in
                            guard !playback.queueLocked else { return }
                            let global = IndexSet(offsets.compactMap {
                                guard visibleQueue.indices.contains($0) else { return nil }
                                return playback.queue.firstIndex(of: visibleQueue[$0])
                            })
                            let target = visibleQueue.indices.contains(destination)
                                ? playback.queue.firstIndex(of: visibleQueue[destination]) ?? playback.queue.count
                                : playback.queue.count
                            playback.move(from: global, to: target)
                        }
                        .onDelete { offsets in
                            guard !playback.queueLocked else { return }
                            let rows = visibleQueue
                            offsets.filter { rows.indices.contains($0) }.forEach { playback.remove(rows[$0]) }
                        }
                        if upcoming.isEmpty {
                            Text("No upcoming tracks").foregroundStyle(.secondary)
                        }
                    } header: {
                        sectionHeader("Queue")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListHeaderHeight, headerHeight)
                .compositingGroup()
                .mask {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Rectangle().frame(height: headerHeight)
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .clear, location: 0.45),
                                    .init(color: .black, location: 1)
                                ], startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: 12)
                            Rectangle()
                        }
                        Rectangle().frame(width: NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle))
                    }
                }
            }
        }
        .padding(16)
        .background(.black.opacity(0.23), in: .rect(cornerRadius: 16))
    }

    private var visibleQueue: [QueueEntry] {
        guard let index = playback.queue.firstIndex(where: { $0.id == playback.currentEntryID }) else { return playback.queue }
        return Array(playback.queue.dropFirst(index + 1))
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                Rectangle()
                    .fill(.black)
                    .padding(.vertical, -4)
                    .padding(.horizontal, -8)
                    .blendMode(.destinationOut)
            }
    }

    private func queueLabel(_ track: AudioTrack, symbol: String? = nil) -> some View {
        HStack(spacing: 10) {
            PlayingCover(library: library, track: track, maxPixels: 88)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let symbol { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
            Text(elapsedLabel(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private func canMove(_ entry: QueueEntry, delta: Int) -> Bool {
        guard let index = visibleQueue.firstIndex(of: entry) else { return false }
        return visibleQueue.indices.contains(index + delta)
    }

    private func move(_ entry: QueueEntry, delta: Int) {
        guard canMove(entry, delta: delta), let index = playback.queue.firstIndex(of: entry) else { return }
        playback.move(from: IndexSet(integer: index), to: index + (delta > 0 ? 2 : -1))
    }
}

enum PlayerFullscreenChrome {
    static func padding(menuBar: CGFloat, screenInset: CGFloat, titleBar: CGFloat, alreadyReserved: CGFloat) -> CGFloat {
        max(0, max(menuBar, screenInset) + titleBar - max(0, alreadyReserved))
    }
}

@MainActor
final class PlayerWindowToolbar {
    private struct ToolbarState {
        weak var toolbar: NSToolbar?
        let wasVisible: Bool
        let autosaved: Bool
        let topInset: CGFloat
    }

    private weak var window: NSWindow?
    private var wasTransparent: Bool?
    private var toolbarState: ToolbarState?

    func hide(in window: NSWindow?) -> CGFloat? {
        guard let window else {
            restore()
            return nil
        }
        if self.window !== window {
            restore()
            self.window = window
        }
        if window.styleMask.contains(.fullSizeContentView) {
            if wasTransparent == nil { wasTransparent = window.titlebarAppearsTransparent }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        }

        let toolbar = window.toolbar
        if toolbarState?.toolbar !== toolbar {
            restoreToolbar()
            if let toolbar {
                toolbarState = ToolbarState(
                    toolbar: toolbar, wasVisible: toolbar.isVisible, autosaved: toolbar.autosavesConfiguration,
                    topInset: window.frame.height - window.contentLayoutRect.maxY
                )
            }
        }
        if let toolbar, toolbar.isVisible {
            toolbar.autosavesConfiguration = false
            toolbar.isVisible = false
        }
        return toolbarState.flatMap { $0.wasVisible ? $0.topInset : nil }
    }

    func restore() {
        restoreToolbar()
        if let window, let wasTransparent, window.titlebarAppearsTransparent != wasTransparent {
            window.titlebarAppearsTransparent = wasTransparent
        }
        wasTransparent = nil
        window = nil
    }

    private func restoreToolbar() {
        defer { toolbarState = nil }
        guard let state = toolbarState, let toolbar = state.toolbar else { return }
        if toolbar.isVisible != state.wasVisible {
            toolbar.autosavesConfiguration = false
            toolbar.isVisible = state.wasVisible
        }
        if toolbar.autosavesConfiguration != state.autosaved {
            toolbar.autosavesConfiguration = state.autosaved
        }
    }
}

private struct PlayerWindowProbe: NSViewRepresentable {
    var visibility: (Bool) -> Void
    var topPadding: (CGFloat?) -> Void
    var reserveLibraryToolbar: (CGFloat?) -> Void
    var prepared: () -> Bool

    func makeNSView(context: Context) -> PlayerWindowProbeView { PlayerWindowProbeView() }

    func updateNSView(_ view: PlayerWindowProbeView, context: Context) {
        view.visibility = visibility
        view.topPadding = topPadding
        view.reserveLibraryToolbar = reserveLibraryToolbar
        view.prepared = prepared
        view.updateChrome()
    }

    static func dismantleNSView(_ view: PlayerWindowProbeView, coordinator: ()) {
        view.detach()
    }
}

private final class PlayerWindowProbeView: NSView {
    private static let titleBarHeight = NSWindow.frameRect(
        forContentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable]
    ).height

    var visibility: ((Bool) -> Void)?
    var topPadding: ((CGFloat?) -> Void)?
    var reserveLibraryToolbar: ((CGFloat?) -> Void)?
    var prepared: (() -> Bool)?
    private var lastTopPadding: CGFloat?
    private var lastLibraryToolbarInset: CGFloat?
    private var layoutObservation: NSKeyValueObservation?
    private var updatingChrome = false
    private var didPrepareWindow = false
    private let toolbar = PlayerWindowToolbar()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        layoutObservation = nil
        guard let window else {
            toolbar.restore()
            return
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateVisibility),
            name: NSWindow.didChangeOcclusionStateNotification, object: window
        )
        DispatchQueue.main.async { [weak self] in self?.updateVisibility() }

        let changes = [
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification
        ]
        for name in changes {
            NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged(_:)), name: name, object: window)
        }
        layoutObservation = window.observe(\.contentLayoutRect) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateChrome() }
        }
        updateChrome()
    }

    override func layout() {
        super.layout()
        updateChrome()
    }

    func detach() {
        let releaseReservation = reserveLibraryToolbar
        visibility = nil
        topPadding = nil
        reserveLibraryToolbar = nil
        prepared = nil
        layoutObservation = nil
        NotificationCenter.default.removeObserver(self)
        toolbar.restore()
        DispatchQueue.main.async { releaseReservation?(nil) }
    }

    @objc private func updateVisibility() {
        visibility?(window?.occlusionState.contains(.visible) == true)
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        updateChrome()
    }

    func updateChrome() {
        guard !updatingChrome else { return }
        updatingChrome = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatingChrome = false
            guard let topPadding = self.topPadding else { return }
            let toolbarInset = self.toolbar.hide(in: self.window)
            if self.lastLibraryToolbarInset != toolbarInset {
                self.lastLibraryToolbarInset = toolbarInset
                self.reserveLibraryToolbar?(toolbarInset)
            }
            let padding = self.fullscreenPadding
            if self.lastTopPadding != padding {
                self.lastTopPadding = padding
                topPadding(padding)
            }
            guard !self.didPrepareWindow, let window = self.window, !self.bounds.isEmpty else { return }
            let viewTop = self.convert(self.bounds, to: nil).maxY
            guard toolbarInset == nil || abs(viewTop - window.contentLayoutRect.maxY) <= 1 else { return }
            self.didPrepareWindow = self.prepared?() == true
        }
    }

    private var fullscreenPadding: CGFloat? {
        guard let window, window.styleMask.contains(.fullScreen), let screen = window.screen else { return nil }
        let content = bounds.isEmpty ? window.contentLayoutRect : convert(bounds, to: nil)
        let top = window.convertToScreen(content).maxY
        return PlayerFullscreenChrome.padding(
            menuBar: max(NSApp.mainMenu?.menuBarHeight ?? 0, NSStatusBar.system.thickness),
            screenInset: screen.safeAreaInsets.top,
            titleBar: Self.titleBarHeight,
            alreadyReserved: screen.frame.maxY - top
        )
    }
}
