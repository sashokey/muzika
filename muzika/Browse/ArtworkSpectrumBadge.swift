import SwiftUI

extension EnvironmentValues {
    @Entry var libraryPlaybackEffectsVisible = true
}

struct ArtworkSpectrumBadge: View {
    enum Style {
        case circle
        case songs
        case audioInfo
    }

    let playback: PlaybackController
    let diameter: CGFloat
    var style: Style = .circle
    var isPresented = true
    var width: CGFloat?
    var verticalOutset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.libraryPlaybackEffectsVisible) private var effectsVisible
    @State private var isVisible = true
    @State private var levels: [CGFloat]?

    private static let idleLevels: [CGFloat] = [0.32, 0.58, 0.83, 0.58, 0.32]
    private static let audioInfoBandCount = 16
    private static let minimumSpectrumLevel: CGFloat = 0.23
    private static let silentLevels = Array(repeating: minimumSpectrumLevel, count: audioInfoBandCount)

    private var restingLevels: [CGFloat] { style == .audioInfo ? Self.silentLevels : Self.idleLevels }

    var body: some View {
        let visible = style == .audioInfo ? isPresented : effectsVisible && isVisible
        let animates = playback.playing && visible && !reduceMotion && scenePhase != .background
        let title: LocalizedStringResource = playback.playing ? "Playing" : "Current Song"
        Group {
            switch style {
            case .songs:
                bars.shadow(color: .black.opacity(0.9), radius: 1)
            case .circle:
                bars.background(.black.opacity(0.82), in: .circle)
            case .audioInfo:
                infoBars.accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .onScrollVisibilityChange(threshold: 0.4) { isVisible = $0 }
        .task(id: animates) { await updateLevels(animates: animates) }
    }

    private var bars: some View {
        let levels = levels ?? restingLevels
        let isSongs = style == .songs
        return HStack(alignment: isSongs ? .bottom : .center, spacing: diameter * (isSongs ? 0.065 : 0.038)) {
            ForEach(levels.indices, id: \.self) { index in
                let level = levels[index]
                Capsule()
                    .fill(.white)
                    .frame(
                        width: diameter * (isSongs ? 0.114 : 0.071),
                        height: diameter * (isSongs ? 0.22 + 0.5 * level : 0.58 * level)
                    )
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var infoBars: some View {
        let peakHeight = diameter + 2 * verticalOutset
        let restingHeight = diameter * (0.08 + 0.79 * Self.minimumSpectrumLevel)
        let heights = (levels ?? restingLevels).map { level in
            let progress = (level - Self.minimumSpectrumLevel) / (1 - Self.minimumSpectrumLevel)
            return restingHeight + (peakHeight - restingHeight) * progress
        }
        return AudioInfoSpectrumBars(heights: heights, width: width ?? diameter, peakHeight: peakHeight)
            .frame(height: diameter)
            .environment(\.layoutDirection, .leftToRight)
    }

    static func bands(from spectrum: [Float], count: Int = 5) -> [CGFloat] {
        guard !spectrum.isEmpty else { return count == 5 ? idleLevels : silentLevels }
        return (0..<count).map { band in
            let start = spectrum.count * band / count
            let end = spectrum.count * (band + 1) / count
            let peak = spectrum[start..<end].reduce(Float.zero) { peak, sample in
                sample.isFinite ? max(peak, sample) : peak
            }
            return minimumSpectrumLevel + (1 - minimumSpectrumLevel) * CGFloat(min(1, peak))
        }
    }

    private func updateLevels(animates: Bool) async {
        guard animates else {
            if style == .audioInfo, !reduceMotion {
                withAnimation(.easeOut(duration: 0.14)) { levels = restingLevels }
            } else {
                levels = restingLevels
            }
            return
        }
        let client = UUID()
        let audioInfo = style == .audioInfo
        if audioInfo { playback.setAudioInfoSpectrumEnabled(true, from: client) }
        else { playback.setSpectrumEnabled(true, from: client) }
        defer {
            if audioInfo { playback.setAudioInfoSpectrumEnabled(false, from: client) }
            else { playback.setSpectrumEnabled(false, from: client) }
        }
        let clock = ContinuousClock()
        let interval: Duration = audioInfo ? .nanoseconds(16_666_667) : .milliseconds(85)
        while !Task.isCancelled {
            let deadline = clock.now + interval
            let spectrum = audioInfo ? playback.audioInfoSpectrum() : playback.spectrum()
            let next: [CGFloat] = if spectrum.isEmpty {
                restingLevels
            } else if audioInfo {
                spectrum.map { Self.minimumSpectrumLevel + (1 - Self.minimumSpectrumLevel) * CGFloat($0) }
            } else {
                Self.bands(from: spectrum)
            }
            if levels != next {
                if audioInfo { levels = next }
                else { withAnimation(.easeInOut(duration: 0.14)) { levels = next } }
            }
            do { try await clock.sleep(until: audioInfo ? deadline : clock.now + interval) }
            catch { return }
        }
    }
}

struct AudioInfoSpectrumBars: View {
    let heights: [CGFloat]
    let width: CGFloat
    let peakHeight: CGFloat

    @Environment(\.pixelLength) private var pixelLength

    var body: some View {
        let count = CGFloat(max(1, heights.count))
        let totalPixels = (width / pixelLength).rounded(.down)
        let barPixels = max(1, (totalPixels / (count * 2)).rounded())
        let pitch = max(0, (totalPixels - barPixels) / max(1, count - 1)).rounded(.down)
        let leading = ((totalPixels - barPixels - pitch * (count - 1)) * 0.5).rounded(.down)
        return ZStack {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(.foreground)
                    .frame(width: barPixels * pixelLength, height: heights[index])
                    .position(x: (leading + CGFloat(index) * pitch + barPixels * 0.5) * pixelLength,
                              y: peakHeight * 0.5)
            }
        }
        .frame(width: width, height: peakHeight)
    }
}
