import SwiftUI

struct LyricsPanel: View {
    let document: LyricsDocument
    let position: @MainActor () -> Double
    let playing: Bool
    let offset: Double
    let textSize: Double
    let blur: Bool
    let seek: @MainActor (Double) -> Void
    var topOverflow: CGFloat = 0
    var positionSnapshot: (@MainActor () -> Double)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if document.isTimed {
            NativeLyrics(configuration: TimedLyricsConfiguration(
                document: document, position: position,
                pausedPosition: playing ? nil : (positionSnapshot?() ?? position()),
                playing: playing, offset: offset, textSize: textSize,
                blur: blur && !reduceMotion && contrast != .increased,
                reduceMotion: reduceMotion, topOverflow: topOverflow, seek: seek
            ))
        } else {
            GeometryReader { geometry in
                let typography = LyricsTypography(width: geometry.size.width, scale: textSize)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: typography.spacing) {
                        ForEach(document.lines) { line in
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
                    .padding(.horizontal, typography.horizontalInset)
                    .frame(maxWidth: typography.containerWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never, axes: .vertical)
                .scrollClipDisabled(topOverflow > 0)
            }
        }
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
