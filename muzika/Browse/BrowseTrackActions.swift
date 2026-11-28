import AppKit
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

extension BrowseHeaderMenu {
    static func trackSort(_ sort: Binding<TrackSortOrder>) -> Self {
        Self(id: .sort, title: "Sort", symbol: "arrow.up.arrow.down", entries: [
            .submenu("Sort By", BrowseHeaderMenuEntry.choices(BrowseSort.allCases, selection: sort.key) {
                Text($0.displayTitle)
            }),
            .separator,
            .command(Text("Reverse Order"), selected: sort.wrappedValue.descending) {
                sort.wrappedValue.descending.toggle()
            }
        ])
    }

    static func trackFilters(_ filters: Binding<OfflineTrackFilters>, tracks: [AudioTrack]) -> Self {
        let value = filters.wrappedValue
        let formats = Set(tracks.map { $0.url.pathExtension.lowercased() })
            .union(value.format.map { [$0] } ?? []).filter { !$0.isEmpty }.sorted()
        return Self(
            id: .filters, title: "Filters",
            symbol: value == .init() ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
            entries: [
                .submenu("Quality", BrowseHeaderMenuEntry.choices(OfflineTrackFilters.Quality.allCases, selection: filters.quality) {
                    Text($0.displayTitle)
                }),
                .submenu("Format", BrowseHeaderMenuEntry.choices([nil] + formats.map(Optional.some), selection: filters.format) {
                    if let format = $0 { Text(format.uppercased()) } else { Text("All") }
                }),
                .submenu("Metadata", BrowseHeaderMenuEntry.choices(OfflineTrackFilters.Metadata.allCases, selection: filters.metadata) {
                    Text($0.displayTitle)
                }),
                .separator,
                .command(Text("Reset"), selected: false, enabled: value != .init()) { filters.wrappedValue = .init() }
            ]
        )
    }
}

@MainActor
struct BrowsePlaybackButtons: View {
    let tracks: [AudioTrack]
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Button("Play", systemImage: "play.fill") { playback.play(tracks, shuffled: false) }
                .buttonStyle(GlassHoverButtonStyle.accent())
            Button("Shuffle", systemImage: "shuffle") { playback.play(tracks, shuffled: true) }
                .buttonStyle(GlassHoverButtonStyle.action())
        }
        .disabled(tracks.isEmpty)
    }
}
