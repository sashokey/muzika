import AppKit
import QuartzCore
import SwiftUI

enum BrowseGroupPresentation {
    case grid
    case list

    @MainActor var hoverOutset: CGSize {
        self == .list ? BrowseTrackRow.hoverOutset : BrowseArtwork.cardHoverOutset
    }

    var dividerHeight: CGFloat { self == .list ? 1 : 0 }
}

@MainActor
struct BrowseGroupGrid: View {
    let groups: [BrowseGroup]
    let library: LibraryStore
    let playback: PlaybackController
    let open: (LibraryRoute) -> Void
    var circular = false
    var presentation: BrowseGroupPresentation = .grid

    @State private var labelHeight: CGFloat = 33
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.controlSize) private var controlSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.libraryPlaybackEffectsVisible) private var playbackEffectsVisible

    var body: some View {
        GroupGridSurface(
            groups: groups, library: library, playback: playback, open: open, circular: circular, presentation: presentation,
            labelHeight: labelHeight,
            appearance: GroupGridAppearance(
                displayScale: displayScale, dynamicTypeSize: dynamicTypeSize, controlSize: controlSize,
                layoutDirection: layoutDirection, colorScheme: colorScheme, reduceMotion: reduceMotion,
                playbackEffectsVisible: playbackEffectsVisible
            )
        )
        .background(alignment: .topLeading) {
            Group {
                if presentation == .grid {
                    GroupGridLabel(title: "M", subtitle: "M")
                } else {
                    Text("M").lineLimit(1)
                }
            }
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { labelHeight = $0 }
        }
    }
}

private struct GroupGridAppearance: Equatable {
    let displayScale: CGFloat
    let dynamicTypeSize: DynamicTypeSize
    let controlSize: ControlSize
    let layoutDirection: LayoutDirection
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    let playbackEffectsVisible: Bool
}

private struct GroupGridLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .fontWeight(.medium)
                .lineLimit(1, reservesSpace: true)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
        }
    }
}

@MainActor
private struct GroupGridCard: View {
    let group: BrowseGroup?
    let library: LibraryStore
    let playback: PlaybackController
    let width: CGFloat
    let circular: Bool
    let presentation: BrowseGroupPresentation
    let appearance: GroupGridAppearance
    let open: (LibraryRoute) -> Void
    var nativeCardHeight: CGFloat?
    var nativeButtonHovered: Bool?

    var body: some View {
        if let group {
            let isList = presentation == .list
            VStack(spacing: 0) {
                Button {
                    open(group.route)
                } label: {
                    cardContent(group)
                        .frame(width: width, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.title)
                .accessibilityHint(group.subtitle)
                .modifier(ArtworkPlaybackModifier(
                    library: library, target: .group(group.tracks), playback: playback, layout: isList ? .row : .grid,
                    cardHoverOutset: nativeCardHeight == nil ? presentation.hoverOutset : nil,
                    hoverOverride: nativeCardHeight.map { _ in true },
                    buttonHoverOverride: nativeButtonHovered
                ))
                .contextMenu {
                    Button("Open", systemImage: "arrow.right") { open(group.route) }
                    Divider()
                    PlayTracksMenu(tracks: group.tracks, playback: playback)
                }
                if isList && nativeCardHeight == nil {
                    Divider().padding(.leading, 46)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .environment(\.dynamicTypeSize, appearance.dynamicTypeSize)
            .environment(\.controlSize, appearance.controlSize)
            .environment(\.layoutDirection, appearance.layoutDirection)
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.libraryPlaybackEffectsVisible, appearance.playbackEffectsVisible)
            .accessibilityHidden(nativeCardHeight != nil)
        }
    }

    @ViewBuilder
    private func cardContent(_ group: BrowseGroup) -> some View {
        if let nativeCardHeight {
            Color.clear.frame(width: width, height: nativeCardHeight - presentation.dividerHeight)
        } else if presentation == .list {
            HStack(spacing: 10) {
                BrowseArtwork(library: library, track: group.artworkTrack, symbol: group.route.symbol,
                              pixelSize: 96, circular: circular)
                    .frame(width: 36, height: 36)
                Text(group.title).lineLimit(1)
                Spacer()
                Text(group.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
            }
            .padding(.vertical, BrowseGroupList.rowVerticalPadding)
        } else {
            let pixels = Int(ceil(width * appearance.displayScale / 32)) * 32
            VStack(alignment: .leading, spacing: 4) {
                BrowseArtwork(library: library, track: group.artworkTrack, symbol: group.route.symbol,
                              pixelSize: min(320, max(96, pixels)), circular: circular)
                GroupGridLabel(title: group.title, subtitle: group.subtitle)
            }
        }
    }
}

private struct GroupGridHoverBackdrop: View {
    let outset: CGSize

    var body: some View {
        Color.clear
            .liquidGlassHover(outset: outset, hovered: true)
            .padding(.horizontal, outset.width)
            .padding(.vertical, outset.height)
    }
}

private final class GroupGridHoverBackdropHost: NSHostingView<GroupGridHoverBackdrop> {
    private static let opacityKey = "group-hover-opacity"

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @discardableResult
    func setHighlighted(_ highlighted: Bool, animated: Bool, startsHidden: Bool = false) -> TimeInterval {
        wantsLayer = true
        guard let layer else { return 0 }
        let target: Float = highlighted ? 1 : 0
        let active = layer.animation(forKey: Self.opacityKey) as? CABasicAnimation
        let start = startsHidden ? 0 : layer.presentation()?.opacity ?? (active?.fromValue as? NSNumber)?.floatValue ?? layer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.opacity = target
        layer.removeAnimation(forKey: Self.opacityKey)
        guard animated, start != target else { return 0 }

        let animation = CASpringAnimation(perceptualDuration: GlassHoverMotion.duration, bounce: 0)
        animation.keyPath = "opacity"
        animation.fromValue = start
        animation.toValue = target
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: Self.opacityKey)
        return animation.duration
    }
}

private struct GroupGridLayout: Equatable {
    private static let columnSpacing: CGFloat = 16
    private static let rowSpacing: CGFloat = 19
    private static let minimumWidth: CGFloat = 132
    private static let maximumWidth: CGFloat = 208

    let width: CGFloat
    let itemCount: Int
    let columns: Int
    let itemWidth: CGFloat
    let rowHeight: CGFloat
    let presentation: BrowseGroupPresentation

    init(width: CGFloat, labelHeight: CGFloat, itemCount: Int, presentation: BrowseGroupPresentation) {
        self.width = width
        self.itemCount = itemCount
        self.presentation = presentation
        if presentation == .list {
            columns = 1
            itemWidth = width
            rowHeight = max(36, labelHeight) + BrowseGroupList.rowVerticalPadding * 2 + presentation.dividerHeight
        } else {
            columns = max(1, Int((width + Self.columnSpacing) / (Self.minimumWidth + Self.columnSpacing)))
            itemWidth = min(Self.maximumWidth, max(0, (width - CGFloat(columns - 1) * Self.columnSpacing) / CGFloat(columns)))
            rowHeight = itemWidth + 4 + labelHeight
        }
    }

    private var rowCount: Int { (itemCount + columns - 1) / columns }
    private var rowSpacing: CGFloat { presentation == .list ? 0 : Self.rowSpacing }
    private var rowStride: CGFloat { rowHeight + rowSpacing }
    var totalHeight: CGFloat { max(0, CGFloat(rowCount) * rowStride - rowSpacing) }

    func items(in rect: CGRect) -> Range<Int> {
        let reserve = 2
        let firstRow = Int(floor(rect.minY / rowStride)) - reserve
        let endRow = Int(ceil(rect.maxY / rowStride)) + reserve
        let rows = (firstRow..<max(firstRow, endRow)).clamped(to: 0..<rowCount)
        return min(itemCount, rows.lowerBound * columns)..<min(itemCount, rows.upperBound * columns)
    }

    func frame(for index: Int, rightToLeft: Bool) -> CGRect {
        let x = CGFloat(index % columns) * (itemWidth + Self.columnSpacing)
        return CGRect(x: rightToLeft ? width - x - itemWidth : x, y: CGFloat(index / columns) * rowStride,
                      width: itemWidth, height: rowHeight)
    }
}

private struct GroupGridSurface: NSViewRepresentable {
    let groups: [BrowseGroup]
    let library: LibraryStore
    let playback: PlaybackController
    let open: (LibraryRoute) -> Void
    let circular: Bool
    let presentation: BrowseGroupPresentation
    let labelHeight: CGFloat
    let appearance: GroupGridAppearance

    func makeNSView(context: Context) -> Viewport { Viewport() }

    func updateNSView(_ view: Viewport, context: Context) { view.configure(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Viewport, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: max(1, layout(width: width).totalHeight))
    }

    private func layout(width: CGFloat) -> GroupGridLayout {
        GroupGridLayout(width: width, labelHeight: labelHeight, itemCount: groups.count, presentation: presentation)
    }

    final class Viewport: NSView {
        private typealias CardHost = NSHostingView<GroupGridCard>

        private weak var clip: NSClipView?
        private var configuration: GroupGridSurface?
        private var cards: [Int: NSView] = [:]
        private var spare: [NSView] = []
        private var currentLayout: GroupGridLayout?
        private var currentItems: Range<Int> = 0..<0
        private var requiresRefresh = false
        private var nativeCards = false
        private var tracking: NSTrackingArea?
        private var interaction: CardHost?
        private var hoverBackdrop: GroupGridHoverBackdropHost?
        private var fadingBackdrop: GroupGridHoverBackdropHost?
        private var fadeRemoval: Task<Void, Never>?
        private var interactionIndex: Int?
        private var interactionButtonHovered: Bool?

        override var isFlipped: Bool { true }

        isolated deinit {
            fadeRemoval?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        func configure(_ next: GroupGridSurface) {
            let previous = configuration
            configuration = next
            let useNative = next.appearance.dynamicTypeSize == .large &&
                next.appearance.layoutDirection == .leftToRight && !NSWorkspace.shared.isVoiceOverEnabled
            if useNative != nativeCards {
                clearInteraction()
                for view in cards.values { view.removeFromSuperview() }
                for view in spare { view.removeFromSuperview() }
                cards.removeAll()
                spare.removeAll()
                requiresRefresh = true
                nativeCards = useNative
            }
            requiresRefresh = requiresRefresh || previous.map {
                $0.library !== next.library || $0.playback !== next.playback || $0.circular != next.circular
                    || $0.presentation != next.presentation
                    || $0.appearance != next.appearance || !Self.sameGroups($0.groups, next.groups)
            } ?? true
            connectToScrollView()
            needsLayout = true
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window, window !== newWindow {
                for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
                    NotificationCenter.default.removeObserver(self, name: name, object: window)
                }
                clearInteraction()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged), name: name, object: window)
                }
            }
            connectToScrollView()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            connectToScrollView()
            reconcileCards()
            updateInteraction()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { updateInteraction(at: event.locationInWindow) }
        override func mouseMoved(with event: NSEvent) { updateInteraction(at: event.locationInWindow) }
        override func mouseExited(with event: NSEvent) { clearInteraction() }
        @objc private func keyWindowChanged() { updateInteraction() }

        private func connectToScrollView() {
            let next = window == nil ? nil : enclosingScrollView?.contentView
            guard clip !== next else { return }
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
            clip = next
            if let next {
                next.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(scrollBoundsChanged), name: NSView.boundsDidChangeNotification, object: next
                )
            }
        }

        @objc private func scrollBoundsChanged() {
            reconcileCards()
            updateInteraction()
        }

        private func reconcileCards() {
            guard let configuration, let clip, bounds.width > 0 else { return }
            let layout = configuration.layout(width: bounds.width)
            let items = layout.items(in: clip.convert(clip.bounds, to: self))
            let changedLayout = currentLayout != layout
            let refresh = requiresRefresh || changedLayout
            guard refresh || items != currentItems else { return }
            currentItems = items
            currentLayout = layout
            requiresRefresh = false

            if let interactionIndex, refresh || !items.contains(interactionIndex) { clearInteraction() }
            for index in Array(cards.keys) where !items.contains(index) {
                guard let view = cards.removeValue(forKey: index) else { continue }
                view.isHidden = true
                spare.append(view)
            }

            for index in items {
                if let view = cards[index] {
                    if refresh { render(view, index: index, layout: layout, configuration: configuration) }
                } else if let view = spare.popLast() {
                    render(view, index: index, layout: layout, configuration: configuration)
                    view.isHidden = false
                    cards[index] = view
                } else {
                    let view: NSView
                    if nativeCards {
                        view = NativeGroupCard()
                        render(view, index: index, layout: layout, configuration: configuration)
                    } else {
                        let host = NSHostingView(rootView: card(configuration, index: index, width: layout.itemWidth))
                        host.sizingOptions = []
                        host.frame = layout.frame(for: index, rightToLeft: configuration.appearance.layoutDirection == .rightToLeft)
                        view = host
                    }
                    if let interaction { addSubview(view, positioned: .below, relativeTo: interaction) }
                    else { addSubview(view) }
                    cards[index] = view
                }
            }

            for view in spare {
                if let native = view as? NativeGroupCard {
                    native.releaseContent()
                } else if let host = view as? CardHost, host.rootView.group != nil {
                    host.prepareForReuse()
                    host.rootView = card(configuration, index: nil, width: layout.itemWidth)
                }
            }
            while spare.count > items.count, let unused = spare.popLast() {
                unused.removeFromSuperview()
            }
        }

        private func render(_ view: NSView, index: Int, layout: GroupGridLayout, configuration: GroupGridSurface) {
            let group = configuration.groups[index]
            let frame = layout.frame(for: index, rightToLeft: configuration.appearance.layoutDirection == .rightToLeft)
            if let native = view as? NativeGroupCard {
                native.configure(group: group, library: configuration.library, playback: configuration.playback,
                                 presentation: configuration.presentation, circular: configuration.circular,
                                 frame: frame, displayScale: configuration.appearance.displayScale,
                                 open: { [weak self] route in self?.configuration?.open(route) })
            } else if let host = view as? CardHost {
                if let previous = host.rootView.group, previous.id != group.id { host.prepareForReuse() }
                host.rootView = card(configuration, index: index, width: layout.itemWidth)
                host.frame = frame
            }
        }

        private func card(_ configuration: GroupGridSurface, index: Int?, width: CGFloat,
                          nativeCardHeight: CGFloat? = nil, nativeButtonHovered: Bool? = nil) -> GroupGridCard {
            GroupGridCard(group: index.map { configuration.groups[$0] }, library: configuration.library,
                          playback: configuration.playback, width: width, circular: configuration.circular,
                          presentation: configuration.presentation, appearance: configuration.appearance,
                          open: { [weak self] route in self?.configuration?.open(route) },
                          nativeCardHeight: nativeCardHeight, nativeButtonHovered: nativeButtonHovered)
        }

        private func updateInteraction(at location: NSPoint? = nil) {
            guard nativeCards, let configuration, let window, window.isKeyWindow else {
                clearInteraction()
                return
            }
            let point = convert(location ?? window.mouseLocationOutsideOfEventStream, from: nil)
            guard visibleRect.contains(point),
                  let (index, view) = cards.first(where: { $0.value.frame.contains(point) }) else {
                clearInteraction()
                return
            }
            let frame = view.frame
            let buttonHovered: Bool?
            if configuration.presentation == .list, let size = ArtworkPlaybackLayout.row.artworkSize {
                let artwork = CGRect(x: frame.minX, y: frame.minY + BrowseGroupList.rowVerticalPadding,
                                     width: size, height: size)
                buttonHovered = ArtworkPlaybackLayout.row.buttonFrame(in: artwork).contains(point)
            } else {
                buttonHovered = nil
            }
            guard interactionIndex != index || interactionButtonHovered != buttonHovered else { return }
            let root = card(configuration, index: index, width: frame.width, nativeCardHeight: frame.height,
                            nativeButtonHovered: buttonHovered)
            if interactionIndex != index {
                clearInteraction()
                interactionIndex = index
                placeHoverBackdrop(behind: view, presentation: configuration.presentation,
                                   animated: !configuration.appearance.reduceMotion)
            }
            interactionButtonHovered = buttonHovered
            if let interaction {
                interaction.rootView = root
                interaction.frame = frame
                interaction.isHidden = false
            } else {
                let host = NSHostingView(rootView: root)
                host.sizingOptions = []
                host.frame = frame
                addSubview(host, positioned: .above, relativeTo: nil)
                interaction = host
            }
        }

        private func placeHoverBackdrop(behind card: NSView, presentation: BrowseGroupPresentation, animated: Bool) {
            let outset = presentation.hoverOutset
            var content = card.frame
            content.size.height -= presentation.dividerHeight
            let frame = content.insetBy(dx: -outset.width, dy: -outset.height)
            if let fadingBackdrop, fadingBackdrop.superview === self, fadingBackdrop.frame == frame {
                fadeRemoval?.cancel()
                self.fadingBackdrop = hoverBackdrop
                hoverBackdrop = fadingBackdrop
                fadingBackdrop.setHighlighted(true, animated: animated)
                return
            }
            let backdrop = GroupGridHoverBackdrop(outset: outset)
            let host = hoverBackdrop ?? GroupGridHoverBackdropHost(rootView: backdrop)
            if host.rootView.outset != outset { host.rootView = backdrop }
            host.sizingOptions = []
            host.frame = frame
            addSubview(host, positioned: .below, relativeTo: card)
            host.setHighlighted(true, animated: animated, startsHidden: true)
            hoverBackdrop = host
        }

        private func clearInteraction() {
            guard interactionIndex != nil else { return }
            fadeRemoval?.cancel()
            let spare = fadingBackdrop
            spare?.removeFromSuperview()
            fadingBackdrop = hoverBackdrop
            hoverBackdrop = spare
            if let fadingBackdrop {
                let duration = fadingBackdrop.setHighlighted(false, animated: configuration?.appearance.reduceMotion == false)
                if duration == 0 {
                    fadingBackdrop.removeFromSuperview()
                } else {
                    fadeRemoval = Task { @MainActor [weak fadingBackdrop] in
                        do { try await Task.sleep(for: .seconds(duration)) }
                        catch { return }
                        fadingBackdrop?.removeFromSuperview()
                    }
                }
            }
            interactionIndex = nil
            interactionButtonHovered = nil
            if let interaction, let configuration {
                interaction.isHidden = true
                interaction.rootView = card(configuration, index: nil, width: 0)
            }
        }

        private static func sameGroups(_ lhs: [BrowseGroup], _ rhs: [BrowseGroup]) -> Bool {
            guard lhs.count == rhs.count else { return false }
            return lhs.withUnsafeBufferPointer { left in
                rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
            }
        }
    }
}
