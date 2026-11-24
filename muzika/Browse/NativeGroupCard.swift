import AppKit
import QuartzCore

@MainActor
final class NativeGroupCard: NSButton {
    private static let gridTitleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    private static let listTitleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let symbols: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private let art = CALayer()
    private let placeholder = CALayer()
    private let mainText = CATextLayer()
    private let detailText = CATextLayer()
    private let arrow = CALayer()
    private let divider = CALayer()
    private(set) var group: BrowseGroup?
    private weak var library: LibraryStore?
    private weak var playback: PlaybackController?
    private var open: ((LibraryRoute) -> Void)?
    private var presentation = BrowseGroupPresentation.grid
    private var circular = false
    private var thumbnailKey: String?
    private var thumbnail: CGImage?
    private var scale: CGFloat = 1
    private var loadTask: Task<Void, Never>?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(openGroup)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        art.contentsGravity = .resizeAspectFill
        art.masksToBounds = true
        art.addSublayer(placeholder)
        art.borderWidth = 1
        for part in [art, mainText, detailText, arrow, divider] {
            layer?.addSublayer(part)
        }
        for text in [mainText, detailText] {
            text.truncationMode = .end
            text.isWrapped = false
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit { loadTask?.cancel() }

    func configure(group: BrowseGroup, library: LibraryStore, playback: PlaybackController, presentation: BrowseGroupPresentation,
                   circular: Bool, frame: CGRect, displayScale: CGFloat, open: @escaping (LibraryRoute) -> Void) {
        self.group = group
        self.library = library
        self.playback = playback
        self.open = open
        self.presentation = presentation
        self.circular = circular
        scale = displayScale
        if self.frame != frame { self.frame = frame }
        setAccessibilityLabel(group.title)
        setAccessibilityHelp(group.subtitle)
        let pixels = presentation == .list ? 96 : min(320, max(96, Int(ceil(frame.width * displayScale / 32)) * 32))
        updateThumbnail(track: group.artworkTrack, library: library, pixels: pixels)
        updateLayers()
    }

    func releaseContent() {
        loadTask?.cancel()
        loadTask = nil
        thumbnailKey = nil
        thumbnail = nil
        art.contents = nil
        mainText.string = nil
        detailText.string = nil
        group = nil
    }

    private func updateThumbnail(track: AudioTrack?, library: LibraryStore, pixels: Int) {
        let key = track.map { "\(pixels):\($0.id)" }
        guard key != thumbnailKey else { return }
        loadTask?.cancel()
        loadTask = nil
        thumbnailKey = key
        thumbnail = nil
        guard let track, let key else { return }
        if let image = BrowseArtwork.cachedThumbnail(for: track, pixelSize: pixels) {
            thumbnail = image
            return
        }
        loadTask = Task(priority: .utility) { [weak self] in
            guard let image = await BrowseArtwork.loadThumbnail(for: track, in: library, pixelSize: pixels),
                  !Task.isCancelled, let self, self.thumbnailKey == key else { return }
            self.thumbnail = image
            self.updateArtworkContents()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayers()
    }

    override func draw(_ dirtyRect: NSRect) {}

    private func updateLayers() {
        guard let group else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            art.backgroundColor = NSColor.controlBackgroundColor.cgColor
            art.borderColor = NSColor.quaternaryLabelColor.cgColor
            mainText.foregroundColor = NSColor.labelColor.cgColor
            detailText.foregroundColor = NSColor.secondaryLabelColor.cgColor
            divider.backgroundColor = NSColor.separatorColor.cgColor
            for part in [art, placeholder, mainText, detailText, arrow] { part.contentsScale = scale }
            if presentation == .list {
                layoutList(group)
            } else {
                layoutGrid(group)
            }
            art.cornerRadius = circular ? art.bounds.width / 2 : 9
            let icon = makeSymbol(group.route.symbol, size: max(14, art.bounds.width * 0.29), weight: .medium)
            setSymbol(icon, on: placeholder, center: CGPoint(x: art.bounds.midX, y: art.bounds.midY))
        }
        updateArtworkContents()
    }

    private func layoutGrid(_ group: BrowseGroup) {
        art.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.width)
        let titleY = art.frame.maxY + 4
        let titleHeight = lineHeight(Self.gridTitleFont)
        setText(group.title, on: mainText, font: Self.gridTitleFont, x: 0, y: titleY, width: bounds.width)
        setText(group.subtitle, on: detailText, font: Self.captionFont,
                x: 0, y: titleY + titleHeight + 4, width: bounds.width)
        arrow.isHidden = true
        divider.isHidden = true
    }

    private func layoutList(_ group: BrowseGroup) {
        art.frame = CGRect(x: 0, y: BrowseGroupList.rowVerticalPadding, width: 36, height: 36)
        let icon = makeSymbol("chevron.forward", size: NSFont.systemFontSize, weight: .regular)
        let arrowWidth = icon?.size.width ?? 0
        let captionWidth = ceil((group.subtitle as NSString).size(withAttributes: [.font: Self.captionFont]).width)
        let captionX = max(46, bounds.maxX - arrowWidth - 10 - captionWidth)
        setText(group.title, on: mainText, font: Self.listTitleFont, x: 46,
                y: (art.frame.midY - lineHeight(Self.listTitleFont) / 2).rounded(.down), width: captionX - 56)
        setText(group.subtitle, on: detailText, font: Self.captionFont, x: captionX,
                y: (art.frame.midY - lineHeight(Self.captionFont) / 2).rounded(.down), width: captionWidth)
        setSymbol(icon, on: arrow, center: CGPoint(x: bounds.maxX - arrowWidth / 2, y: art.frame.midY))
        arrow.isHidden = false
        divider.frame = CGRect(x: 46, y: bounds.maxY - 1, width: max(0, bounds.width - 46), height: 1)
        divider.isHidden = false
    }

    private func updateArtworkContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.contents = thumbnail
        placeholder.isHidden = thumbnail != nil
        CATransaction.commit()
    }

    private func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    private func setText(_ title: String, on layer: CATextLayer, font: NSFont, x: CGFloat, y: CGFloat, width: CGFloat) {
        layer.font = font
        layer.fontSize = font.pointSize
        layer.string = title
        layer.frame = CGRect(x: x, y: y, width: max(0, width), height: lineHeight(font))
    }

    private func setSymbol(_ image: NSImage?, on layer: CALayer, center: CGPoint) {
        guard let image else {
            layer.contents = nil
            return
        }
        layer.contents = image
        layer.frame = CGRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2,
                             width: image.size.width, height: image.size.height)
    }

    private func makeSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let size = size.rounded()
        let key = "\(effectiveAppearance.name.rawValue):\(name):\(size):\(weight.rawValue)" as NSString
        if let cached = Self.symbols.object(forKey: key) { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: size, weight: weight)
                .applying(.init(paletteColors: [.tertiaryLabelColor]))
        )
        if let image { Self.symbols.setObject(image, forKey: key) }
        return image
    }

    @objc private func openGroup() {
        if let group { open?(group.route) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let group, let playback else { return nil }
        let menu = NSMenu()
        let open = self.open
        menu.addItem(ActionItem(title: String(localized: "Open"), symbol: "arrow.right") { open?(group.route) })
        menu.addItem(.separator())
        menu.addItem(ActionItem(title: String(localized: "Play"), symbol: "play") { playback.play(group.tracks, shuffled: false) })
        if group.tracks.count > 1 {
            menu.addItem(ActionItem(title: String(localized: "Shuffle"), symbol: "shuffle") { playback.play(group.tracks, shuffled: true) })
        }
        menu.addItem(ActionItem(title: String(localized: "Play Next"), symbol: "text.insert") { playback.addToQueue(group.tracks, next: true) })
        menu.addItem(ActionItem(title: String(localized: "Add to Queue"), symbol: "text.append") { playback.addToQueue(group.tracks, next: false) })
        if group.tracks.count == 1, let track = group.tracks.first {
            menu.addItem(.separator())
            menu.addItem(ActionItem(title: String(localized: "Show in Finder"), symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([track.url])
            })
        }
        return menu
    }

    private final class ActionItem: NSMenuItem {
        private let invoke: () -> Void

        init(title: String, symbol: String, invoke: @escaping () -> Void) {
            self.invoke = invoke
            super.init(title: title, action: #selector(invokeAction), keyEquivalent: "")
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            target = self
        }

        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func invokeAction() { invoke() }
    }
}
