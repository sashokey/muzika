import SwiftUI

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

enum ArtworkPlaybackLayout {
    case grid
    case row
    case song

    static let songArtworkSize: CGFloat = 22
    static let songArtworkGap: CGFloat = 7

    var artworkSize: CGFloat? {
        switch self {
        case .grid: nil
        case .row: 36
        case .song: Self.songArtworkSize
        }
    }

    var buttonSize: CGFloat {
        switch self {
        case .grid: 34
        case .row: 28
        case .song: Self.songArtworkSize
        }
    }

    var hitWidth: CGFloat { buttonSize + (self == .song ? Self.songArtworkGap : 0) }
    var artworkWidth: CGFloat? { self == .song ? hitWidth : artworkSize }

    var symbolSize: CGFloat {
        switch self {
        case .grid: 14
        case .row: 12
        case .song: 10
        }
    }

    func buttonFrame(in artwork: CGRect) -> CGRect {
        CGRect(x: artwork.midX - buttonSize / 2, y: artwork.midY - buttonSize / 2,
               width: buttonSize, height: buttonSize)
    }
}

@MainActor
struct ArtworkPlaybackModifier: ViewModifier {
    let library: LibraryStore
    let target: ArtworkPlaybackTarget
    let playback: PlaybackController
    let layout: ArtworkPlaybackLayout
    var effectsTrack: AudioTrack? = nil
    var beforePlay: (AudioTrack) -> Void = { _ in }
    let cardHoverOutset: CGSize?
    var hoverOverride: Bool?
    var buttonHoverOverride: Bool?

    @State private var cardHovered = false

    @Environment(\.libraryPlaybackEffectsVisible) private var effectsVisible

    @ViewBuilder
    func body(content: Content) -> some View {
        let hovered = hoverOverride ?? cardHovered
        let card = playbackOverlay(for: cardSurface(for: content, hovered: hovered), hovered: hovered)
        if hoverOverride == nil, cardHoverOutset != nil {
            card.stableHover { cardHovered = $0 }
        } else {
            card
        }
    }

    @ViewBuilder
    private func cardSurface(for content: Content, hovered: Bool) -> some View {
        if let cardHoverOutset {
            content.liquidGlassHover(outset: cardHoverOutset, hovered: hovered)
        } else {
            content
        }
    }

    @ViewBuilder
    private func playbackOverlay(for content: some View, hovered: Bool) -> some View {
        if effectsVisible {
            let isCurrent = target.contains(playback.current)
            let state = HomeArtworkPlaybackState(isCurrent: isCurrent, isPlaying: isCurrent && playback.playing)
            let title: LocalizedStringResource = state.showsPlaying ? "Pause" : "Play"
            content
                .overlay(alignment: layout == .grid ? .top : .leading) {
                    let artwork = ArtworkPlaybackControl(
                        library: library, effectsTrack: effectsTrack, playback: playback, state: state,
                        title: title, layout: layout,
                        hoverOverride: layout == .grid ? hovered : buttonHoverOverride, action: playOrPause
                    )
                    if let width = layout.artworkWidth, let height = layout.artworkSize {
                        artwork.frame(width: width, height: height)
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
    let layout: ArtworkPlaybackLayout
    let hoverOverride: Bool?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var buttonHovered = false
    @State private var visible = false
    @State private var palette = WavePalette.defaultPalette
    @FocusState private var focused: Bool

    var body: some View {
        let showsControl = (hoverOverride ?? buttonHovered) || focused
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
            if layout == .song, state.isCurrent, !showsControl {
                ArtworkSpectrumBadge(playback: playback, diameter: layout.buttonSize, style: .songs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if effectsTrack != nil, state.showsPlaying, !showsControl {
                ArtworkSpectrumBadge(playback: playback, diameter: layout == .row ? 16 : 22)
                    .padding(layout == .row ? 2 : 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            playbackButton(showsControl: showsControl)
        }
        .onScrollVisibilityChange(threshold: 0.2) { visible = $0 }
        .animation(reduceMotion ? nil : GlassHoverMotion.appearance, value: showsControl)
    }

    @ViewBuilder
    private func playbackButton(showsControl: Bool) -> some View {
        let size = layout.buttonSize
        let button = Button(action: action) {
            let surface = Group {
                if showsControl {
                    CenteredControlSymbol(name: state.symbol, size: CGSize(width: size, height: size),
                                          pointSize: layout.symbolSize)
                } else {
                    Color.clear.frame(width: size, height: size)
                }
            }
            .glassEffect(showsControl ? .regular.interactive() : .identity, in: Circle())
            .scaleEffect(reduceMotion || showsControl ? 1 : GlassHoverMotion.initialScale)
            if layout == .grid {
                surface.contentShape(Circle())
            } else {
                surface
                    .frame(width: layout.hitWidth, height: size, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .focused($focused)
        .accessibilityLabel(Text(title))
        .opacity(showsControl ? 1 : 0)
        .allowsHitTesting(showsControl)
        .accessibilityHidden(!showsControl)
        if hoverOverride == nil {
            button.stableHover { inside in
                #if MUZIKA_DEV_LOGS
                if buttonHovered != inside {
                    MuzikaTrace.event(.library, "artwork.play.hover", "inside=\(inside) layout=\(layout) target_width_pt=\(layout.hitWidth)")
                }
                #endif
                buttonHovered = inside
            }
        } else {
            button
        }
    }

}
