import AppKit
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var userIsScrolling = false
    @State private var scrollResumeAt: ContinuousClock.Instant?
    @State private var scrolling = LyricsScrolling()
    @State private var sampledLyrics: Sample?

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(width: geometry.size.width, height: geometry.size.height, scale: textSize, topOverflow: topOverflow)
            let samplesPlayback = document.isTimed && playing
            let sample = samplesPlayback ? sampledLyrics ?? playbackSample() : Sample(time: document.isTimed ? playbackTime : 0)
            lyrics(layout: layout, sample: sample)
                .background {
                    if samplesPlayback {
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                            Color.clear.onChange(of: playbackSample(), initial: true) { _, next in sampledLyrics = next }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .onChange(of: samplesPlayback) { _, samplesPlayback in
                    if !samplesPlayback { sampledLyrics = nil }
                }
        }
    }

    private var playbackTime: Double {
        let seconds = position()
        return seconds.isFinite && offset.isFinite ? seconds - offset : 0
    }

    private struct Sample: Equatable {
        let time: Double
        var remainingSeconds: Double?
    }

    private func playbackSample() -> Sample {
        let seconds = playbackTime
        return Sample(time: document.displayTime(at: seconds), remainingSeconds: document.gap(at: seconds).map {
            ($0.end - seconds).rounded(.up)
        })
    }

    private func lyrics(layout: Layout, sample: Sample) -> some View {
        let time = sample.time
        let active = focus(at: time)
        let gapID: Int? = if case .gap(let id) = active { id } else { nil }
        let follow = FollowTarget(
            anchor: userIsScrolling || scrollResumeAt != nil ? nil : active,
            viewport: CGSize(width: layout.width, height: layout.height),
            textSize: layout.textSize
        )
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: layout.spacing - layout.topOverflow) {
                    ForEach(document.lines) { line in
                        if let gap = document.gap(before: line.id), active == .gap(line.id) {
                            countdown(gap, time: time, remainingSeconds: sample.remainingSeconds)
                                .padding(.bottom, layout.topOverflow)
                                .id(Anchor.gap(line.id))
                                .transition(.opacity)
                        }
                        lyricRow(line, layout: layout, time: time, active: active) {
                            userIsScrolling = false
                            scrollResumeAt = nil
                            scrollToFocus(.lyric(line.id), with: reader, layout: layout)
                        }
                        .padding(.bottom, layout.topOverflow)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(LyricsCoordinates.content))
                        } action: { frame in
                            scrolling.lineFrames[line.id] = frame
                        }
                        .onDisappear { scrolling.lineFrames[line.id] = nil }
                        .id(Anchor.lyric(line.id))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: gapID)
                .padding(.horizontal, layout.horizontalInset)
                .padding(.top, document.isTimed ? layout.followTopInset : 0)
                .padding(.bottom, (document.isTimed ? layout.followBottomInset : 0) - layout.topOverflow)
                .frame(maxWidth: layout.maximumWidth)
                .frame(maxWidth: .infinity)
                .coordinateSpace(name: LyricsCoordinates.content)
                .background { LyricsScrollAttachment(scrolling: scrolling) }
            }
            .scrollIndicators(.never, axes: .vertical)
            .scrollClipDisabled(layout.topOverflow > 0)
            .onScrollPhaseChange { previous, phase in
                if phase == .interacting || phase == .decelerating {
                    scrolling.cancel()
                    userIsScrolling = true
                    scrollResumeAt = nil
                } else if phase == .idle && (previous == .interacting || previous == .decelerating) {
                    userIsScrolling = false
                    scrollResumeAt = .now.advanced(by: .seconds(4))
                }
            }
            .onChange(of: follow, initial: true) { previous, next in
                guard let anchor = next.anchor else { return }
                if !reduceMotion, previous.anchor != next.anchor,
                   case .lyric = previous.anchor, case let .lyric(id) = anchor,
                   scrolling.animate(to: id, inset: layout.followTopInset) {
                    return
                }
                scrollToFocus(anchor, with: reader, layout: layout, animated: previous.anchor != next.anchor)
            }
            .onDisappear { scrolling.cancel() }
            .task(id: scrollResumeAt) {
                guard let deadline = scrollResumeAt else { return }
                do {
                    try await ContinuousClock().sleep(until: deadline)
                } catch { return }
                guard !Task.isCancelled, !userIsScrolling, scrollResumeAt == deadline else { return }
                scrollResumeAt = nil
            }
        }
    }

    private func focus(at time: Double) -> Anchor? {
        if let line = document.activeLine(at: time) { return .lyric(line.id) }
        if let gap = document.gap(at: time) { return .gap(gap.nextLineID) }
        return document.lineBeforeShortPause(at: time).map { .lyric($0.id) }
    }

    private func scrollToFocus(_ anchor: Anchor, with reader: ScrollViewProxy, layout: Layout, animated: Bool = true) {
        scrolling.cancel()
        if reduceMotion || !animated {
            reader.scrollTo(anchor, anchor: focusPoint(for: anchor, layout: layout))
        } else {
            withAnimation(.easeInOut(duration: 0.24)) { reader.scrollTo(anchor, anchor: focusPoint(for: anchor, layout: layout)) }
        }
    }

    private func focusPoint(for anchor: Anchor, layout: Layout) -> UnitPoint {
        let rowHeight: CGFloat
        switch anchor {
        case let .lyric(id): rowHeight = scrolling.lineFrames[id]?.height ?? layout.textSize * 1.2 + layout.topOverflow
        case .gap: rowHeight = 28 + layout.topOverflow
        }
        return UnitPoint(x: 0, y: min(1, layout.followTopInset / max(1, layout.height - rowHeight)))
    }

    private func countdown(_ gap: LyricsGap, time: Double, remainingSeconds: Double?) -> some View {
        let duration = gap.end - gap.start
        let seconds = countdownSeconds(remainingSeconds ?? gap.end - time)
        let label = countdownLabel(seconds)
            .frame(maxWidth: .infinity, alignment: .leading)

        return countdownLabel(countdownSeconds(duration))
            .hidden()
            .overlay(alignment: .leading) {
                label
                    .foregroundStyle(.secondary)
                    .overlay {
                        if !reduceMotion {
                            label
                                .foregroundStyle(.primary)
                                .mask {
                                    TimelineView(.animation(paused: !playing)) { _ in
                                        let now = playing ? playbackTime : time
                                        let progress = min(1, max(0, (now - gap.start) / duration))
                                        countdownMask(progress)
                                    }
                                }
                                .accessibilityHidden(true)
                            }
                    }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Instrumental break")
            .accessibilityValue("\(seconds) seconds until the next line")
    }

    private func countdownSeconds(_ duration: Double) -> String {
        max(1, duration.rounded(.up)).formatted(.number.precision(.fractionLength(0)))
    }

    private func countdownLabel(_ seconds: String) -> some View {
        Label("Instrumental · \(seconds)s", systemImage: "music.note")
            .font(.callout.weight(.semibold))
            .monospacedDigit()
    }

    private func countdownMask(_ progress: Double) -> some View {
        GeometryReader { geometry in
            let feather = min(6, geometry.size.width)
            let span = geometry.size.width + feather
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: feather)
            }
            .frame(width: span)
            .offset(x: span * (progress - 1))
        }
    }

    @ViewBuilder
    private func lyricRow(
        _ line: LyricsLine, layout: Layout, time: Double, active: Anchor?, recenter: @escaping () -> Void
    ) -> some View {
        let singing = line.start.map { $0 <= time && time < (line.end ?? .infinity) } ?? false
        let deEmphasized = active != nil && !singing && active != .lyric(line.id)
        let text = LyricText(
            line: line, layout: layout, time: singing ? wordBoundary(in: line, at: time) : -.infinity,
            timed: document.isTimed, singing: singing, deEmphasized: deEmphasized,
            soften: deEmphasized && blur && !reduceMotion && contrast != .increased, reduceMotion: reduceMotion
        )
        .equatable()
        if let start = line.start {
            Button {
                seek(max(0, start + (offset.isFinite ? offset : 0)))
                recenter()
            } label: {
                text.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(singing ? .isSelected : [])
            .accessibilityHint(line.isBackground ? "Backing vocals. Seeks to this line." : "Seeks to this line.")
        } else {
            text.textSelection(.enabled)
        }
    }

    private func wordBoundary(in line: LyricsLine, at time: Double) -> Double {
        var latest = -Double.infinity
        for words in [line.words, line.pronunciationWords, line.translationWords] {
            for word in words {
                if word.start <= time { latest = max(latest, word.start) }
                if let end = word.end, end <= time { latest = max(latest, end) }
            }
        }
        return latest
    }

    private struct LyricText: View, Equatable {
        let line: LyricsLine
        let layout: Layout
        let time: Double
        let timed: Bool
        let singing: Bool
        let deEmphasized: Bool
        let soften: Bool
        let reduceMotion: Bool

        var body: some View {
            let emphasisAnimation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.24)
            VStack(alignment: .leading, spacing: layout.auxiliarySpacing) {
                if let pronunciation = line.pronunciation {
                    highlighted(pronunciation, words: line.pronunciationWords)
                        .font(.system(size: layout.auxiliarySize, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                highlighted(line.text, words: line.words)
                    .font(.system(size: layout.textSize * (line.isBackground ? 0.86 : 1), weight: timed ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .animation(emphasisAnimation) { text in
                        text.opacity(deEmphasized ? 0.5 : 1)
                    }
                if let translation = line.translation {
                    highlighted(translation, words: line.translationWords)
                        .font(.system(size: layout.auxiliarySize))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, line.isBackground ? 16 : 0)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(emphasisAnimation) { row in
                row.blur(radius: soften ? 0.65 : 0)
            }
            .accessibilityElement(children: .combine)
        }

        private func highlighted(_ text: String, words: [LyricsWord]) -> Text {
            guard singing, !words.isEmpty else { return Text(verbatim: text) }
            var value = AttributedString(text)
            let count = value.characters.count
            value.foregroundColor = Color.secondary
            for word in words where (word.end ?? .infinity) <= time {
                color(.primary, range: word.range, count: count, in: &value)
            }
            for word in words where word.isActive(at: time) {
                color(.accentColor, range: word.range, count: count, in: &value)
            }
            return Text(value)
        }

        private func color(_ color: Color, range: Range<Int>, count: Int, in text: inout AttributedString) {
            guard range.lowerBound >= 0, range.upperBound <= count else { return }
            let start = text.characters.index(text.startIndex, offsetBy: range.lowerBound)
            let end = text.characters.index(start, offsetBy: range.count)
            text[start..<end].foregroundColor = color
        }
    }

    private enum Anchor: Hashable {
        case lyric(Int)
        case gap(Int)
    }

    private enum LyricsCoordinates { case content }

    private struct FollowTarget: Equatable {
        let anchor: Anchor?
        let viewport: CGSize
        let textSize: Double
    }

    private struct Layout: Equatable {
        let width: Double
        let height: Double
        let scale: Double
        let topOverflow: Double

        private var wide: Bool { width >= 500 }
        private var safeScale: Double { scale.isFinite ? min(1.4, max(0.8, scale)) : 1 }

        var textSize: Double { (wide ? 30 : 21) * safeScale }
        var auxiliarySize: Double { (wide ? 16 : 13) * safeScale }
        var auxiliarySpacing: Double { wide ? 5 : 3 }
        var spacing: Double { wide ? 22 : 15 }
        var horizontalInset: Double { wide ? 44 : 22 }
        var maximumWidth: Double { wide ? 750 : .infinity }

        var followTopInset: Double { max(0, (height + topOverflow) * 0.36 - topOverflow) }
        var followBottomInset: Double { height - followTopInset }
    }
}

@MainActor
private final class LyricsScrolling {
    weak var scrollView: NSScrollView?
    var lineFrames: [Int: CGRect] = [:]
    private var scrollTask: Task<Void, Never>?

    func animate(to id: Int, inset: CGFloat) -> Bool {
        guard let scrollView, let frame = lineFrames[id] else { return false }
        let clip = scrollView.contentView
        let origin = clip.bounds.origin
        let requested = CGRect(origin: CGPoint(x: origin.x, y: frame.minY - inset), size: clip.bounds.size)
        let destination = clip.constrainBoundsRect(requested).origin
        guard abs(destination.y - origin.y) < clip.bounds.height else { return false }

        cancel()
        if abs(destination.y - origin.y) < 0.5 { return true }
        scrollTask = Task { @MainActor [weak scrollView] in
            let start = ProcessInfo.processInfo.systemUptime
            let duration = 0.24
            while !Task.isCancelled, let scrollView {
                let time = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
                let fraction = time * time * (3 - 2 * time)
                let offset = origin.y + (destination.y - origin.y) * fraction
                let clip = scrollView.contentView
                clip.scroll(to: CGPoint(x: origin.x, y: offset))
                scrollView.reflectScrolledClipView(clip)
                if time == 1 { return }
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
        }
        return true
    }

    func cancel() {
        scrollTask?.cancel()
        scrollTask = nil
    }
}

private struct LyricsScrollAttachment: NSViewRepresentable {
    let scrolling: LyricsScrolling

    func makeNSView(context: Context) -> NSView { Attachment(scrolling) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Attachment: NSView {
        let scrolling: LyricsScrolling

        init(_ scrolling: LyricsScrolling) {
            self.scrolling = scrolling
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scrolling.scrollView = window == nil ? nil : enclosingScrollView
        }
    }
}
