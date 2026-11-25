import AppKit
import SwiftUI

struct BrowseHeaderMenu: Identifiable {
    enum ID: Hashable {
        case sort
        case filters
        case folderOrder
    }

    let id: ID
    let title: LocalizedStringResource
    let symbol: String
    let entries: [BrowseHeaderMenuEntry]
}

enum BrowseHeaderMenuEntry {
    case command(Text, selected: Bool, enabled: Bool = true, action: () -> Void)
    case submenu(LocalizedStringResource, [BrowseHeaderMenuEntry])
    case separator

    static func choices<Value: Equatable>(
        _ values: [Value], selection: Binding<Value>, title: (Value) -> Text
    ) -> [Self] {
        values.map { value in
            .command(title(value), selected: selection.wrappedValue == value) { selection.wrappedValue = value }
        }
    }
}

struct BrowseHeaderMenus: View {
    let menus: [BrowseHeaderMenu]

    @Namespace private var menuSpace
    @State private var selection: BrowseHeaderMenu.ID?
    @State private var buttonFrames: [BrowseHeaderMenu.ID: CGRect] = [:]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(menus) { menu in
                Button(menu.title, systemImage: menu.symbol) {
                    select(menu.id)
                }
                .buttonStyle(GlassHoverButtonStyle.action(showsMenuIndicator: true))
                .onGeometryChange(for: CGRect.self, of: { [menuSpace] in $0.frame(in: .named(menuSpace)) }) {
                    buttonFrames[menu.id] = $0
                }
            }
        }
        .coordinateSpace(name: menuSpace)
        .background {
            BrowseHeaderMenuPopover(
                menu: menus.first { $0.id == selection },
                selectionRect: selection.flatMap { buttonFrames[$0] },
                buttonFrames: buttonFrames.filter { id, _ in menus.contains { $0.id == id } },
                select: select,
                dismiss: { selection = nil }
            )
        }
    }

    private func select(_ id: BrowseHeaderMenu.ID) {
        #if MUZIKA_DEV_LOGS
        MuzikaTrace.event(.library, "menu.switch", "from=\(String(describing: selection)) selected=\(id) closes=\(selection == id)")
        #endif
        selection = selection == id ? nil : id
    }
}

private struct BrowseHeaderMenuPanel: View {
    let menu: BrowseHeaderMenu
    let dismiss: () -> Void

    @State private var submenuIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let submenuIndex, menu.entries.indices.contains(submenuIndex),
               case let .submenu(title, entries) = menu.entries[submenuIndex] {
                menuButton(Text(title), symbol: "chevron.backward") {
                    self.submenuIndex = nil
                }
                Divider()
                rows(entries)
            } else {
                rows(menu.entries)
            }
        }
        .padding(5)
        .frame(minWidth: 165)
        .fixedSize()
    }

    private func rows(_ entries: [BrowseHeaderMenuEntry]) -> some View {
        ForEach(entries.indices, id: \.self) { index in
            switch entries[index] {
            case let .command(title, selected, enabled, action):
                menuButton(title, symbol: selected ? "checkmark" : nil) {
                    action()
                    dismiss()
                }
                .disabled(!enabled)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            case let .submenu(title, _):
                menuButton(Text(title), trailingSymbol: "chevron.forward") { submenuIndex = index }
            case .separator:
                Divider().padding(.vertical, 3)
            }
        }
    }

    private func menuButton(
        _ title: Text, symbol: String? = nil, trailingSymbol: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol ?? "checkmark")
                    .opacity(symbol == nil ? 0 : 1)
                    .accessibilityHidden(true)
                title
                Spacer(minLength: 12)
                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .liquidGlassHover(outset: .zero)
    }
}

private struct BrowseHeaderMenuPopover: NSViewRepresentable {
    let menu: BrowseHeaderMenu?
    let selectionRect: CGRect?
    let buttonFrames: [BrowseHeaderMenu.ID: CGRect]
    let select: (BrowseHeaderMenu.ID) -> Void
    let dismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.update(self, anchor: view)
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private let popover: NSPopover
        private weak var anchor: Anchor?
        private var buttonFrames: [BrowseHeaderMenu.ID: CGRect] = [:]
        private var select: ((BrowseHeaderMenu.ID) -> Void)?
        private var dismiss: (() -> Void)?
        private var eventMonitor: Any?

        init(popover: NSPopover = NSPopover()) {
            self.popover = popover
            super.init()
            popover.behavior = .applicationDefined
            popover.delegate = self
        }

        func update(_ presentation: BrowseHeaderMenuPopover, anchor: Anchor) {
            guard let menu = presentation.menu, let selectionRect = presentation.selectionRect, anchor.window != nil else {
                close()
                return
            }
            self.anchor = anchor
            buttonFrames = presentation.buttonFrames
            select = presentation.select
            dismiss = presentation.dismiss

            let isSwitching = popover.isShown
            popover.animates = !isSwitching && !presentation.reduceMotion
            let panel = BrowseHeaderMenuPanel(menu: menu) { [weak self] in self?.dismissMenu() }
                .id(menu.id)
                .environment(\.dynamicTypeSize, presentation.dynamicTypeSize)
                .environment(\.layoutDirection, presentation.layoutDirection)
                .environment(\.colorScheme, presentation.colorScheme)
            let controller: NSHostingController<AnyView>
            if let current = popover.contentViewController as? NSHostingController<AnyView> {
                controller = current
                controller.rootView = AnyView(panel)
            } else {
                controller = NSHostingController(rootView: AnyView(panel))
                controller.sizingOptions = [.preferredContentSize]
                popover.contentViewController = controller
            }
            let size = controller.sizeThatFits(in: CGSize(width: 500, height: 500))
            if popover.contentSize != size { popover.contentSize = size }
            if popover.isShown {
                popover.positioningRect = selectionRect
            } else {
                popover.show(relativeTo: selectionRect, of: anchor, preferredEdge: .maxY)
            }
            popover.animates = !presentation.reduceMotion
            if eventMonitor == nil {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
                    [weak self] event in
                    guard let self else { return event }
                    return self.handle(event)
                }
                NotificationCenter.default.addObserver(
                    self, selector: #selector(dismissMenu), name: NSApplication.didResignActiveNotification, object: NSApp
                )
            }
        }

        func close() {
            select = nil
            dismiss = nil
            stopMonitoring()
            if popover.isShown { popover.close() }
        }

        func popoverDidClose(_ notification: Notification) {
            stopMonitoring()
            let action = dismiss
            dismiss = nil
            action?()
        }

        @objc private func dismissMenu() {
            let action = dismiss
            close()
            action?()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                dismissMenu()
                return nil
            }
            if event.window === popover.contentViewController?.view.window { return event }
            if event.type == .leftMouseDown, let anchor, event.window === anchor.window {
                let point = anchor.convert(event.locationInWindow, from: nil)
                if let id = buttonFrames.first(where: { $0.value.contains(point) })?.key {
                    select?(id)
                    return nil
                }
            }
            dismissMenu()
            return event
        }

        private func stopMonitoring() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: NSApp)
        }
    }
}
