import AppKit
import QuartzCore
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
        let hasLeadingGap = document.lines.prefix(2).contains { document.gap(before: $0.id) != nil }
        let topInset = layout.followTopInset + (hasLeadingGap ? Layout.countdownHeight + layout.spacing : 0)
        let follow = FollowTarget(
            anchor: userIsScrolling || scrollResumeAt != nil ? nil : active,
            viewport: CGSize(width: layout.width, height: layout.height),
            inset: layout.followTopInset,
            textSize: layout.textSize
        )
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.lines) { line in
                        if let gap = document.gap(before: line.id), active == .gap(line.id) {
                            followGuide(for: .gap(line.id))
                            countdown(gap, time: time, remainingSeconds: sample.remainingSeconds)
                                .frame(height: Layout.countdownHeight)
                                .padding(.bottom, layout.topOverflow)
                                .padding(.bottom, layout.spacing - layout.topOverflow)
                                .id(Anchor.gap(line.id))
                                .transition(.opacity.animation(reduceMotion ? nil : .easeInOut(duration: 0.24)))
                        }
                        if document.isTimed { followGuide(for: .lyric(line.id)) }
                        lyricRow(line, layout: layout, time: time, active: active) {
                            userIsScrolling = false
                            scrollResumeAt = nil
                            if playing { sampledLyrics = playbackSample() }
                            requestScroll(.lyric(line.id), with: reader, layout: layout, animated: !reduceMotion)
                        }
                        .padding(.bottom, layout.topOverflow)
                        .padding(.bottom, line.id == document.lines.last?.id ? 0 : layout.spacing - layout.topOverflow)
                        .id(Anchor.lyric(line.id))
                    }
                }
                .padding(.horizontal, layout.horizontalInset)
                .padding(.top, document.isTimed ? topInset : 0)
                .padding(.bottom, (document.isTimed ? layout.followBottomInset : 0) - layout.topOverflow)
                .frame(maxWidth: layout.maximumWidth)
                .frame(maxWidth: .infinity)
                .coordinateSpace(name: LyricsCoordinates.content)
                .background { LyricsScrollAttachment(scrolling: scrolling) }
            }
            .scrollIndicators(.never, axes: .vertical)
            .scrollClipDisabled(layout.topOverflow > 0)
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { notification in
                guard scrolling.owns(notification) else { return }
                scrolling.cancel()
                userIsScrolling = true
                scrollResumeAt = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didLiveScrollNotification)) { notification in
                guard scrolling.owns(notification) else { return }
                scrolling.cancel()
                if !userIsScrolling { scrollResumeAt = .now.advanced(by: .seconds(4)) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didEndLiveScrollNotification)) { notification in
                guard scrolling.owns(notification) else { return }
                userIsScrolling = false
                scrollResumeAt = .now.advanced(by: .seconds(4))
            }
            .onChange(of: follow, initial: true) { previous, next in
                guard let anchor = next.anchor else { return }
                let animate = !reduceMotion && previous.anchor != next.anchor
                let removedGap: CGFloat
                if animate, case let .lyric(id) = anchor, previous.anchor == .gap(id) {
                    removedGap = Layout.countdownHeight + layout.spacing
                } else {
                    removedGap = 0
                }
                requestScroll(anchor, with: reader, layout: layout, animated: animate, removedGap: removedGap)
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

    private func requestScroll(
        _ anchor: Anchor, with reader: ScrollViewProxy, layout: Layout, animated: Bool, removedGap: CGFloat = 0
    ) {
        scrolling.move(to: anchor, inset: layout.followTopInset, animated: animated, removedGap: removedGap) {
            let fraction = layout.followTopInset / max(1, layout.height)
            reader.scrollTo(FollowGuideID(anchor: anchor), anchor: UnitPoint(x: 0, y: fraction))
        }
    }

    private struct FollowGuideID: Hashable {
        let anchor: Anchor
    }

    private func followGuide(for anchor: Anchor) -> some View {
        Color.clear.frame(height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(LyricsCoordinates.content)).minY
            } action: { position in
                scrolling.record(position, for: anchor)
            }
            .onDisappear { scrolling.positions[anchor] = nil }
            .id(FollowGuideID(anchor: anchor))
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
        if let start = line.start {
            LyricButton(text: text) {
                seek(max(0, start + (offset.isFinite ? offset : 0)))
                recenter()
            }
        } else {
            text.equatable().textSelection(.enabled)
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

    private struct LyricButton: View {
        let text: LyricText
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                label.equatable().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(text.singing ? .isSelected : [])
            .accessibilityHint(text.line.isBackground ? "Backing vocals. Seeks to this line." : "Seeks to this line.")
        }

        private var label: LyricText {
            var label = text
            label.hovered = hovered
            return label
        }
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
        var hovered = false

        var body: some View {
            let emphasisAnimation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.24)
            let opacity = deEmphasized ? (hovered ? 0.75 : 0.5) : 1
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
                        text.opacity(opacity)
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

    fileprivate enum Anchor: Hashable {
        case lyric(Int)
        case gap(Int)
    }

    private enum LyricsCoordinates { case content }

    private struct FollowTarget: Equatable {
        let anchor: Anchor?
        let viewport: CGSize
        let inset: CGFloat
        let textSize: Double
    }

    private struct Layout: Equatable {
        static let countdownHeight: CGFloat = 28
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
private final class LyricsScrolling: NSObject {
    var positions: [LyricsPanel.Anchor: CGFloat] = [:]
    private(set) weak var scrollView: NSScrollView?
    private var motion: Motion?
    private var displayLink: CADisplayLink?

    private struct Motion {
        let target: LyricsPanel.Anchor
        let inset: CGFloat
        let animated: Bool
        let reveal: () -> Void
        let requestedAt = CACurrentMediaTime()
        var revealedAt: Double?
        var start: (position: CGFloat, time: Double)?
    }

    func record(_ position: CGFloat, for anchor: LyricsPanel.Anchor) {
        positions[anchor] = position
        guard let motion, motion.target == anchor, let revealedAt = motion.revealedAt else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.motion?.revealedAt == revealedAt else { return }
            self.advance(at: CACurrentMediaTime())
        }
    }

    func attach(to scrollView: NSScrollView?) {
        if scrollView == nil {
            cancel()
        }
        self.scrollView = scrollView
        startDisplayLink()
    }

    func owns(_ notification: Notification) -> Bool {
        guard let scrollView else { return false }
        return notification.object as? NSScrollView === scrollView
    }

    func move(to target: LyricsPanel.Anchor, inset: CGFloat, animated: Bool, removedGap: CGFloat, reveal: @escaping () -> Void) {
        if motion?.target == target, motion?.inset == inset { return }
        if removedGap > 0, let scrollView {
            scroll(scrollView, to: scrollView.contentView.bounds.minY - removedGap)
        }
        motion = Motion(target: target, inset: inset, animated: animated, reveal: reveal)
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard let scrollView, motion != nil, displayLink == nil else { return }
        let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        advance(at: link.targetTimestamp)
    }

    private func advance(at time: Double) {
        guard var motion, let scrollView else { return }
        guard let target = positions[motion.target] else {
            if let revealedAt = motion.revealedAt {
                if time - revealedAt >= 0.24 { cancel() }
            } else {
                motion.revealedAt = time
                self.motion = motion
                motion.reveal()
            }
            return
        }

        let clip = scrollView.contentView
        let origin = clip.bounds.origin
        let requestedPosition = target - origin.y
        let position = motion.start?.position ?? requestedPosition
        let startedAt = motion.start?.time ?? min(time, motion.requestedAt)
        let duration = 0.24
        let animate = motion.animated && motion.revealedAt == nil && abs(position - motion.inset) >= 0.5
        let progress = animate ? min(1, max(0, (time - startedAt) / duration)) : 1
        let fraction = progress * progress * (3 - 2 * progress)
        let visualY = position + (motion.inset - position) * fraction
        scroll(scrollView, to: target - visualY)
        if progress == 1 {
            cancel()
        } else {
            motion.start = (position, startedAt)
            self.motion = motion
        }
    }

    private func scroll(_ scrollView: NSScrollView, to y: CGFloat) {
        let clip = scrollView.contentView
        let origin = clip.bounds.origin
        let requested = CGRect(origin: CGPoint(x: origin.x, y: y), size: clip.bounds.size)
        let destination = clip.constrainBoundsRect(requested).origin
        if destination != origin {
            clip.scroll(to: destination)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        motion = nil
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
            scrolling.attach(to: window == nil ? nil : enclosingScrollView)
        }
    }
}
