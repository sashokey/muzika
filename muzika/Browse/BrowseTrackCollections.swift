import SwiftUI

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
            .modifier(ArtworkPlaybackModifier(
                library: library, target: .track(track, queue: tracks), playback: playback,
                layout: .row, effectsTrack: showsPlaybackEffects ? track : nil, beforePlay: beforePlay,
                cardHoverOutset: BrowseTrackRow.hoverOutset
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
                .modifier(ArtworkPlaybackModifier(
                    library: library, target: .track(track, queue: tracks), playback: playback,
                    layout: .grid, effectsTrack: showsPlaybackEffects ? track : nil, beforePlay: beforePlay,
                    cardHoverOutset: BrowseArtwork.cardHoverOutset
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
