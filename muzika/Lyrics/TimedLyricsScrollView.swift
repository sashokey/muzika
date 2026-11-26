import AppKit
import QuartzCore

struct TimedLyricsConfiguration {
    let document: LyricsDocument
    let position: @MainActor () -> Double
    let pausedPosition: Double?
    let playing: Bool
    let offset: Double
    let textSize: Double
    let blur: Bool
    let reduceMotion: Bool
    let topOverflow: CGFloat
    let seek: @MainActor (Double) -> Void
    var duration: Double? = nil
    var animatesWordHighlighting = true
}

@MainActor
final class TimedLyricsScrollView: NSScrollView {
    private let canvas = LyricsCanvas()
    private let tiles = CALayer()
    private let countdown = LyricsCountdownLayer()
    private var configuration: TimedLyricsConfiguration?
    private var geometry: LyricsScrollGeometry?
    private var measuredTypography: LyricsTypography?
    private var requestedTypography: LyricsTypography?
    private var layoutTask: Task<Void, Never>?
    private var blockHeights: [[CGFloat]] = []
    private var rowByID: [Int: Int] = [:]
    private var rowLayers: [Int: LyricsRowLayer] = [:]
    private var cachedBounds: Range<CGFloat>?
    private var deviceScale: CGFloat = 1
    private var layoutViewportHeight: CGFloat?
    private var layoutOverflow: CGFloat?
    private var hover: Int?
    private var accessibilityRows: [LyricsAccessibilityRow]?
    private var accessibilityCountdown: LyricsAccessibilityRow?
    private var time = -Double.greatestFiniteMagnitude
    private var accentPosition: Double?
    private var accentMotion: LyricsAccentMotion = .paused
    private var focus: Focus?
    private var activeGap: LyricsGap?
    private var manualUntil: CFTimeInterval?
    private var liveScrolling = false
    private var ticker: Timer?
    private var displayLink: CADisplayLink?
    #if MUZIKA_DEV_LOGS
    private var progressFrames = MuzikaFrameMetrics()
    #endif
    private var motion: Motion?
    private var motionID: UInt64 = 0
    private var gapExitID: UUID?
    private static let cueDuration: CFTimeInterval = 0.24
    private static let scrollAnimationKey = "lyrics-scroll"
    private static let rowStaggerKey = "lyrics-row-stagger"
    private static let countdownFadeKey = "lyrics-countdown-fade"
    private static let gapPositionKey = "lyrics-gap-position"

    private enum Focus: Equatable {
        case row(Int)
        case gap(Int)
    }

    private struct Motion {
        let id: UInt64
        let from: CGFloat
        let to: CGFloat
        let staggered: Bool
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        automaticallyAdjustsContentInsets = false
        horizontalScrollElasticity = .none
        canvas.owner = self
        canvas.wantsLayer = true
        canvas.layer?.addSublayer(tiles)
        documentView = canvas
        contentView.postsBoundsChangedNotifications = true
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        notifications.addObserver(self, selector: #selector(beginLiveScroll), name: NSScrollView.willStartLiveScrollNotification, object: self)
        notifications.addObserver(self, selector: #selector(endLiveScroll), name: NSScrollView.didEndLiveScrollNotification, object: self)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        layoutTask?.cancel()
        ticker?.invalidate()
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func configure(_ next: TimedLyricsConfiguration) {
        let old = configuration
        configuration = next
        if old?.document != next.document {
            #if MUZIKA_DEV_LOGS
            MuzikaTrace.event(.lyrics, "timed.document", "lines=\(next.document.lines.count) size=\(next.textSize) blur=\(next.blur) offset_s=\(next.offset) reduce_motion=\(next.reduceMotion)")
            #endif
            rowByID = Dictionary(next.document.lines.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            layoutTask?.cancel()
            requestedTypography = nil
            measuredTypography = nil
            layoutViewportHeight = nil
            geometry = nil
            blockHeights = []
            accessibilityRows = nil
            accessibilityCountdown = nil
            focus = nil
            time = -Double.greatestFiniteMagnitude
            accentPosition = nil
            accentMotion = .paused
            activeGap = nil
            hover = nil
            stopMotion(keepingPosition: false)
            manualUntil = nil
            liveScrolling = false
            clearGapExit()
            countdown.layer.removeFromSuperlayer()
            clearLayers()
        } else if old?.blur != next.blur {
            clearLayers()
        }
        if next.reduceMotion {
            clearGapExit()
            for row in rowLayers.values { row.layer.removeAnimation(forKey: Self.rowStaggerKey) }
        }
        let clips = next.topOverflow <= 0
        if clipsToBounds != clips { clipsToBounds = clips }
        if contentView.clipsToBounds != clips { contentView.clipsToBounds = clips }
        updateLayout()
        updateCue(force: old?.offset != next.offset || old?.reduceMotion != next.reduceMotion || old?.duration != next.duration)
        if next.reduceMotion, motion != nil {
            center(animated: false)
        }
        reconcileRows()
        updateClocks()
    }

    override func layout() {
        super.layout()
        updateLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let motion { finishMotion(id: motion.id) }
            clearGapExit()
        }
        updateDeviceScale()
        updateClocks()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDeviceScale()
    }

    override func tile() {
        super.tile()
        if let configuration {
            contentView.clipsToBounds = configuration.topOverflow <= 0
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 { holdFollowing() }
        super.scrollWheel(with: event)
    }

    func stop() {
        #if MUZIKA_DEV_LOGS
        if displayLink != nil { MuzikaTrace.event(.lyrics, "progress.clock.detached", progressFrames.summary) }
        #endif
        ticker?.invalidate()
        ticker = nil
        stopMotion(keepingPosition: false)
        clearGapExit()
        displayLink?.invalidate()
        displayLink = nil
        layoutTask?.cancel()
        layoutTask = nil
        requestedTypography = measuredTypography
        configuration = nil
    }

    private func updateDeviceScale() {
        let next = window?.backingScaleFactor ?? 1
        guard next != deviceScale else { return }
        deviceScale = next
        clearLayers()
        reconcileRows()
        updateCountdown()
    }

    private func updateLayout() {
        guard let configuration, contentSize.width > 0, contentSize.height > 0 else { return }
        let typography = LyricsTypography(width: contentSize.width, scale: configuration.textSize)
        if typography == measuredTypography {
            if requestedTypography != typography {
                layoutTask?.cancel()
                requestedTypography = typography
            }
            if layoutViewportHeight != contentSize.height || layoutOverflow != configuration.topOverflow {
                rebuildGeometry()
            }
            return
        }
        guard typography != requestedTypography else { return }
        requestedTypography = typography
        layoutTask?.cancel()
        let lines = configuration.document.lines
        #if MUZIKA_DEV_LOGS
        let layoutStarted = CACurrentMediaTime()
        MuzikaTrace.event(.lyrics, "layout.begin", "lines=\(lines.count) width_pt=\(typography.textWidth) viewport_pt=\(contentSize.height)")
        #endif
        let job = Task.detached(priority: .userInitiated) {
            var heights: [[CGFloat]] = []
            heights.reserveCapacity(lines.count)
            for line in lines {
                if Task.isCancelled { return [] as [[CGFloat]] }
                let width = max(1, typography.textWidth - (line.isBackground ? 16 : 0))
                heights.append(typography.blocks(for: line).map { $0.height(at: width) })
            }
            return heights
        }
        layoutTask = Task { [weak self] in
            let heights = await withTaskCancellationHandler {
                await job.value
            } onCancel: {
                job.cancel()
            }
            guard !Task.isCancelled, let self, requestedTypography == typography else { return }
            #if MUZIKA_DEV_LOGS
            MuzikaTrace.event(.lyrics, "layout.ready", "rows=\(heights.count) elapsed_ms=\(((CACurrentMediaTime() - layoutStarted) * 1000).rounded())")
            #endif
            measuredTypography = typography
            blockHeights = heights
            clearLayers()
            rebuildGeometry()
            updateCue(force: true)
        }
    }

    private func rebuildGeometry() {
        guard let configuration, let typography = measuredTypography else { return }
        stopMotion(keepingPosition: true)
        clearGapExit()
        let viewport = contentSize.height
        let old = geometry
        let oldOffset = contentView.bounds.minY
        let geometry = LyricsScrollGeometry(
            heights: blockHeights.map { heights in
                heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * typography.auxiliarySpacing
            },
            spacing: typography.spacing, viewportHeight: viewport, topOverflow: configuration.topOverflow,
            hasLeadingGap: configuration.document.lines.prefix(2).contains { configuration.document.gap(before: $0.id) != nil }
        )
        self.geometry = geometry
        layoutViewportHeight = viewport
        layoutOverflow = configuration.topOverflow
        syncDocumentFrame()
        if manualUntil != nil || liveScrolling {
            scroll(to: oldOffset + geometry.anchor - (old?.anchor ?? geometry.anchor))
        } else {
            center(animated: false)
        }
        reconcileRows(force: true)
        updateCountdown()
        updateClocks()
    }

    private var gapIndex: Int? {
        if case .gap(let index) = focus { return index }
        return nil
    }

    private func syncDocumentFrame() {
        guard let geometry else { return }
        let size = CGSize(width: contentSize.width, height: geometry.contentHeight(gapBefore: gapIndex))
        if canvas.frame.size != size { canvas.setFrameSize(size) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiles.frame = canvas.bounds
        CATransaction.commit()
        cachedBounds = nil
    }

    private func clearLayers() {
        rowLayers.values.forEach { $0.layer.removeFromSuperlayer() }
        rowLayers.removeAll()
        cachedBounds = nil
    }

    @objc private func boundsChanged() {
        if let motion, contentView.bounds.minY != motion.from {
            stopMotion(keepingPosition: false)
        }
        reconcileRows()
    }

    private func reconcileRows(force: Bool = false) {
        guard let geometry, let typography = measuredTypography, let configuration else { return }
        let viewport = contentView.bounds
        let overflow = max(0, configuration.topOverflow)
        let destination = motion?.to ?? viewport.minY
        let minY = min(viewport.minY, destination) - overflow
        let maxY = max(viewport.minY, destination) + viewport.height
        if !force, let cachedBounds, cachedBounds.lowerBound <= minY,
           cachedBounds.upperBound >= maxY { return }
        let reserve = max(80, viewport.height * 0.5)
        let range = (minY - reserve)..<(maxY + reserve)
        cachedBounds = range
        let visible = geometry.rows(in: range, gapBefore: gapIndex)
        let x = (canvas.bounds.width - typography.containerWidth) / 2 + typography.horizontalInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for index in Array(rowLayers.keys) where !visible.contains(index) {
            rowLayers.removeValue(forKey: index)?.layer.removeFromSuperlayer()
        }
        for index in visible {
            let row: LyricsRowLayer
            if let existing = rowLayers[index] {
                row = existing
            } else {
                row = LyricsRowLayer(line: configuration.document.lines[index], typography: typography,
                                     heights: blockHeights[index], deviceScale: deviceScale, blur: configuration.blur)
                rowLayers[index] = row
                tiles.addSublayer(row.layer)
                updateRow(index, animated: false)
            }
            row.layer.frame.origin = CGPoint(x: x, y: geometry.y(forRow: index, gapBefore: gapIndex))
        }
    }

    private var audioTime: Double {
        guard let configuration else { return 0 }
        let position = configuration.pausedPosition ?? configuration.position()
        return position.isFinite && configuration.offset.isFinite ? position - configuration.offset : 0
    }

    private func updateCue(force: Bool = false, at overrideTime: Double? = nil) {
        guard let configuration, let geometry else { return }
        let now = overrideTime ?? audioTime
        let delta = accentPosition.map { now - $0 }
        let isAdvancing = configuration.playing && delta != 0
        let motion: LyricsAccentMotion = configuration.reduceMotion || !configuration.animatesWordHighlighting
            ? .reduced : (isAdvancing ? .playing : .paused)
        let reposition = force || (delta.map { $0 < 0 || $0 > 0.12 } ?? false)
        let refreshAccents = reposition || motion != accentMotion || (motion == .paused && delta != 0)
        accentPosition = now
        accentMotion = motion
        let next = configuration.document.displayTime(at: now)
        if next == time && !force {
            if activeGap != nil { updateCountdown(at: now) }
            fillingRow?.paintLineFill(at: now)
            if refreshAccents {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for row in rowLayers.values {
                    row.paintAccents(at: now, motion: motion, reposition: reposition)
                }
                CATransaction.commit()
            }
            return
        }
        let previous = focus
        time = next
        let active = configuration.document.activeLine(at: next)
        activeGap = active == nil ? configuration.document.gap(at: now) : nil
        if let active, let row = rowByID[active.id] {
            focus = .row(row)
        } else if let gap = activeGap, let row = rowByID[gap.nextLineID] {
            focus = .gap(row)
        } else if let prior = configuration.document.lineBeforeShortPause(at: next), let row = rowByID[prior.id] {
            focus = .row(row)
        } else {
            focus = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if previous != focus {
            #if MUZIKA_DEV_LOGS
            MuzikaTrace.event(.lyrics, "cue.changed", "from=\(String(describing: previous)) to=\(String(describing: focus)) time_s=\(now) instrumental=\(activeGap != nil) discontinuity=\(reposition) manual=\(manualUntil != nil || liveScrolling)")
            #endif
            let precedingGap: Int?
            if case .gap(let index) = previous { precedingGap = index } else { precedingGap = nil }
            let following = manualUntil == nil && !liveScrolling
            var gapExit: (row: Int, oldOffset: CGFloat)?
            if precedingGap != gapIndex {
                clearGapExit()
                stopMotion(keepingPosition: true)
                let oldOffset = contentView.bounds.minY
                syncDocumentFrame()
                if let precedingGap, focus == .row(precedingGap) {
                    if following || oldOffset >= geometry.y(forGapBefore: precedingGap) {
                        scroll(to: oldOffset - geometry.gapExtent)
                    }
                    gapExit = (precedingGap, oldOffset)
                }
                reconcileRows(force: true)
            }
            if following {
                let staggerFrom: Int?
                if !reposition, isAdvancing, !configuration.reduceMotion, case .row = previous, case .row(let row) = focus {
                    staggerFrom = row
                } else {
                    staggerFrom = nil
                }
                center(animated: previous != nil && !configuration.reduceMotion, staggerFrom: staggerFrom)
            }
            if let gapExit, !configuration.reduceMotion, window != nil {
                animateGapExit(before: gapExit.row, offsetChange: contentView.bounds.minY - gapExit.oldOffset,
                               extent: geometry.gapExtent)
            }
        }
        for row in rowLayers.keys {
            updateRow(row, animated: !force && !configuration.reduceMotion, repositionAccents: reposition)
        }
        updateCountdown(at: now)
        CATransaction.commit()
        updateClocks()
    }

    private func animateGapExit(before index: Int, offsetChange: CGFloat, extent: CGFloat) {
        let id = UUID()
        gapExitID = id
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.lyrics, "instrumental.fade.begin", "row=\(index) offset_pt=\(offsetChange) extent_pt=\(extent) duration_s=\(Self.cueDuration)")
        #endif
        countdown.layer.frame.origin.y += offsetChange
        countdown.layer.opacity = 0
        countdown.layer.add(cueAnimation("opacity", from: 1, to: 0), forKey: Self.countdownFadeKey)
        for (rowIndex, row) in rowLayers {
            let shift = offsetChange + (rowIndex < index ? 0 : extent)
            guard shift != 0 else { continue }
            let y = row.layer.position.y
            row.layer.add(cueAnimation("position.y", from: y + shift, to: y), forKey: Self.gapPositionKey)
        }
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gapExitID == id else { return }
                #if MUZIKA_DEV_LOGS
                MuzikaTrace.event(.lyrics, "instrumental.fade.complete")
                #endif
                clearGapExit()
            }
        }
    }

    private func clearGapExit() {
        guard gapExitID != nil else { return }
        gapExitID = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        countdown.layer.removeFromSuperlayer()
        countdown.layer.removeAnimation(forKey: Self.countdownFadeKey)
        countdown.layer.opacity = 1
        for row in rowLayers.values { row.layer.removeAnimation(forKey: Self.gapPositionKey) }
        CATransaction.commit()
    }

    private func updateRow(_ index: Int, animated: Bool, repositionAccents: Bool = false) {
        guard let configuration, let row = rowLayers[index] else { return }
        let line = configuration.document.lines[index]
        let singing = isSinging(line)
        let dimmed = focus != .row(index) && !singing
        let hasWords = !line.words.isEmpty || !line.pronunciationWords.isEmpty || !line.translationWords.isEmpty
        let fillInterval = singing && focus == .row(index) && !configuration.reduceMotion && line.words.isEmpty
            ? configuration.document.fillInterval(for: line, until: configuration.duration.map { $0 - configuration.offset })
            : nil
        row.update(LyricsRowLayer.Appearance(singing: singing, dimmed: dimmed, idleOpacity: idleOpacity(for: index),
                                             hovered: hover == index,
                                             softened: dimmed && configuration.blur,
                                             wordTime: singing && hasWords ? time : -.infinity,
                                             fillInterval: fillInterval), animated: animated)
        if singing, hasWords {
            row.paintAccents(at: accentPosition ?? time, motion: accentMotion, reposition: repositionAccents)
        }
        row.paintLineFill(at: accentPosition ?? time)
    }

    private func idleOpacity(for index: Int) -> Float {
        guard case .row(let current) = focus else { return 0.5 }
        switch abs(index - current) {
        case 0...1: return 0.5
        case 2: return 0.46
        default: return 0.42
        }
    }

    private func isSinging(_ line: LyricsLine) -> Bool {
        line.start.map { $0 <= time && time < (line.end ?? .infinity) } ?? false
    }

    private func updateCountdown(at seconds: Double? = nil) {
        guard let configuration, let geometry, let typography = measuredTypography, let gap = activeGap, let index = gapIndex else {
            if gapExitID == nil { countdown.layer.removeFromSuperlayer() }
            return
        }
        let x = (canvas.bounds.width - typography.containerWidth) / 2 + typography.horizontalInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if countdown.layer.superlayer == nil { tiles.addSublayer(countdown.layer) }
        countdown.layer.frame.origin = CGPoint(x: x, y: geometry.y(forGapBefore: index))
        countdown.update(gap: gap, at: seconds ?? audioTime, scale: deviceScale, reduceMotion: configuration.reduceMotion)
        CATransaction.commit()
    }

    private func center(animated: Bool, staggerFrom: Int? = nil) {
        guard let focus, let geometry else { return }
        let target: CGFloat
        switch focus {
        case .row(let row): target = geometry.offset(forRow: row, gapBefore: gapIndex)
        case .gap(let row): target = geometry.offset(forGapBefore: row)
        }
        let end = constrainedOffset(target)
        if animated, motion?.to == end { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        stopMotion(keepingPosition: true)
        let start = contentView.bounds.minY
        guard animated, window != nil, abs(start - end) >= 0.5, abs(start - end) <= contentSize.height else {
            scroll(to: end)
            return
        }

        motionID &+= 1
        let id = motionID
        motion = Motion(id: id, from: start, to: end, staggered: staggerFrom != nil)
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.lyrics, "scroll.animation.begin", "id=\(id) from_pt=\(start) to_pt=\(end) stagger=\(staggerFrom != nil) duration_s=\(staggerFrom == nil ? Self.cueDuration : 0.34)")
        #endif
        reconcileRows()

        let animation = cueAnimation("transform.translation.y", from: 0, to: start - end)
        if let staggerFrom {
            animation.duration = 0.34
            staggerRows(after: staggerFrom, distance: end - start, duration: animation.duration)
        }
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in self?.finishMotion(id: id) }
        }
        tiles.add(animation, forKey: Self.scrollAnimationKey)
    }

    private func staggerRows(after anchor: Int, distance: CGFloat, duration: CFTimeInterval) {
        let direction = distance > 0 ? 1 : -1
        let step = min(abs(distance) * 0.10, 5) * CGFloat(direction)
        for (index, row) in rowLayers {
            let lag = min(max((index - anchor) * direction, 0), 4)
            let start = row.layer.presentation()?.transform.m42 ?? 0
            guard lag > 0 || start != 0 else { continue }
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            animation.values = [start, step * CGFloat(lag), 0]
            animation.keyTimes = [0, 0.45, 1]
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            animation.duration = duration
            row.layer.add(animation, forKey: Self.rowStaggerKey)
        }
    }

    private func cueAnimation(_ keyPath: String, from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = Self.cueDuration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 1 / 3.0, 0, 2 / 3.0, 1)
        return animation
    }

    private var displayedTranslation: CGFloat {
        guard motion != nil else { return 0 }
        return tiles.presentation()?.transform.m42 ?? 0
    }

    private func stopMotion(keepingPosition: Bool) {
        guard motion != nil else { return }
        let position = contentView.bounds.minY - displayedTranslation
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.lyrics, "scroll.animation.stop", "keep_position=\(keepingPosition) presented_pt=\(position)")
        #endif
        motion = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiles.removeAnimation(forKey: Self.scrollAnimationKey)
        if keepingPosition { scroll(to: position) }
        CATransaction.commit()
    }

    private func finishMotion(id: UInt64) {
        guard let motion, motion.id == id else { return }
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.lyrics, "scroll.animation.complete", "id=\(id) target_pt=\(motion.to)")
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopMotion(keepingPosition: false)
        scroll(to: motion.to)
        CATransaction.commit()
    }

    private func constrainedOffset(_ y: CGFloat) -> CGFloat {
        let clip = contentView
        let proposed = CGRect(origin: CGPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)
        return clip.constrainBoundsRect(proposed).origin.y
    }

    private func scroll(to y: CGFloat) {
        let clip = contentView
        let target = constrainedOffset(y)
        if target != clip.bounds.minY {
            clip.scroll(to: CGPoint(x: clip.bounds.minX, y: target))
            reflectScrolledClipView(clip)
        }
    }

    @objc private func beginLiveScroll() {
        liveScrolling = true
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.lyrics, "timed.manual.begin", "offset_pt=\(contentView.bounds.minY)")
        #endif
        holdFollowing()
    }

    @objc private func endLiveScroll() {
        liveScrolling = false
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.lyrics, "timed.manual.end", "resume_delay_s=\(LyricsScrollTiming.manualHold)")
        #endif
        holdFollowing()
    }

    private func holdFollowing() {
        stopMotion(keepingPosition: true)
        manualUntil = CACurrentMediaTime() + LyricsScrollTiming.manualHold
        updateClocks()
    }

    private var fillingRow: LyricsRowLayer? {
        guard case .row(let index) = focus, let row = rowLayers[index], row.hasLineFill else { return nil }
        return row
    }

    private func updateClocks() {
        let attached = window != nil
        let wantsTicker = attached && (configuration?.playing == true || manualUntil != nil)
        if wantsTicker, ticker == nil {
            let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            ticker = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !wantsTicker {
            ticker?.invalidate()
            ticker = nil
        }
        let wantsDisplayLink = attached && (activeGap != nil || fillingRow != nil) &&
            configuration?.playing == true && configuration?.reduceMotion == false
        if wantsDisplayLink, displayLink == nil {
            #if MUZIKA_DEV_LOGS
            progressFrames = MuzikaFrameMetrics()
            MuzikaTrace.event(.lyrics, "progress.clock.start")
            #endif
            let link = displayLink(target: self, selector: #selector(updatePlaybackProgress))
            displayLink = link
            link.add(to: .main, forMode: .common)
        } else if !wantsDisplayLink {
            #if MUZIKA_DEV_LOGS
            if displayLink != nil { MuzikaTrace.event(.lyrics, "progress.clock.stop", progressFrames.summary) }
            #endif
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func tick() {
        updateCue()
        if let manualUntil, !liveScrolling, CACurrentMediaTime() >= manualUntil {
            self.manualUntil = nil
            #if MUZIKA_DEV_LOGS
            MuzikaTrace.event(.lyrics, "timed.manual.resume")
            #endif
            center(animated: configuration?.reduceMotion == false)
        }
        updateClocks()
    }

    @objc private func updatePlaybackProgress() {
        let now = audioTime
        #if MUZIKA_DEV_LOGS
        progressFrames.record(at: CACurrentMediaTime(), position: now)
        progressFrames.reportIfReady(.lyrics, "progress.frames")
        #endif
        if let gap = activeGap {
            countdown.setProgress((now - gap.start) / (gap.end - gap.start))
        }
        fillingRow?.paintLineFill(at: now)
    }

    fileprivate func row(at point: CGPoint) -> Int? {
        guard let geometry, let typography = measuredTypography, let configuration else { return nil }
        let x = (canvas.bounds.width - typography.containerWidth) / 2 + typography.horizontalInset
        let localPoint = CGPoint(x: point.x, y: point.y - displayedTranslation)
        let row = if gapExitID != nil || motion?.staggered == true {
            rowLayers.first { ($0.value.layer.presentation()?.frame ?? $0.value.layer.frame).contains(localPoint) }?.key
        } else {
            geometry.row(at: localPoint.y, gapBefore: gapIndex)
        }
        guard point.x >= x, point.x < x + typography.textWidth,
              let row, configuration.document.lines[row].start != nil else { return nil }
        return row
    }

    fileprivate func updateHover(_ row: Int?) {
        guard hover != row else { return }
        let previous = hover
        hover = row
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in [previous, row].compactMap({ $0 }) {
            updateRow(index, animated: configuration?.reduceMotion == false)
        }
        CATransaction.commit()
    }

    fileprivate func seek(to row: Int) -> Bool {
        guard let configuration, configuration.document.lines.indices.contains(row),
              let start = configuration.document.lines[row].start else { return false }
        let offset = configuration.offset.isFinite ? configuration.offset : 0
        manualUntil = nil
        liveScrolling = false
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.lyrics, "seek.row", "row=\(row) target_s=\(max(0, start + offset))")
        #endif
        configuration.seek(max(0, start + offset))
        updateCue(force: true, at: start)
        if focus == .row(row) { center(animated: !configuration.reduceMotion) }
        return true
    }

    fileprivate func accessibilityItems() -> [Any] {
        guard let configuration else { return [] }
        if accessibilityRows == nil {
            accessibilityRows = configuration.document.lines.enumerated().map { index, line in
                let item = LyricsAccessibilityRow(owner: self, row: index)
                item.setAccessibilityParent(canvas)
                item.setAccessibilityRole(line.start == nil ? .staticText : .button)
                item.setAccessibilityLabel([line.pronunciation, line.text, line.translation].compactMap { $0 }.joined(separator: ", "))
                if line.start != nil {
                    item.setAccessibilityHelp(line.isBackground
                        ? String(localized: "Backing vocals. Seeks to this line.")
                        : String(localized: "Seeks to this line."))
                }
                return item
            }
        }
        var items: [Any] = accessibilityRows ?? []
        if let gapIndex {
            if accessibilityCountdown == nil {
                let gap = LyricsAccessibilityRow(owner: self, row: nil)
                gap.setAccessibilityParent(canvas)
                gap.setAccessibilityRole(.staticText)
                gap.setAccessibilityLabel(String(localized: "Instrumental break"))
                accessibilityCountdown = gap
            }
            if let accessibilityCountdown { items.insert(accessibilityCountdown, at: gapIndex) }
        }
        return items
    }

    fileprivate func accessibilityFrame(row index: Int?) -> CGRect {
        guard let geometry, let typography = measuredTypography, let window else { return .zero }
        let x = (canvas.bounds.width - typography.containerWidth) / 2 + typography.horizontalInset
        let frame: CGRect
        if let index, blockHeights.indices.contains(index), let row = configuration?.document.lines[index] {
            let height = blockHeights[index].reduce(0, +) + CGFloat(max(0, blockHeights[index].count - 1)) * typography.auxiliarySpacing
            let indent: CGFloat = row.isBackground ? 16 : 0
            let presentedY = gapExitID == nil ? nil : rowLayers[index]?.layer.presentation()?.frame.minY
            frame = CGRect(x: x + indent, y: presentedY ?? geometry.y(forRow: index, gapBefore: gapIndex),
                           width: max(1, typography.textWidth - indent), height: height)
        } else if let gapIndex {
            frame = CGRect(x: x, y: geometry.y(forGapBefore: gapIndex), width: typography.textWidth, height: 28)
        } else {
            return .zero
        }
        return window.convertToScreen(canvas.convert(frame.offsetBy(dx: 0, dy: displayedTranslation), to: nil))
    }

    fileprivate func accessibilitySelected(row: Int) -> Bool {
        guard let lines = configuration?.document.lines, lines.indices.contains(row) else { return false }
        return isSinging(lines[row])
    }

    fileprivate func accessibilityValue(row: Int?) -> String? {
        guard row == nil, let gap = activeGap else { return nil }
        let seconds = max(1, (gap.end - audioTime).rounded(.up)).formatted(.number.precision(.fractionLength(0)))
        return String(localized: "\(seconds) seconds until the next line")
    }
}

@MainActor
private final class LyricsCanvas: NSView {
    weak var owner: TimedLyricsScrollView?
    private var pressed: Int?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                      owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let row = owner?.row(at: convert(event.locationInWindow, from: nil))
        owner?.updateHover(row)
        (row == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        owner?.updateHover(nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = owner?.row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        if let pressed, pressed == owner?.row(at: convert(event.locationInWindow, from: nil)) {
            _ = owner?.seek(to: pressed)
        }
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { owner?.accessibilityItems() }
}

@MainActor
private final class LyricsAccessibilityContent: Sendable {
    private weak var owner: TimedLyricsScrollView?
    private let row: Int?

    init(owner: TimedLyricsScrollView, row: Int?) {
        self.owner = owner
        self.row = row
    }

    var frame: CGRect { owner?.accessibilityFrame(row: row) ?? .zero }
    var value: String? { owner?.accessibilityValue(row: row) }
    var selected: Bool { row.map { owner?.accessibilitySelected(row: $0) == true } ?? false }

    func press() -> Bool {
        guard let row else { return false }
        return owner?.seek(to: row) == true
    }
}

private final class LyricsAccessibilityRow: NSAccessibilityElement {
    private let content: LyricsAccessibilityContent

    @MainActor
    init(owner: TimedLyricsScrollView, row: Int?) {
        content = LyricsAccessibilityContent(owner: owner, row: row)
        super.init()
    }

    override func accessibilityFrame() -> NSRect {
        let content = content
        return MainActor.assumeIsolated { content.frame }
    }

    override func accessibilityValue() -> Any? {
        let content = content
        let value: String? = MainActor.assumeIsolated { content.value }
        return value
    }

    override func isAccessibilitySelected() -> Bool {
        let content = content
        return MainActor.assumeIsolated { content.selected }
    }

    override func accessibilityPerformPress() -> Bool {
        let content = content
        return MainActor.assumeIsolated { content.press() }
    }
}
