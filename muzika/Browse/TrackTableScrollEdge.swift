import AppKit
import QuartzCore
import SwiftUI

extension View {
    func trackTableScrollEdge(enabled: Bool = true, usesUniformRows: Bool = false) -> some View {
        background {
            if enabled {
                TrackTableScrollEdge(usesUniformRows: usesUniformRows)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct TrackTableScrollEdge: NSViewRepresentable {
    var usesUniformRows = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.controlSize) private var controlSize

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
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
        private weak var scroll: NSScrollView?
        private var masks: [ObjectIdentifier: EdgeMask] = [:]
        private weak var sizedTable: NSTableView?
        private var originalRowHeight: CGFloat?
        private var uniformRowHeight: CGFloat?
        private var rowSizingPending = false

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
                    scroll = findTableScroll(in: view, region: region)
                    ancestor = view.superview
                }
            }
            guard let scroll, let table = scroll.documentView as? NSTableView else { return }
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
            var active: Set<ObjectIdentifier> = []
            for view in scroll.subviews {
                let name = String(describing: type(of: view))
                guard name == "BackdropView" || name == "NSScrollPocket",
                      abs(view.convert(view.bounds, to: nil).maxY - frame.maxY) < 1,
                      let layer = view.layer else { continue }
                let rect = view.convert(band, from: nil).intersection(view.bounds)
                guard !rect.isEmpty else { continue }
                let id = ObjectIdentifier(layer)
                active.insert(id)
                let mask = masks[id] ?? EdgeMask(layer: layer)
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
        }

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

        private func findTableScroll(in view: NSView, region: CGRect) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTableView {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if abs(frame.minX - region.minX) < 1, abs(frame.width - region.width) < 1,
                   frame.minY - 1 <= region.minY, frame.maxY + 1 >= region.maxY {
                    return scroll
                }
            }
            for child in view.subviews.reversed() {
                if let scroll = findTableScroll(in: child, region: region) { return scroll }
            }
            return nil
        }
    }

    @MainActor
    private final class EdgeMask {
        private weak var layer: CALayer?
        private var original: CALayer?
        private let mask = CAShapeLayer()
        private var rect: CGRect = .null

        init(layer: CALayer) {
            self.layer = layer
            mask.fillColor = NSColor.black.cgColor
        }

        func update(_ rect: CGRect) {
            guard let layer else { return }
            guard self.rect != rect || mask.frame != layer.bounds || layer.mask !== mask else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.rect = rect
            mask.frame = layer.bounds
            mask.path = CGPath(rect: rect, transform: nil)
            if layer.mask !== mask {
                original = layer.mask
                layer.mask = mask
            }
            CATransaction.commit()
        }

        func restore() {
            guard let layer, layer.mask === mask else { return }
            layer.mask = original
        }
    }
}
