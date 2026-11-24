import AppKit
import QuartzCore
import SwiftUI

@MainActor
struct PlayTracksMenu: View {
    let tracks: [AudioTrack]
    let playback: PlaybackController

    var body: some View {
        Button("Play", systemImage: "play") { playback.play(tracks, shuffled: false) }
        if tracks.count > 1 {
            Button("Shuffle", systemImage: "shuffle") { playback.play(tracks, shuffled: true) }
        }
        Button("Play Next", systemImage: "text.insert") { playback.addToQueue(tracks, next: true) }
        Button("Add to Queue", systemImage: "text.append") { playback.addToQueue(tracks, next: false) }
        if tracks.count == 1, let track = tracks.first {
            Divider()
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([track.url])
            }
        }
    }
}

@MainActor
struct TrackBrowserPage: View {
    let title: String
    let subtitle: String?
    let artwork: AudioTrack?
    let tracks: [AudioTrack]
    let library: LibraryStore
    let playback: PlaybackController
    let back: (() -> Void)?
    let relatedAlbums: [BrowseGroup]
    let presorted: BrowseSort?
    let glassHeader: Bool
    let highlightsCellsOnHover: Bool
    let allowsRowsBehindHeader: Bool
    let usesSongsArtwork: Bool
    let navigate: ((LibraryRoute) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var sort: TrackSortOrder
    @State private var filters = OfflineTrackFilters()
    @AppStorage("library.artistShowsSongs") private var showsSongs = false

    init(
        title: String,
        subtitle: String? = nil,
        artwork: AudioTrack? = nil,
        tracks: [AudioTrack],
        library: LibraryStore,
        playback: PlaybackController,
        order: BrowseSort = .title,
        back: (() -> Void)? = nil,
        relatedAlbums: [BrowseGroup] = [],
        presorted: BrowseSort? = nil,
        glassHeader: Bool = true,
        highlightsCellsOnHover: Bool = true,
        allowsRowsBehindHeader: Bool = false,
        usesSongsArtwork: Bool = false,
        navigate: ((LibraryRoute) -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.tracks = tracks
        self.library = library
        self.playback = playback
        self.back = back
        self.relatedAlbums = relatedAlbums
        self.presorted = presorted
        self.glassHeader = glassHeader
        self.highlightsCellsOnHover = highlightsCellsOnHover
        self.allowsRowsBehindHeader = allowsRowsBehindHeader
        self.usesSongsArtwork = usesSongsArtwork
        self.navigate = navigate
        self._sort = State(initialValue: TrackSortOrder(key: order))
    }

    var body: some View {
        let onlyAlbums = !relatedAlbums.isEmpty && !showsSongs
        let selectedTracks = onlyAlbums && navigate != nil ? [] : sortedMatchingTracks
        let results = ZStack {
            if onlyAlbums, let navigate {
                relatedAlbumResults(navigate: navigate).transition(.opacity)
            } else {
                trackResults(selectedTracks).transition(.opacity)
            }
        }
        Group {
            if glassHeader {
                results.browseGlassHeader(spacing: selectedTracks.isEmpty ? 0 : BrowseLayout.headerSpacing) {
                    header(onlyAlbums: onlyAlbums, selectedTracks: selectedTracks)
                }
            } else {
                VStack(spacing: 0) {
                    header(onlyAlbums: onlyAlbums, selectedTracks: selectedTracks)
                    results
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: onlyAlbums)
        .windowLibraryFilter(text: $query, prompt: onlyAlbums ? "Filter Albums" : "Filter Songs")
    }

    private var sortedMatchingTracks: [AudioTrack] {
        let terms = AudioTrack.artistKey(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = terms.isEmpty && filters == .init() ? tracks : tracks.filter {
            $0.matches(tokens: terms) && filters.matches($0)
        }
        return !sort.descending && sort.key == presorted ? matches : sort.sorted(matches)
    }

    private func header(onlyAlbums: Bool, selectedTracks: [AudioTrack]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BrowseHeading(title: title, subtitle: subtitle ?? trackCount(tracks.count), back: back) {
                if !onlyAlbums {
                    BrowseTrackSortMenu(sort: $sort.key, descending: $sort.descending)
                    BrowseTrackFiltersMenu(filters: $filters, tracks: tracks)
                }
            }
            if !relatedAlbums.isEmpty {
                Picker("Artist View", selection: $showsSongs) {
                    Text("Albums").tag(false)
                    Text("Songs").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let artwork {
                HStack(alignment: .bottom, spacing: 14) {
                    BrowseArtwork(library: library, track: artwork)
                        .frame(width: 104, height: 104)
                    Text(trackCount(tracks.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, onlyAlbums ? 12 : 0)
            }
            if !onlyAlbums, !selectedTracks.isEmpty {
                BrowsePlaybackButtons(tracks: selectedTracks, playback: playback)
                    .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 26)
    }

    @ViewBuilder
    private func relatedAlbumResults(navigate: @escaping (LibraryRoute) -> Void) -> some View {
        let terms = BrowseSearch.terms(query)
        let albums = relatedAlbums.filter { BrowseSearch.matches(terms, fields: [$0.title, $0.subtitle]) }
        if albums.isEmpty {
            BrowseEmpty(title: "No Matching Albums", symbol: "square.stack")
        } else {
            ScrollView {
                BrowseGroupGrid(groups: albums, library: library, playback: playback, open: navigate)
                    .padding(.top, BrowseLayout.headerSpacing)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 22)
            }
            .browseScrollUnderHeader()
        }
    }

    @ViewBuilder
    private func trackResults(_ selectedTracks: [AudioTrack]) -> some View {
        if selectedTracks.isEmpty {
            BrowseEmpty(
                title: tracks.isEmpty ? "No Songs" : "No Matching Songs",
                symbol: tracks.isEmpty ? "music.note" : "magnifyingglass"
            )
        } else {
            BrowseTrackTable(
                library: library, tracks: selectedTracks, playback: playback, sorting: $sort,
                highlightsCellsOnHover: highlightsCellsOnHover, usesSongsArtwork: usesSongsArtwork, navigate: navigate
            )
            .background {
                if glassHeader && allowsRowsBehindHeader {
                    TrackTableScrollEdge()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

private struct TrackTableScrollEdge: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.controlSize) private var controlSize

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.enabled = !reduceTransparency
        view.useUniformRows = dynamicTypeSize == .large && controlSize == .regular
        view.updateMasks()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.restoreMasks()
    }

    final class Anchor: NSView {
        var enabled = true
        var useUniformRows = true
        private weak var scroll: NSScrollView?
        private var masks: [ObjectIdentifier: EdgeMask] = [:]
        private weak var sizedTable: NSTableView?
        private var originalRowHeight: CGFloat?
        private var uniformRowHeight: CGFloat?
        private var rowSizingPending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                restoreMasks()
                forgetRowSizing()
            }
            else { Task { @MainActor [weak self] in self?.updateMasks() } }
        }

        override func layout() {
            super.layout()
            updateMasks()
        }

        func updateMasks() {
            guard let window, !bounds.isEmpty else {
                restoreMasks()
                forgetRowSizing()
                return
            }
            if scroll?.window !== window {
                restoreMasks()
                forgetRowSizing()
                let region = convert(bounds, to: nil)
                var ancestor = superview
                while let view = ancestor, scroll == nil {
                    scroll = findTableScroll(in: view, region: region)
                    ancestor = view.superview
                }
            }
            guard let scroll, let table = scroll.documentView as? NSTableView else { return }
            updateRowSizing(for: table)
            guard enabled, let header = table.headerView, header.window === window else {
                for mask in masks.values { mask.restore() }
                masks.removeAll()
                return
            }
            let frame = scroll.convert(scroll.bounds, to: nil)
            let top = header.convert(header.bounds, to: nil).maxY + BrowseLayout.headerSpacing
            let band = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: top - frame.minY)
            guard !band.isEmpty, band.maxY < frame.maxY else {
                restoreMasks()
                return
            }
            var active: Set<ObjectIdentifier> = []
            for view in scroll.subviews {
                let name = String(describing: type(of: view))
                guard name == "BackdropView" || name == "NSScrollPocket",
                      abs(view.convert(view.bounds, to: nil).maxY - frame.maxY) < 1,
                      let layer = view.layer else { continue }
                let rect = view.convert(band, from: nil).intersection(view.bounds)
                guard !rect.isEmpty else { continue }
                let id = ObjectIdentifier(layer)
                active.insert(id)
                let mask = masks[id] ?? EdgeMask(layer: layer)
                mask.update(rect)
                masks[id] = mask
            }
            for id in Array(masks.keys) where !active.contains(id) {
                masks.removeValue(forKey: id)?.restore()
            }
        }

        func restoreMasks() {
            for mask in masks.values { mask.restore() }
            masks.removeAll()
            scroll = nil
        }

        private func updateRowSizing(for table: NSTableView) {
            if sizedTable !== table { forgetRowSizing() }
            if useUniformRows {
                if let uniformRowHeight, !table.usesAutomaticRowHeights, table.rowHeight == uniformRowHeight { return }
                guard table.usesAutomaticRowHeights || sizedTable === table else { return }
            } else if sizedTable !== table {
                return
            }
            guard !rowSizingPending else { return }
            rowSizingPending = true
            Task { @MainActor [weak self, weak table] in
                guard let self else { return }
                self.rowSizingPending = false
                guard let table, self.window != nil, self.scroll?.documentView === table else { return }
                if self.useUniformRows { self.fixRowHeight(in: table) }
                else { self.restoreRowSizing() }
            }
        }

        private func fixRowHeight(in table: NSTableView) {
            let height: CGFloat
            if sizedTable === table, let uniformRowHeight {
                height = uniformRowHeight
            } else {
                var lower = CGFloat.infinity
                var upper = CGFloat.zero
                var count = 0
                table.enumerateAvailableRowViews { row, _ in
                    let height = row.frame.height
                    guard height > 0 else { return }
                    lower = min(lower, height)
                    upper = max(upper, height)
                    count += 1
                }
                guard count >= 2, upper - lower < 0.5, lower > table.intercellSpacing.height else { return }
                height = lower - table.intercellSpacing.height
                originalRowHeight = table.rowHeight
                uniformRowHeight = height
                sizedTable = table
            }
            if table.rowHeight != height { table.rowHeight = height }
            if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
        }

        private func restoreRowSizing() {
            if let table = sizedTable, let originalRowHeight, table.rowHeight == uniformRowHeight {
                table.rowHeight = originalRowHeight
                table.usesAutomaticRowHeights = true
            }
            forgetRowSizing()
        }

        private func forgetRowSizing() {
            sizedTable = nil
            originalRowHeight = nil
            uniformRowHeight = nil
        }

        private func findTableScroll(in view: NSView, region: CGRect) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTableView {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if abs(frame.minX - region.minX) < 1, abs(frame.width - region.width) < 1,
                   frame.minY - 1 <= region.minY, frame.maxY + 1 >= region.maxY {
                    return scroll
                }
            }
            for child in view.subviews {
                if let scroll = findTableScroll(in: child, region: region) { return scroll }
            }
            return nil
        }
    }

    @MainActor
    private final class EdgeMask {
        private weak var layer: CALayer?
        private var original: CALayer?
        private let mask = CAShapeLayer()
        private var rect: CGRect = .null

        init(layer: CALayer) {
            self.layer = layer
            mask.fillColor = NSColor.black.cgColor
        }

        func update(_ rect: CGRect) {
            guard let layer else { return }
            guard self.rect != rect || mask.frame != layer.bounds || layer.mask !== mask else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.rect = rect
            mask.frame = layer.bounds
            mask.path = CGPath(rect: rect, transform: nil)
            if layer.mask !== mask {
                original = layer.mask
                layer.mask = mask
            }
            CATransaction.commit()
        }

        func restore() {
            guard let layer, layer.mask === mask else { return }
            layer.mask = original
        }
    }
}

private struct BrowseTrackSortMenu: View {
    @Binding var sort: BrowseSort
    @Binding var descending: Bool

    var body: some View {
        Menu("Sort", systemImage: "arrow.up.arrow.down") {
            Picker("Sort By", selection: $sort) {
                ForEach(BrowseSort.allCases) { order in
                    Text(order.displayTitle).tag(order)
                }
            }
            Divider()
            Toggle("Reverse Order", isOn: $descending)
        }
        .glassHoverMenu()
    }
}

private struct BrowseTrackFiltersMenu: View {
    @Binding var filters: OfflineTrackFilters
    let tracks: [AudioTrack]

    var body: some View {
        let formats = Set(tracks.map { $0.url.pathExtension.lowercased() })
            .union(filters.format.map { [$0] } ?? []).filter { !$0.isEmpty }.sorted()
        Menu("Filters", systemImage: filters == .init() ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") {
            Picker("Quality", selection: $filters.quality) {
                ForEach(OfflineTrackFilters.Quality.allCases, id: \.self) { item in
                    Text(item.displayTitle).tag(item)
                }
            }
            Picker("Format", selection: $filters.format) {
                Text("All").tag(String?.none)
                ForEach(formats, id: \.self) { format in
                    Text(format.uppercased()).tag(Optional(format))
                }
            }
            Picker("Metadata", selection: $filters.metadata) {
                ForEach(OfflineTrackFilters.Metadata.allCases, id: \.self) { item in
                    Text(item.displayTitle).tag(item)
                }
            }
            Divider()
            Button("Reset") { filters = .init() }
                .disabled(filters == .init())
        }
        .glassHoverMenu()
    }
}

@MainActor
struct BrowsePlaybackButtons: View {
    let tracks: [AudioTrack]
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Button("Play", systemImage: "play.fill") { playback.play(tracks, shuffled: false) }
                .buttonStyle(GlassHoverButtonStyle(prominent: true))
            Button("Shuffle", systemImage: "shuffle") { playback.play(tracks, shuffled: true) }
                .buttonStyle(GlassHoverButtonStyle())
        }
        .disabled(tracks.isEmpty)
    }
}

@MainActor
struct BrowseTrackTable: View {
    let library: LibraryStore
    let tracks: [AudioTrack]
    let playback: PlaybackController
    var sorting: Binding<TrackSortOrder>? = nil
    var highlightsCellsOnHover = true
    var usesSongsArtwork = false
    var navigate: ((LibraryRoute) -> Void)? = nil
    var beforePlay: (AudioTrack) -> Void = { _ in }

    @Environment(Preferences.self) private var preferences: Preferences?
    @State private var selection: Set<String> = []
    @State private var details: AudioTrack?
    @State private var ownSorting: TrackSortOrder?

    var body: some View {
        let rows = sorting == nil ? ownSorting?.sorted(tracks) ?? tracks : tracks
        Table(rows, selection: $selection, sortOrder: headerSorting) {
            TableColumn(BrowseSort.title.displayTitle, sortUsing: TrackSortOrder(key: .title)) { track in
                trackCell(HStack(spacing: 7) {
                    BrowseArtwork(
                        library: library, track: track, pixelSize: 64,
                        cornerRadius: usesSongsArtwork ? 2 : BrowseArtwork.defaultCornerRadius
                    )
                        .frame(width: 22, height: 22)
                        .overlay {
                            if playback.current?.id == track.id {
                                ArtworkSpectrumBadge(
                                    playback: playback, diameter: usesSongsArtwork ? 22 : 19,
                                    style: usesSongsArtwork ? .songs : .circle
                                )
                            }
                        }
                    Text(track.title).lineLimit(1)
                })
            }
            .width(min: 105, ideal: 164)

            TableColumn(BrowseSort.artist.displayTitle, sortUsing: TrackSortOrder(key: .artist)) { track in
                trackCell(Text(artistDisplayName(track.artist)).lineLimit(1))
            }
            .width(min: 67, ideal: 107)

            TableColumn(BrowseSort.album.displayTitle, sortUsing: TrackSortOrder(key: .album)) { track in
                trackCell(Text(albumDisplayName(track.album)).lineLimit(1))
            }
            .width(min: 67, ideal: 112)

            TableColumn(BrowseSort.quality.displayTitle, sortUsing: TrackSortOrder(key: .quality)) { track in
                trackCell(Text((preferences?.audioQuality ?? .fileFormat).value(for: track)).lineLimit(1))
            }
            .width(min: 53, ideal: 78)

            TableColumn(BrowseSort.duration.displayTitle, sortUsing: TrackSortOrder(key: .duration)) { track in
                trackCell(Text(timeLabel(track.duration)).monospacedDigit())
            }
            .width(min: 62, ideal: 69, max: 86)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                PlayTracksMenu(tracks: rows.filter { ids.contains($0.id) }, playback: playback)
                if ids.count == 1, let track = rows.first(where: { ids.contains($0.id) }) {
                    Button("Get Info", systemImage: "info.circle") { showDetails(track) }
                    if let navigate, let name = BrowseGroup.artistCredits(track).first, !name.isEmpty {
                        Button("Go to Artist", systemImage: "music.mic") {
                            navigate(.artist(AudioTrack.artistKey(name)))
                        }
                    }
                    if let navigate, !track.album.isEmpty {
                        Button("Go to Album", systemImage: "square.stack") {
                            navigate(BrowseGroup.albumRoute(track.albumKey))
                        }
                    }
                }
            }
        } primaryAction: { ids in
            playSelection(ids, in: rows)
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            playSelection(selection, in: rows)
            return .handled
        }
        .onChange(of: selection.isEmpty ? [] : rows.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .sheet(item: $details) { TrackInfoView(library: library, track: $0) }
    }

    @ViewBuilder
    private func trackCell<Content: View>(_ content: Content) -> some View {
        let cell = content.frame(maxWidth: .infinity, alignment: .leading)
        if highlightsCellsOnHover {
            cell.liquidGlassHover()
        } else {
            cell
        }
    }

    private var headerSorting: Binding<[TrackSortOrder]> {
        Binding {
            (sorting?.wrappedValue ?? ownSorting).map { [$0] } ?? []
        } set: { descriptors in
            guard let first = descriptors.first else { return }
            if let sorting { sorting.wrappedValue = first }
            else { ownSorting = first }
        }
    }

    private func playSelection(_ selection: Set<String>, in tracks: [AudioTrack]) {
        let selected = tracks.filter { selection.contains($0.id) }
        if selected.count == 1, let track = selected.first {
            if preferences?.songTap == .details {
                showDetails(track)
            } else {
                beforePlay(track)
                playback.play(track, in: tracks)
            }
        } else if let first = selected.first {
            beforePlay(first)
            playback.play(selected, shuffled: false)
        }
    }

    private func showDetails(_ track: AudioTrack) {
        beforePlay(track)
        details = track
    }
}

nonisolated struct TrackSortOrder: SortComparator {
    var key: BrowseSort
    var order: SortOrder = .forward

    var descending: Bool {
        get { order == .reverse }
        set { order = newValue ? .reverse : .forward }
    }

    func compare(_ lhs: AudioTrack, _ rhs: AudioTrack) -> ComparisonResult {
        descending ? key.compare(rhs, lhs) : key.compare(lhs, rhs)
    }

    func sorted(_ tracks: [AudioTrack]) -> [AudioTrack] {
        key.sorted(tracks, descending: descending)
    }
}

@MainActor
struct BrowseTrackRows: View {
    let library: LibraryStore
    let tracks: [AudioTrack]
    let playback: PlaybackController
    var limit: Int? = nil
    var showsPlaybackEffects = false
    var beforePlay: (AudioTrack) -> Void = { _ in }

    @Environment(Preferences.self) private var preferences: Preferences?
    @State private var details: AudioTrack?

    var body: some View {
        ForEach(tracks.prefix(limit ?? tracks.count)) { track in
            Button {
                beforePlay(track)
                if preferences?.songTap == .details {
                    details = track
                } else {
                    playback.play(track, in: tracks)
                }
            } label: {
                BrowseTrackRow(library: library, track: track)
            }
            .buttonStyle(.plain)
            .liquidGlassHover(outset: BrowseTrackRow.hoverOutset)
            .modifier(ArtworkPlaybackModifier(
                library: library, target: .track(track, queue: tracks), playback: playback,
                compact: true, effectsTrack: showsPlaybackEffects ? track : nil, beforePlay: beforePlay
            ))
            .contextMenu {
                PlayTracksMenu(tracks: [track], playback: playback)
                Button("Get Info", systemImage: "info.circle") {
                    beforePlay(track)
                    details = track
                }
            }
            Divider().padding(.leading, 46)
        }
        .sheet(item: $details) { TrackInfoView(library: library, track: $0) }
    }
}

@MainActor
struct BrowseTrackRow: View {
    static let hoverOutset = CGSize(width: 6, height: 1)

    let library: LibraryStore
    let track: AudioTrack

    var body: some View {
        HStack(spacing: 10) {
            BrowseArtwork(library: library, track: track, pixelSize: 96)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).fontWeight(.medium).lineLimit(1)
                Text(artistDisplayName(track.artist))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(timeLabel(track.duration)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

@MainActor
struct BrowseSongGrid: View {
    let library: LibraryStore
    let tracks: [AudioTrack]
    let playback: PlaybackController
    var displayAlbum = false
    var limit: Int? = nil
    var showsPlaybackEffects = false
    var beforePlay: (AudioTrack) -> Void = { _ in }

    @Environment(Preferences.self) private var preferences: Preferences?
    @State private var details: AudioTrack?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 180), spacing: 15)], alignment: .leading, spacing: 18) {
            ForEach(tracks.prefix(limit ?? tracks.count)) { track in
                Button {
                    beforePlay(track)
                    if preferences?.songTap == .details {
                        details = track
                    } else {
                        playback.play(track, in: tracks)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        BrowseArtwork(library: library, track: track, pixelSize: 250)
                        Text(displayAlbum && !track.album.isEmpty ? track.album : track.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(artistDisplayName(track.artist))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .liquidGlassHover(outset: BrowseArtwork.cardHoverOutset)
                .modifier(ArtworkPlaybackModifier(
                    library: library, target: .track(track, queue: tracks), playback: playback,
                    compact: false, effectsTrack: showsPlaybackEffects ? track : nil, beforePlay: beforePlay
                ))
                .contextMenu {
                    PlayTracksMenu(tracks: [track], playback: playback)
                    Button("Get Info", systemImage: "info.circle") {
                        beforePlay(track)
                        details = track
                    }
                }
            }
        }
        .sheet(item: $details) { TrackInfoView(library: library, track: $0) }
    }
}

struct HomeArtworkPlaybackState {
    let isCurrent: Bool
    let isPlaying: Bool

    var showsPlaying: Bool { isCurrent && isPlaying }
    var symbol: String { showsPlaying ? "pause.fill" : "play.fill" }
}

enum ArtworkPlaybackTarget {
    case track(AudioTrack, queue: [AudioTrack])
    case group([AudioTrack])

    func contains(_ track: AudioTrack?) -> Bool {
        guard let track else { return false }
        switch self {
        case .track(let song, _):
            return song.id == track.id
        case .group(let tracks):
            return tracks.contains { $0.id == track.id }
        }
    }
}

@MainActor
struct ArtworkPlaybackModifier: ViewModifier {
    let library: LibraryStore
    let target: ArtworkPlaybackTarget
    let playback: PlaybackController
    let compact: Bool
    var effectsTrack: AudioTrack? = nil
    var beforePlay: (AudioTrack) -> Void = { _ in }
    var artworkHovered: Bool?

    @Environment(\.libraryPlaybackEffectsVisible) private var effectsVisible

    func body(content: Content) -> some View {
        if effectsVisible {
            let isCurrent = target.contains(playback.current)
            let state = HomeArtworkPlaybackState(isCurrent: isCurrent, isPlaying: isCurrent && playback.playing)
            let title: LocalizedStringResource = state.showsPlaying ? "Pause" : "Play"
            content
                .overlay(alignment: compact ? .leading : .top) {
                    let artwork = ArtworkPlaybackControl(
                        library: library, effectsTrack: effectsTrack, playback: playback, state: state,
                        title: title, compact: compact, hoverOverride: artworkHovered, action: playOrPause
                    )
                    if compact {
                        artwork.frame(width: 36, height: 36)
                    } else {
                        artwork
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .accessibilityAction(named: Text(title), playOrPause)
        } else {
            content
        }
    }

    private func playOrPause() {
        if target.contains(playback.current) {
            playback.togglePlayback()
            return
        }
        switch target {
        case .track(let track, let queue):
            beforePlay(track)
            playback.play(track, in: queue)
        case .group(let tracks):
            playback.play(tracks, shuffled: false)
        }
    }
}

@MainActor
private struct ArtworkPlaybackControl: View {
    let library: LibraryStore
    let effectsTrack: AudioTrack?
    let playback: PlaybackController
    let state: HomeArtworkPlaybackState
    let title: LocalizedStringResource
    let compact: Bool
    let hoverOverride: Bool?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var visible = false
    @State private var palette = WavePalette.defaultPalette
    @FocusState private var focused: Bool

    var body: some View {
        let showsControl = (hoverOverride ?? isHovered) || focused
        let buttonSize: CGFloat = compact ? 28 : 34
        ZStack(alignment: .center) {
            Color.clear.allowsHitTesting(false)
            if let track = effectsTrack, state.isCurrent, visible, !reduceMotion {
                WaveBackground(
                    palette: palette, activity: state.showsPlaying ? .playing : .paused, playback: playback,
                    framesPerSecond: WaveClock.artworkFramesPerSecond
                )
                    .clipShape(.rect(cornerRadius: 9))
                    .opacity(0.75)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .task(id: track.id) {
                        palette = .defaultPalette
                        if let artwork = await library.artwork(for: track) {
                            let loaded = await WavePalette.fromArtwork(artwork)
                            if !Task.isCancelled { palette = loaded }
                        }
                    }
            }
            if effectsTrack != nil, state.showsPlaying, !showsControl {
                ArtworkSpectrumBadge(playback: playback, diameter: compact ? 16 : 22)
                    .padding(compact ? 2 : 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            Button(action: action) {
                Group {
                    if showsControl {
                        CenteredControlSymbol(name: state.symbol, size: CGSize(width: buttonSize, height: buttonSize),
                                              pointSize: compact ? 12 : 14)
                    } else {
                        Color.clear.frame(width: buttonSize, height: buttonSize)
                    }
                }
                .contentShape(Circle())
                .glassEffect(showsControl ? .regular.interactive() : .identity, in: Circle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .accessibilityLabel(Text(title))
            .opacity(showsControl ? 1 : 0)
            .scaleEffect(reduceMotion || showsControl ? 1 : GlassHoverMotion.initialScale)
            .allowsHitTesting(showsControl)
            .accessibilityHidden(!showsControl)
        }
        .onHover { isHovered = $0 }
        .onScrollVisibilityChange(threshold: 0.2) { visible = $0 }
        .animation(reduceMotion ? nil : GlassHoverMotion.appearance, value: showsControl)
    }
}

@MainActor
struct FolderBrowserPage: View {
    let route: LibraryRoute
    let library: LibraryStore
    let playback: PlaybackController
    let navigate: (LibraryRoute) -> Void
    let back: () -> Void
    let addFolder: () -> Void

    @State private var query = ""
    @State private var sortByName = true
    @State private var trackSort = TrackSortOrder(key: .title)
    @State private var filters = OfflineTrackFilters()

    private var selectedFolder: URL? {
        guard case .folder(let folder) = route else { return nil }
        return folder
    }

    var body: some View {
        let folder = selectedFolder
        let terms = BrowseSearch.terms(query)
        let descendants = folder.map { current in library.tracks.filter { belongs($0.url, to: current) } } ?? []
        let folders = entries(for: folder, descendants: descendants).filter {
            BrowseSearch.matches(terms, fields: [$0.name, $0.url.path]) ||
                $0.tracks.contains { $0.matches(query) }
        }
        let matches = descendants.filter {
            $0.url.deletingLastPathComponent().standardizedFileURL.path == folder?.standardizedFileURL.path &&
                $0.matches(query) && filters.matches($0)
        }
        let tracks = trackSort.sorted(matches)
        Group {
            if folders.isEmpty, tracks.isEmpty {
                BrowseEmpty(
                    title: terms.isEmpty ? "No Music Folders" : "No Matches",
                    symbol: "folder",
                    detail: folder == nil && terms.isEmpty ? "Add a folder to browse its music." : nil
                )
            } else if folders.isEmpty {
                BrowseTrackTable(library: library, tracks: tracks, playback: playback, sorting: $trackSort, navigate: navigate)
            } else if tracks.isEmpty {
                folderList(folders)
                    .browseScrollUnderHeader()
            } else {
                VSplitView {
                    folderList(folders)
                        .frame(minHeight: 54, idealHeight: min(140, Double(folders.count) * 43))
                    BrowseTrackTable(library: library, tracks: tracks, playback: playback, sorting: $trackSort, navigate: navigate)
                        .frame(minHeight: 110)
                }
                .contentMargins(.bottom, 0, for: .scrollIndicators)
            }
        }
        .padding(.horizontal, 26)
        .browseGlassHeader(spacing: folders.isEmpty && !tracks.isEmpty ? BrowseLayout.headerSpacing : 0) {
            VStack(spacing: 0) {
                BrowseHeading(title: route.title, subtitle: folder.map { _ in trackCount(descendants.count) }, back: folder == nil ? nil : back) {
                    if folder != nil, !descendants.isEmpty {
                        BrowsePlaybackButtons(tracks: descendants, playback: playback)
                    }
                    if folder != nil {
                        BrowseTrackSortMenu(sort: $trackSort.key, descending: $trackSort.descending)
                        BrowseTrackFiltersMenu(filters: $filters, tracks: descendants)
                    }
                    if !folders.isEmpty {
                        Menu("Folder Order", systemImage: "folder") {
                            Toggle("Ascending by Name", isOn: $sortByName)
                        }
                        .glassHoverMenu()
                    }
                    if folder == nil {
                        Button("Add Folder", systemImage: "folder.badge.plus", action: addFolder)
                            .buttonStyle(GlassHoverButtonStyle())
                            .disabled(library.isScanning)
                    }
                }
                if let folder {
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 12)
                }
            }
            .padding(.horizontal, 26)
        }
        .windowLibraryFilter(text: $query, prompt: "Filter Folders")
    }

    private func folderList(_ folders: [Folder]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(folders) { item in
                    Button {
                        navigate(.folder(item.url))
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.tint)
                                .frame(width: 36, alignment: .leading)
                            Text(item.name)
                            Spacer()
                            Text(item.detail)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlassHover(outset: BrowseTrackRow.hoverOutset)
                    .contextMenu {
                        Button("Open", systemImage: "arrow.right") { navigate(.folder(item.url)) }
                        if !item.tracks.isEmpty {
                            Divider()
                            PlayTracksMenu(tracks: item.tracks, playback: playback)
                        }
                    }
                    Divider().padding(.leading, 46)
                }
            }
            .padding(.top, 1)
            .padding(.bottom, 12)
        }
        .browseHoverGutter()
    }

    private func belongs(_ file: URL, to folder: URL) -> Bool {
        let folder = folder.standardizedFileURL.path
        return file.standardizedFileURL.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    private func entries(for folder: URL?, descendants: [AudioTrack]) -> [Folder] {
        let entries: [Folder]
        if let folder {
            let directory = folder.standardizedFileURL.path
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            let grouped = Dictionary(grouping: descendants) { track in
                track.url.standardizedFileURL.path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)
            }
            var children: [String: [AudioTrack]] = [:]
            for (path, tracks) in grouped where path.count > 1 {
                children[String(path[0]), default: []].append(contentsOf: tracks)
            }
            entries = children.map { name, tracks in
                Folder(url: folder.appendingPathComponent(name, isDirectory: true), name: name, tracks: tracks)
            }
        } else {
            entries = library.sources.map { source in
                let url = source.url.standardizedFileURL
                return Folder(
                    url: url, name: source.name,
                    tracks: library.tracks.filter { belongs($0.url, to: url) },
                    detail: source.status == .unavailable ? String(localized: "Unavailable") : nil
                )
            }
        }
        return entries.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison == .orderedSame { return $0.id.path < $1.id.path }
            return comparison == (sortByName ? .orderedAscending : .orderedDescending)
        }
    }

    private struct Folder: Identifiable {
        let url: URL
        let name: String
        let tracks: [AudioTrack]
        var detailOverride: String? = nil

        init(url: URL, name: String, tracks: [AudioTrack], detail: String? = nil) {
            self.url = url
            self.name = name
            self.tracks = tracks
            self.detailOverride = detail
        }

        var id: URL { url }
        var detail: String { detailOverride ?? trackCount(tracks.count) }
    }
}
