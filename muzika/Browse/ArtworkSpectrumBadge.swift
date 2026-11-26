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
        let levels = levels ?? restingLevels
        let width = width ?? diameter
        let column = width / CGFloat(levels.count)
        let peakHeight = diameter + 2 * verticalOutset
        let restingHeight = diameter * (0.08 + 0.79 * Self.minimumSpectrumLevel)
        return HStack(spacing: 0) {
            ForEach(levels.indices, id: \.self) { index in
                let level = levels[index]
                let progress = (level - Self.minimumSpectrumLevel) / (1 - Self.minimumSpectrumLevel)
                Capsule()
                    .fill(.foreground)
                    .frame(width: column * 0.5,
                           height: restingHeight + (peakHeight - restingHeight) * progress)
                    .frame(width: column, height: peakHeight)
            }
        }
        .frame(width: width, height: diameter)
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
        playback.setSpectrumEnabled(true, from: client)
        #if MUZIKA_DEV_LOGS
        var lastSpectrumReport = -Double.infinity
        if style == .audioInfo {
            MuzikaTrace.event(.controls, "spectrum.start",
                "bands=\(restingLevels.count) width_pt=\(width ?? diameter) peak_height_pt=\(diameter + 2 * verticalOutset)")
        }
        defer {
            if style == .audioInfo { MuzikaTrace.event(.controls, "spectrum.stop") }
        }
        #endif
        defer { playback.setSpectrumEnabled(false, from: client) }
        while !Task.isCancelled {
            let spectrum = playback.spectrum()
            let next = spectrum.isEmpty ? restingLevels : Self.bands(from: spectrum, count: restingLevels.count)
            #if MUZIKA_DEV_LOGS
            let now = ProcessInfo.processInfo.systemUptime
            if style == .audioInfo, now - lastSpectrumReport >= 1 {
                lastSpectrumReport = now
                MuzikaTrace.event(.controls, "spectrum.levels",
                    "available=\(!spectrum.isEmpty) bass=\(next.first ?? 0) peak=\(next.max() ?? 0) treble=\(next.last ?? 0)")
            }
            #endif
            if levels != next {
                withAnimation(.easeInOut(duration: 0.14)) { levels = next }
            }
            do { try await Task.sleep(for: .milliseconds(85)) }
            catch { return }
        }
    }
}
