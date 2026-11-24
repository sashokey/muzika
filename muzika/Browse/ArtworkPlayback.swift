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
