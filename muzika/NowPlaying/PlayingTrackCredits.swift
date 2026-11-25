import SwiftUI

@MainActor
struct PlayingTrackCredits: View {
    let track: AudioTrack
    let navigate: (LibraryRoute) -> Void

    private struct Segment {
        let text: String
        let route: LibraryRoute?
    }

    var body: some View {
        let artists = artistSegments
        let album = Segment(text: track.album, route: track.isTemporary ? nil : BrowseGroup.albumRoute(track.albumKey))
        Group {
            if artists.isEmpty {
                if !album.text.isEmpty { credit(album).lineLimit(2) }
            } else if album.text.isEmpty {
                artistLine(artists).lineLimit(2)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        artistLine(artists)
                        Text(verbatim: " · ")
                        credit(album)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 0) {
                        artistLine(artists)
                        credit(album)
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

    @ViewBuilder
    private func credit(_ segment: Segment) -> some View {
        if let route = segment.route {
            CreditLink(text: segment.text) { navigate(route) }
        } else {
            Text(verbatim: segment.text)
        }
    }
}

private struct CreditLink: View {
    let text: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .foregroundStyle(hovering ? Color.white : Color.secondary)
                .animation(reduceMotion ? nil : GlassHoverMotion.appearance, value: hovering)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityAddTraits(.isLink)
        .stableHover { hovering = $0 }
    }
}
