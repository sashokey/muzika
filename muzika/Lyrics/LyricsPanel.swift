import SwiftUI

struct LyricsPanel: View {
    let document: LyricsDocument
    let position: @MainActor () -> Double
    let playing: Bool
    let offset: Double
    let textSize: Double
    let blur: Bool
    let highlighting: TimedLyricsHighlighting
    let automaticallyScrollsUntimedLyrics: Bool
    let seek: @MainActor (Double) -> Void
    var topOverflow: CGFloat = 0
    var positionSnapshot: (@MainActor () -> Double)? = nil
    var duration: Double?
    var bottomClearance: CGFloat = 0
    var isWindowVisible = true

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var measuredLayout: (request: UntimedLayoutRequest, layout: UntimedLyricsLayout)?
    @State private var visibleRows = 0..<0
    @State private var incompatibleLines: [LyricsLine]?

    var body: some View {
        if document.isTimed {
            NativeLyrics(configuration: TimedLyricsConfiguration(
                document: document, position: position,
                pausedPosition: playing ? nil : (positionSnapshot?() ?? position()),
                playing: playing, offset: offset, textSize: textSize,
                blur: blur && !reduceMotion && contrast != .increased,
                reduceMotion: reduceMotion, topOverflow: topOverflow, seek: seek, duration: duration,
                highlighting: highlighting
            ))
        } else {
            GeometryReader { geometry in
                let typography = LyricsTypography(width: geometry.size.width, scale: textSize)
                let request = document.lines.count > 200 && !voiceOver && incompatibleLines != document.lines
                    ? UntimedLayoutRequest(lines: document.lines, typography: typography) : nil
                let measurement = request.flatMap { request in
                    measuredLayout.flatMap { $0.request.lines == request.lines ? $0 : nil }
                }
                let layout = measurement?.layout
                let displayedTypography = measurement?.request.typography ?? typography
                ScrollView {
                    untimedContent(typography: displayedTypography, layout: layout,
                                   viewportHeight: geometry.size.height, preparingLayout: request != nil)
                    .padding(.horizontal, displayedTypography.horizontalInset)
                    .frame(width: layout == nil ? nil : displayedTypography.containerWidth)
                    .frame(maxWidth: displayedTypography.containerWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, bottomClearance)
                    .background {
                        if automaticallyScrollsUntimedLyrics {
                            UntimedLyricsScrollDriver(
                                position: position, positionSnapshot: positionSnapshot?() ?? position(),
                                duration: duration, playing: playing, visible: isWindowVisible && scenePhase != .background,
                                reduceMotion: reduceMotion
                            )
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .scrollIndicators(.never, axes: .vertical)
                .scrollClipDisabled(topOverflow > 0)
                .onScrollGeometryChange(for: Range<Int>.self) { scroll in
                    layout?.rows(covering: scroll.visibleRect) ?? 0..<0
                } action: { _, rows in
                    visibleRows = rows
                }
                .task(id: request) {
                    guard let request else {
                        measuredLayout = nil
                        return
                    }
                    guard let result = await request.measure(), !Task.isCancelled else { return }
                    if measuredLayout?.request.lines != request.lines { visibleRows = 0..<0 }
                    measuredLayout = (request, result)
                }
            }
        }
    }

    @ViewBuilder
    private func untimedContent(typography: LyricsTypography, layout: UntimedLyricsLayout?,
                                viewportHeight: CGFloat, preparingLayout: Bool) -> some View {
        if let layout {
            let initial = CGRect(x: 0, y: 0, width: typography.textWidth, height: viewportHeight)
            let range = visibleRows.isEmpty ? layout.rows(covering: initial) : visibleRows
            let rows = range.clamped(to: document.lines.indices)
            Color.clear.frame(height: layout.height)
                .overlay(alignment: .topLeading) {
                    ForEach(rows, id: \.self) { index in
                        untimedRow(document.lines[index], typography: typography)
                            .onGeometryChange(for: Bool.self) { geometry in
                                layout.fitsRenderedRow(height: geometry.size.height, at: index)
                            } action: { fits in
                                if !fits { incompatibleLines = document.lines }
                            }
                            .offset(y: layout.origin(of: index))
                    }
                }
        } else {
            VStack(alignment: .leading, spacing: typography.spacing) {
                ForEach(document.lines.prefix(preparingLayout ? 32 : document.lines.count)) { line in
                    untimedRow(line, typography: typography)
                }
            }
        }
    }

    private func untimedRow(_ line: LyricsLine, typography: LyricsTypography) -> some View {
        VStack(alignment: .leading, spacing: typography.auxiliarySpacing) {
            if let pronunciation = line.pronunciation {
                Text(verbatim: pronunciation)
                    .font(.system(size: typography.auxiliarySize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: line.text)
                .font(.system(size: typography.textSize * (line.isBackground ? 0.86 : 1), weight: .medium))
            if let translation = line.translation {
                Text(verbatim: translation)
                    .font(.system(size: typography.auxiliarySize))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, line.isBackground ? 16 : 0)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .textSelection(.enabled)
    }
}

private nonisolated struct UntimedLayoutRequest: Sendable, Equatable {
    let lines: [LyricsLine]
    let typography: LyricsTypography

    @concurrent
    func measure() async -> UntimedLyricsLayout? {
        var heights: [CGFloat] = []
        heights.reserveCapacity(lines.count)
        for line in lines {
            guard !Task.isCancelled else { return nil }
            let width = max(1, typography.textWidth - (line.isBackground ? 16 : 0))
            let blocks = typography.blocks(for: line, untimed: true)
            heights.append(blocks.reduce(0) { $0 + $1.height(at: width) }
                + CGFloat(max(0, blocks.count - 1)) * typography.auxiliarySpacing)
        }
        return UntimedLyricsLayout(heights: heights, spacing: typography.spacing)
    }
}

private struct NativeLyrics: NSViewRepresentable {
    let configuration: TimedLyricsConfiguration

    func makeNSView(context: Context) -> TimedLyricsScrollView {
        TimedLyricsScrollView(frame: .zero)
    }

    func updateNSView(_ view: TimedLyricsScrollView, context: Context) {
        view.configure(configuration)
    }

    static func dismantleNSView(_ view: TimedLyricsScrollView, coordinator: ()) {
        view.stop()
    }
}
