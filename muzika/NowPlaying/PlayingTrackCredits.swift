import SwiftUI

@MainActor
struct PlayingTrackCredits: View {
    let track: AudioTrack
    let showsAlbum: Bool
    let showsReleaseYear: Bool
    let navigate: (LibraryRoute) -> Void

    private static let albumColor = Color.secondary.opacity(0.85)

    private struct Segment {
        let text: String
        let route: LibraryRoute?
    }

    var body: some View {
        let artists = artistSegments
        let album = Segment(text: showsAlbum ? track.album : "",
                            route: track.isTemporary ? nil : BrowseGroup.albumRoute(track.albumKey))
        let year = showsReleaseYear ? track.year : nil
        let hasAlbumLine = !album.text.isEmpty || year != nil
        Group {
            if artists.isEmpty {
                if hasAlbumLine { albumLine(album, year: year).lineLimit(2) }
            } else if !hasAlbumLine {
                artistLine(artists).lineLimit(2)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        artistLine(artists)
                        Text(verbatim: " · ")
                        albumLine(album, year: year)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 0) {
                        artistLine(artists)
                        albumLine(album, year: year)
                    }
                }
                .lineLimit(1)
            }
        }
        .font(.body)
        .foregroundStyle(.secondary)
    }

    private var artistSegments: [Segment] {
        let value = track.artist
        guard !value.isEmpty else { return [] }
        if track.isTemporary { return [Segment(text: value, route: nil)] }

        var segments: [Segment] = []
        var start = value.startIndex
        for name in BrowseGroup.artistCredits(track) where !name.isEmpty {
            guard let range = value.range(of: name, range: start..<value.endIndex) else { continue }
            if start < range.lowerBound {
                segments.append(Segment(text: String(value[start..<range.lowerBound]), route: nil))
            }
            segments.append(Segment(text: String(value[range]), route: .artist(AudioTrack.artistKey(name))))
            start = range.upperBound
        }
        if start < value.endIndex {
            segments.append(Segment(text: String(value[start...]), route: nil))
        }
        return segments
    }

    private func artistLine(_ segments: [Segment]) -> some View {
        HStack(spacing: 0) {
            ForEach(segments.indices, id: \.self) { index in
                credit(segments[index])
            }
        }
    }

    private func albumLine(_ album: Segment, year: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !album.text.isEmpty { credit(album, restingColor: Self.albumColor) }
            if let year {
                Text(verbatim: album.text.isEmpty ? String(year) : " · \(year)")
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .foregroundStyle(Self.albumColor)
    }

    @ViewBuilder
    private func credit(_ segment: Segment, restingColor: Color = .secondary) -> some View {
        if let route = segment.route {
            CreditLink(text: segment.text, restingColor: restingColor) { navigate(route) }
        } else {
            Text(verbatim: segment.text)
        }
    }
}

private struct CreditLink: View {
    let text: String
    let restingColor: Color
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .foregroundStyle(hovering ? Color.white : restingColor)
                .animation(reduceMotion ? nil : GlassHoverMotion.appearance, value: hovering)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityAddTraits(.isLink)
        .stableHover { hovering = $0 }
    }
}
