import AppKit
import ImageIO
import SwiftUI

struct PlayerCapsule: View {
    @Bindable var state: AppState
    @State private var editingTime: Double?

    var body: some View {
        if let track = state.playback.current {
            HStack(spacing: 12) {
                TransportControls(playback: state.playback, compact: true)
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: state.showPlayer) {
                        HStack(spacing: 8) {
                            PlayingCover(library: state.library, track: track, maxPixels: 96)
                                .frame(width: 33, height: 33)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlassHover(outset: CGSize(width: 3, height: 3))
                    .help("Open Now Playing")
                    .accessibilityLabel("Open Now Playing, \(track.title)")
                    Scrubber(playback: state.playback, duration: track.duration, editingTime: $editingTime)
                        .controlSize(.mini)
                }
                .frame(minWidth: 110, maxWidth: .infinity)
                HStack(spacing: 3) {
                    PlayerIcon("Lyrics", symbol: "quote.bubble") { state.togglePanel(.lyrics) }
                    PlayerIcon("Up Next", symbol: "list.bullet") { state.togglePanel(.queue) }
                    PlayerVolumeButton(state: state, acceptsWheel: { !state.showingPlayer })
                    if !state.playback.playing {
                        PlayerIcon("Dismiss", symbol: "xmark", action: state.dismissPlayback)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 5.5)
            .frame(maxWidth: 760)
            .glassEffect(.regular.interactive(), in: .capsule)
            .onChange(of: state.playback.currentEntryID) { _, _ in editingTime = nil }
        }
    }
}

struct PlayerVolumeButton: View {
    let state: AppState
    let acceptsWheel: () -> Bool
    @State private var showingVolume = false

    var body: some View {
        PlayerIcon("Volume", symbol: volumeSymbol(state.playback.volume)) { showingVolume.toggle() }
            .background {
                if acceptsWheel() {
                    VolumeScroll { change in
                        guard acceptsWheel() else { return false }
                        state.setVolume(state.playback.volume + change)
                        return true
                    }
                }
            }
            .popover(isPresented: $showingVolume, arrowEdge: .bottom) {
                VolumeControl(state: state).padding(12).frame(width: 210)
            }
    }
}

struct PlayerIcon: View {
    static let size = CGSize(width: 27, height: 28)

    let title: LocalizedStringResource
    let symbol: String
    let highlighted: Bool
    let hoverScale: CGFloat
    let symbolScale: CGFloat
    let action: () -> Void

    init(
        _ title: LocalizedStringResource, symbol: String, highlighted: Bool = false, hoverScale: CGFloat = 1, symbolScale: CGFloat = 1,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.highlighted = highlighted
        self.hoverScale = hoverScale
        self.symbolScale = symbolScale
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            CenteredControlSymbol(name: symbol, size: Self.size, symbolScale: symbolScale)
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
                .contentShape(Rectangle().scale(x: symbolScale, y: symbolScale))
        }
        .buttonStyle(.plain)
        .liquidGlassHover(in: Circle(), scale: hoverScale)
        .accessibilityLabel(title)
        .help(title)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

struct TransportControls: View {
    @Bindable var playback: PlaybackController
    let compact: Bool

    var body: some View {
        let primaryScale: CGFloat = compact ? 1.15 : 1.45
        HStack(spacing: compact ? 4 : 20) {
            PlayerIcon("Shuffle", symbol: "shuffle", highlighted: playback.shuffle) { playback.shuffle.toggle() }
            if !compact { Spacer(minLength: 0) }
            PlayerIcon("Previous", symbol: "backward.fill", hoverScale: primaryScale, action: playback.previous)
            if !compact { Spacer(minLength: 0) }
            PlayerIcon(
                playback.playing ? "Pause" : "Play", symbol: playback.playing ? "pause.fill" : "play.fill",
                hoverScale: primaryScale, symbolScale: primaryScale, action: playback.togglePlayback
            )
            if !compact { Spacer(minLength: 0) }
            PlayerIcon("Next", symbol: "forward.fill", hoverScale: primaryScale, action: playback.next)
            if !compact { Spacer(minLength: 0) }
            PlayerIcon(
                repeatLabel, symbol: playback.repeatMode == .one ? "repeat.1" : "repeat",
                highlighted: playback.repeatMode != .off
            ) {
                playback.repeatMode = switch playback.repeatMode {
                case .off: .all
                case .all: .one
                case .one: .off
                }
            }
        }
    }

    private var repeatLabel: LocalizedStringResource {
        switch playback.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }
}

struct Scrubber: View {
    var playback: PlaybackController
    let duration: Double
    @Binding var editingTime: Double?

    var body: some View {
        Slider(
            value: Binding(
                get: { min(max(editingTime ?? playback.position, 0), max(0.01, duration)) },
                set: { editingTime = $0 }
            ),
            in: 0...max(0.01, duration)
        ) {
            Text("Playback position")
        } onEditingChanged: { editing in
            if !editing, let value = editingTime {
                playback.seek(to: value)
                editingTime = nil
            }
        }
        .labelsHidden()
        .accessibilityValue(elapsedLabel(editingTime ?? playback.position))
    }
}

struct PlayingCover: View {
    let library: LibraryStore
    let track: AudioTrack
    let maxPixels: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cover: CGImage?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Rectangle().fill(.quaternary)
                if let cover {
                    Image(decorative: cover, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: min(size.width, size.height) * 0.31, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .clipShape(.rect(cornerRadius: max(4, min(size.width, size.height) * 0.045)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: cover != nil)
        }
        .task(id: track.id) {
            cover = nil
            if let data = await library.artwork(for: track) {
                let image = await CoverDecoding.image(data, limit: maxPixels)
                if !Task.isCancelled { cover = image }
            }
        }
        .accessibilityHidden(true)
    }
}

enum CoverDecoding {
    @concurrent
    static func image(_ data: Data, limit: Int) async -> CGImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ] as CFDictionary)
    }
}

struct VolumeControl: View {
    var state: AppState

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "speaker.fill").accessibilityHidden(true)
            Slider(value: Binding(get: { state.playback.volume }, set: state.setVolume), in: 0...1) {
                Text("Volume")
            }
            .labelsHidden()
            .accessibilityValue(state.playback.volume.formatted(.percent))
            Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
        }
        .background(VolumeScroll { change in
            state.setVolume(state.playback.volume + change)
            return true
        })
    }
}

private struct VolumeScroll: NSViewRepresentable {
    var change: (Double) -> Bool

    func makeNSView(context: Context) -> VolumeScrollView {
        VolumeScrollView()
    }

    func updateNSView(_ view: VolumeScrollView, context: Context) {
        view.change = change
    }
}

private final class VolumeScrollView: NSView {
    var change: ((Double) -> Bool)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.viewWillMove(toWindow: newWindow)
        guard newWindow != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.bounds.intersection(self.visibleRect).contains(self.convert(event.locationInWindow, from: nil)),
                  !event.scrollingDeltaY.isZero, event.momentumPhase.isEmpty else { return event }
            let scale = event.hasPreciseScrollingDeltas ? 0.0025 : 0.035
            return self.change?(event.scrollingDeltaY * scale) == true ? nil : event
        }
    }
}

func elapsedLabel(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(min(max(seconds, 0), 360_000)) : 0
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

func volumeSymbol(_ volume: Double) -> String {
    switch volume {
    case 0: "speaker.slash"
    case ..<0.35: "speaker.wave.1"
    case ..<0.7: "speaker.wave.2"
    default: "speaker.wave.3"
    }
}
