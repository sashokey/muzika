import AppKit
import SwiftUI

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
