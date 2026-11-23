import Foundation
import NowPlaying
import Observation

@MainActor
@Observable
final class SystemPlayback: MediaSessionRepresentable {
    let id = "local-player"
    private(set) var content: (any MediaContentRepresentable)?
    private(set) var playbackSnapshot: MediaPlaybackSnapshot?
    private(set) var commands: [MediaCommand] = []

    @ObservationIgnored private weak var playback: PlaybackController?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var publishedTrack: AudioTrack?
    @ObservationIgnored private var session: MediaSession<SystemPlayback>?
    @ObservationIgnored private var primacy: Task<Void, Never>?
    @ObservationIgnored private var lastRepeat: RepeatMode?
    @ObservationIgnored private var lastShuffle: Bool?
    @ObservationIgnored private var lastEnabled: Bool?

    init(library: LibraryStore, playback: PlaybackController) {
        self.library = library
        self.playback = playback
    }

    func update() {
        guard let playback else { return }
        if publishedTrack != playback.current {
            publishedTrack = playback.current
            content = playback.current.map { track in
                let trackArtwork = Artwork(id: track.id) { [library] _ in
                    guard let image = await library.artwork(for: track) else {
                        throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
                    }
                    return try ArtworkRepresentation(data: image)
                }
                let duration: MediaDuration? = track.duration.isFinite && track.duration > 0
                    ? .finite(track.duration)
                    : nil
                var media = MusicContent(
                    id: track.id, songTitle: track.title, artistName: track.artist, albumName: track.album,
                    type: .audio, duration: duration, artwork: trackArtwork
                )
                media.genre = track.genre
                media.isExcludedFromSuggestions = true
                return media
            }
        }

        let available = playback.current != nil
        let state: MediaPlaybackSnapshot.PlaybackState
        if playback.playing {
            state = playback.isRendering ? .playing() : .buffering
        } else {
            state = .paused
        }
        playbackSnapshot = available ? MediaPlaybackSnapshot(
            state: state,
            elapsedTime: playback.livePosition, timestamp: .now
        ) : nil
        if lastRepeat != playback.repeatMode || lastShuffle != playback.shuffle || lastEnabled != available {
            commands = available ? controls(for: playback) : []
            lastRepeat = playback.repeatMode
            lastShuffle = playback.shuffle
            lastEnabled = available
        }
        if available {
            if session == nil { session = MediaSession(self) }
            if playback.playing, let session, !session.isApplicationPrimary, primacy == nil {
                primacy = Task { [weak self, weak session] in
                    defer {
                        if self?.session === session { self?.primacy = nil }
                    }
                    do {
                        try await session?.requestToBecomeApplicationPrimary()
                    } catch where !Task.isCancelled {
                        MuzikaDiagnostics.report("System Now Playing: \(error.localizedDescription)")
                    } catch {
                    }
                }
            }
        } else {
            primacy?.cancel()
            primacy = nil
            session = nil
        }
    }

    private func controls(for playback: PlaybackController) -> [MediaCommand] {
        let repeatSetting: MediaCommand.RepeatMode = switch playback.repeatMode {
        case .off: .off
        case .one: .one
        case .all: .all
        }
        return [
            .play { [weak playback] in
                if let playback, !playback.playing { playback.togglePlayback() }
            },
            .pause { [weak playback] in
                if let playback, playback.playing { playback.togglePlayback() }
            },
            .togglePlayPause { [weak playback] in playback?.togglePlayback() },
            .previous { [weak playback] in playback?.previous() },
            .next { [weak playback] in playback?.next() },
            .seekToPosition { [weak playback] time in playback?.seek(to: time) },
            .changeRepeatMode(current: repeatSetting) { [weak playback] mode in
                playback?.repeatMode = switch mode {
                case .off: .off
                case .all: .all
                case .one: .one
                @unknown default: .off
                }
            },
            .changeShuffleMode(current: playback.shuffle ? .items : .off, supported: [.off, .items]) { [weak playback] mode in
                playback?.shuffle = mode == .items
            }
        ]
    }
}
