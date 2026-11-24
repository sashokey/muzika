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

struct BrowseTrackSortMenu: View {
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

struct BrowseTrackFiltersMenu: View {
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
