import AppKit
import QuartzCore
import SwiftUI

extension View {
    func trackTableScrollEdge(enabled: Bool = true, usesUniformRows: Bool = false) -> some View {
        background {
            if enabled {
                BrowseNativeScrollEdge(usesUniformRows: usesUniformRows)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    func hideTitlebarScrollEdge(enabled: Bool = true) -> some View {
        background {
            if enabled {
                BrowseNativeScrollEdge(hidesTitlebarBackdrop: true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct BrowseNativeScrollEdge: NSViewRepresentable {
    var usesUniformRows = false
    var hidesTitlebarBackdrop = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.controlSize) private var controlSize

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.hidesTitlebarBackdrop = hidesTitlebarBackdrop
        view.enabled = !reduceTransparency
        view.useUniformRows = usesUniformRows && dynamicTypeSize == .large && controlSize == .regular
        view.updateMasks()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.restoreMasks()
    }

    final class Anchor: NSView {
        var enabled = true
        var useUniformRows = false
        var hidesTitlebarBackdrop = false
        private weak var scroll: NSScrollView?
        private var masks: [ObjectIdentifier: RectangularLayerMask] = [:]
        private weak var sizedTable: NSTableView?
        private var originalRowHeight: CGFloat?
        private var uniformRowHeight: CGFloat?
        private var rowSizingPending = false
        #if MUZIKA_DEV_LOGS
        private weak var tracedTable: NSTableView?
        #endif

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                restoreMasks()
                forgetRowSizing()
            }
            else { Task { @MainActor [weak self] in self?.updateMasks() } }
        }

        override func layout() {
            super.layout()
            updateMasks()
        }

        func updateMasks() {
            guard let window, !bounds.isEmpty else {
                restoreMasks()
                forgetRowSizing()
                return
            }
            if scroll?.window !== window {
                restoreMasks()
                forgetRowSizing()
                let region = convert(bounds, to: nil)
                var ancestor = superview
                while let view = ancestor, scroll == nil {
                    scroll = findScroll(in: view, region: region)
                    ancestor = view.superview
                }
            }
            guard let scroll else { return }
            if hidesTitlebarBackdrop {
                updateMasks(in: scroll, retaining: nil, titlebarBottom: window.contentLayoutRect.maxY)
                return
            }
            guard let table = scroll.documentView as? NSTableView else { return }
            #if MUZIKA_DEV_LOGS
            observeSelection(in: table)
            #endif
            updateRowSizing(for: table)
            guard enabled, let header = table.headerView, header.window === window else {
                for mask in masks.values { mask.restore() }
                masks.removeAll()
                return
            }
            let frame = scroll.convert(scroll.bounds, to: nil)
            let top = header.convert(header.bounds, to: nil).maxY + BrowseLayout.headerSpacing
            let band = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: top - frame.minY)
            guard !band.isEmpty, band.maxY < frame.maxY else {
                restoreMasks()
                return
            }
            updateMasks(in: scroll, retaining: band)
        }

        private func updateMasks(in scroll: NSScrollView, retaining band: CGRect?, titlebarBottom: CGFloat? = nil) {
            let frame = scroll.convert(scroll.bounds, to: nil)
            var active: Set<ObjectIdentifier> = []
            for view in scroll.subviews {
                let name = String(describing: type(of: view))
                let backdropFrame = view.convert(view.bounds, to: nil)
                guard name == "BackdropView" || name == "NSScrollPocket",
                      abs(backdropFrame.maxY - frame.maxY) < 1,
                      !backdropFrame.isEmpty,
                      let layer = view.layer else { continue }
                if let titlebarBottom, backdropFrame.minY < titlebarBottom - 1 { continue }
                let rect = band.map { view.convert($0, from: nil).intersection(view.bounds) } ?? .zero
                guard band == nil || !rect.isEmpty else { continue }
                let id = ObjectIdentifier(layer)
                active.insert(id)
                let mask = masks[id] ?? RectangularLayerMask(layer: layer)
                mask.update(rect)
                masks[id] = mask
            }
            for id in Array(masks.keys) where !active.contains(id) {
                masks.removeValue(forKey: id)?.restore()
            }
        }

        func restoreMasks() {
            for mask in masks.values { mask.restore() }
            masks.removeAll()
            scroll = nil
            #if MUZIKA_DEV_LOGS
            NotificationCenter.default.removeObserver(self, name: NSTableView.selectionDidChangeNotification, object: tracedTable)
            tracedTable = nil
            #endif
        }

        #if MUZIKA_DEV_LOGS
        private func observeSelection(in table: NSTableView) {
            guard tracedTable !== table else { return }
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSTableView.selectionDidChangeNotification, object: tracedTable)
            tracedTable = table
            center.addObserver(self, selector: #selector(selectionChanged(_:)),
                name: NSTableView.selectionDidChangeNotification, object: table)
        }

        @objc private func selectionChanged(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow >= 0 ? table.selectedRow : 0
            let height = table.numberOfRows > row ? table.rect(ofRow: row).height : 0
            MuzikaTrace.event(.library, "table.selection",
                "selected=\(table.numberOfSelectedRows) row=\(row) measured_pt=\(height) native_height_pt=\(table.rowHeight) automatic=\(table.usesAutomaticRowHeights)")
        }
        #endif

        private func updateRowSizing(for table: NSTableView) {
            if sizedTable !== table { forgetRowSizing() }
            if useUniformRows {
                if let uniformRowHeight, !table.usesAutomaticRowHeights, table.rowHeight == uniformRowHeight { return }
                guard table.usesAutomaticRowHeights || sizedTable === table else { return }
            } else if sizedTable !== table {
                return
            }
            guard !rowSizingPending else { return }
            rowSizingPending = true
            Task { @MainActor [weak self, weak table] in
                guard let self else { return }
                self.rowSizingPending = false
                guard let table, self.window != nil, self.scroll?.documentView === table else { return }
                if self.useUniformRows { self.fixRowHeight(in: table) }
                else { self.restoreRowSizing() }
            }
        }

        private func fixRowHeight(in table: NSTableView) {
            let height: CGFloat
            if sizedTable === table, let uniformRowHeight {
                height = uniformRowHeight
            } else {
                var lower = CGFloat.infinity
                var upper = CGFloat.zero
                var count = 0
                table.enumerateAvailableRowViews { row, _ in
                    let height = row.frame.height
                    guard height > 0 else { return }
                    lower = min(lower, height)
                    upper = max(upper, height)
                    count += 1
                }
                guard count >= 2, upper - lower < 0.5, lower > table.intercellSpacing.height else { return }
                height = lower - table.intercellSpacing.height
                originalRowHeight = table.rowHeight
                uniformRowHeight = height
                sizedTable = table
            }
            #if MUZIKA_DEV_LOGS
            if table.rowHeight != height || table.usesAutomaticRowHeights {
                MuzikaTrace.event(.library, "table.uniform-height",
                    "before_pt=\(table.rowHeight) fixed_pt=\(height) spacing_pt=\(table.intercellSpacing.height) rows=\(table.numberOfRows)")
            }
            #endif
            if table.rowHeight != height { table.rowHeight = height }
            if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
        }

        private func restoreRowSizing() {
            if let table = sizedTable, let originalRowHeight, table.rowHeight == uniformRowHeight {
                table.rowHeight = originalRowHeight
                table.usesAutomaticRowHeights = true
            }
            forgetRowSizing()
        }

        private func forgetRowSizing() {
            sizedTable = nil
            originalRowHeight = nil
            uniformRowHeight = nil
        }

        private func findScroll(in view: NSView, region: CGRect) -> NSScrollView? {
            if let scroll = view as? NSScrollView, hidesTitlebarBackdrop || scroll.documentView is NSTableView {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if abs(frame.minX - region.minX) < 1, abs(frame.width - region.width) < 1,
                   frame.minY - 1 <= region.minY, frame.maxY + 1 >= region.maxY {
                    return scroll
                }
            }
            for child in view.subviews.reversed() {
                if let scroll = findScroll(in: child, region: region) { return scroll }
            }
            return nil
        }
    }
}
