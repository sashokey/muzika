import AppKit
import SwiftUI

private struct WindowLibraryFilter {
    let text: Binding<String>
    let prompt: LocalizedStringResource
}

private struct WindowLibraryFilterKey: PreferenceKey {
    static var defaultValue: WindowLibraryFilter? { nil }

    static func reduce(value: inout WindowLibraryFilter?, nextValue: () -> WindowLibraryFilter?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    func libraryWindowTitlebar(showsTitle: Bool) -> some View {
        backgroundPreferenceValue(WindowLibraryFilterKey.self) { filter in
            WindowTitlebar(showsTitle: showsTitle, filter: showsTitle ? filter : nil)
        }
    }

    func windowLibraryFilter(text: Binding<String>, prompt: LocalizedStringResource) -> some View {
        preference(key: WindowLibraryFilterKey.self, value: WindowLibraryFilter(text: text, prompt: prompt))
    }
}

private struct WindowTitlebar: NSViewRepresentable {
    var showsTitle: Bool
    var filter: WindowLibraryFilter?

    func makeNSView(context: Context) -> TitlebarView { TitlebarView() }

    func updateNSView(_ view: TitlebarView, context: Context) {
        view.update(showsTitle: showsTitle, filter: filter)
    }

    final class TitlebarView: NSView {
        private static let filterWidth: CGFloat = 325
        private static let filterPadding: CGFloat = 8
        private static let titlebarPaddingHeight: CGFloat = 12
        private var showsTitle = true
        private var filter: WindowLibraryFilter?
        private var filterLeading: NSLayoutConstraint?
        private let titlebarPadding: NSTitlebarAccessoryViewController = {
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .bottom
            accessory.automaticallyAdjustsSize = false
            accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: TitlebarView.titlebarPaddingHeight))
            return accessory
        }()
        private lazy var filterField: NSSearchField = {
            let field = TitlebarSearchField()
            field.cell = TitlebarSearchCell(textCell: "")
            field.target = self
            field.action = #selector(filterChanged)
            field.sendsSearchStringImmediately = true
            field.isBezeled = true
            field.isEditable = true
            field.drawsBackground = false
            field.translatesAutoresizingMaskIntoConstraints = false
            return field
        }()
        private lazy var filterAccessory: NSTitlebarAccessoryViewController = {
            let filterHeight: CGFloat = 28
            let glass = NSGlassEffectView()
            glass.cornerRadius = filterHeight / 2
            glass.effectIsInteractive = true
            glass.translatesAutoresizingMaskIntoConstraints = false

            let content = NSView()
            content.addSubview(filterField)
            glass.contentView = content

            let container = NSView(frame: NSRect(
                x: 0, y: 0, width: TitlebarView.filterWidth, height: filterHeight + TitlebarView.filterPadding
            ))
            container.addSubview(glass)
            let leading = glass.leftAnchor.constraint(equalTo: container.leftAnchor)
            filterLeading = leading
            NSLayoutConstraint.activate([
                leading,
                glass.widthAnchor.constraint(equalToConstant: TitlebarView.filterWidth),
                glass.topAnchor.constraint(equalTo: container.topAnchor, constant: TitlebarView.filterPadding),
                glass.heightAnchor.constraint(equalToConstant: filterHeight),
                filterField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
                filterField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
                filterField.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = container
            return accessory
        }()

        private let accessory: NSTitlebarAccessoryViewController = {
            let icon = NSImageView()
            if let url = Bundle.main.url(forResource: "OkayegTitle", withExtension: "webp") {
                icon.image = NSImage(contentsOf: url)
            }
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.setAccessibilityElement(false)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16)
            ])

            let label = NSTextField(labelWithString: "💢 MUZIKA ❓")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityLabel("Okayeg 💢 MUZIKA ❓")

            let stack = NSStackView(views: [icon, label])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
            stack.frame.size = stack.fittingSize

            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .left
            accessory.view = stack
            return accessory
        }()

        func update(showsTitle: Bool, filter: WindowLibraryFilter?) {
            self.showsTitle = showsTitle
            self.filter = filter
            if let window { updateAccessories(in: window) }
        }

        @objc private func filterChanged(_ sender: NSSearchField) {
            filter?.text.wrappedValue = sender.stringValue
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window, window !== newWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: window)
                setAccessory(accessory, visible: false, in: window)
                setAccessory(filterAccessory, visible: false, in: window)
                setAccessory(titlebarPadding, visible: false, in: window)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            filterAccessory.layoutAttribute = window.windowTitlebarLayoutDirection == .rightToLeft ? .right : .left
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResize(_:)), name: NSWindow.didResizeNotification, object: window
            )
            updateAccessories(in: window)
        }

        override func layout() {
            super.layout()
            if let window { centerFilter(in: window) }
        }

        @objc private func windowDidResize(_ notification: Notification) {
            if let window { centerFilter(in: window) }
        }

        private func updateAccessories(in window: NSWindow) {
            setAccessory(accessory, visible: showsTitle, in: window)
            setAccessory(titlebarPadding, visible: showsTitle, in: window)
            if let filter {
                let prompt = String(localized: filter.prompt)
                filterField.placeholderString = prompt
                filterField.setAccessibilityLabel(prompt)
                let text = filter.text.wrappedValue
                if filterField.stringValue != text { filterField.stringValue = text }
            }
            setAccessory(filterAccessory, visible: filter != nil, in: window)
            centerFilter(in: window)
        }

        private func centerFilter(in window: NSWindow) {
            guard filter != nil, let filterLeading else { return }
            let container = filterAccessory.view
            guard container.window === window else { return }
            let frame = container.convert(container.bounds, to: nil)
            let rtl = window.windowTitlebarLayoutDirection == .rightToLeft
            let detailOffset = BrowseLayout.detailLeadingInset / 2
            let center = window.contentLayoutRect.midX + (rtl ? -detailOffset : detailOffset)
            let halfWidth = Self.filterWidth / 2
            let inset = max(0, rtl ? frame.maxX - center - halfWidth : center - halfWidth - frame.minX)
            let width = Self.filterWidth + inset
            let leading = rtl ? 0 : inset
            if abs(filterLeading.constant - leading) > 0.01 {
                filterLeading.constant = leading
            }
            if abs(container.frame.width - width) > 0.01 {
                container.setFrameSize(NSSize(width: width, height: container.frame.height))
            }
        }

        private func setAccessory(_ accessory: NSTitlebarAccessoryViewController, visible: Bool, in window: NSWindow) {
            let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory)
            if visible {
                if index == nil { window.addTitlebarAccessoryViewController(accessory) }
            } else if let index {
                window.removeTitlebarAccessoryViewController(at: index)
            }
        }
    }
}

private final class TitlebarSearchField: NSSearchField {
    override var focusRingMaskBounds: NSRect {
        guard let superview else { return bounds }
        return convert(superview.bounds, from: superview)
    }

    override func drawFocusRingMask() {
        let rect = focusRingMaskBounds
        let radius = rect.height / 2
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}

private final class TitlebarSearchCell: NSSearchFieldCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }
}
