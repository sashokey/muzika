import SwiftUI

extension EnvironmentValues {
    @Entry var libraryPlaybackEffectsVisible = true
}

struct ArtworkSpectrumBadge: View {
    let playback: PlaybackController
    let diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.libraryPlaybackEffectsVisible) private var effectsVisible
    @State private var isVisible = true
    @State private var levels = Self.idleLevels

    private static let idleLevels: [CGFloat] = [0.32, 0.58, 0.83, 0.58, 0.32]

    var body: some View {
        let animates = playback.playing && effectsVisible && isVisible && !reduceMotion && scenePhase != .background
        let title: LocalizedStringResource = playback.playing ? "Playing" : "Current Song"
        HStack(spacing: diameter * 0.038) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: diameter * 0.071, height: diameter * 0.58 * levels[index])
            }
        }
        .frame(width: diameter, height: diameter)
        .background(.black.opacity(0.82), in: .circle)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .onScrollVisibilityChange(threshold: 0.4) { isVisible = $0 }
        .task(id: animates) { await updateLevels(animates: animates) }
    }

    static func bands(from spectrum: [Float]) -> [CGFloat] {
        guard !spectrum.isEmpty else { return idleLevels }
        return (0..<5).map { band in
            let start = spectrum.count * band / 5
            let end = spectrum.count * (band + 1) / 5
            let peak = spectrum[start..<end].reduce(Float.zero) { peak, sample in
                sample.isFinite ? max(peak, sample) : peak
            }
            return CGFloat(0.23 + 0.77 * min(1, peak))
        }
    }

    private func updateLevels(animates: Bool) async {
        guard animates else {
            levels = Self.idleLevels
            return
        }
        let client = UUID()
        playback.setSpectrumEnabled(true, from: client)
        defer { playback.setSpectrumEnabled(false, from: client) }
        while !Task.isCancelled {
            let next = Self.bands(from: playback.spectrum())
            if levels != next {
                withAnimation(.easeInOut(duration: 0.14)) { levels = next }
            }
            do { try await Task.sleep(for: .milliseconds(85)) }
            catch { return }
        }
    }
}
