import CoreGraphics

struct LyricsScrollGeometry {
    let anchor: CGFloat
    let gapExtent: CGFloat
    private let viewportHeight: CGFloat
    private let topInset: CGFloat
    private let bottomInset: CGFloat
    private let heights: [CGFloat]
    private let origins: [CGFloat]
    private let rowsHeight: CGFloat

    init(heights: [CGFloat], spacing: CGFloat, viewportHeight: CGFloat, topOverflow: CGFloat, hasLeadingGap: Bool) {
        self.heights = heights
        self.viewportHeight = viewportHeight
        anchor = max(0, (viewportHeight + topOverflow) * 0.36 - topOverflow)
        gapExtent = 28 + spacing
        topInset = anchor + (hasLeadingGap ? gapExtent : 0)
        bottomInset = max(0, viewportHeight - anchor - topOverflow)
        var next: CGFloat = 0
        origins = heights.map { height in
            defer { next += height + spacing }
            return next
        }
        rowsHeight = heights.isEmpty ? 0 : next - spacing
    }

    func contentHeight(gapBefore: Int?) -> CGFloat {
        max(viewportHeight, topInset + rowsHeight + bottomInset + (gapBefore == nil ? 0 : gapExtent))
    }

    func y(forRow index: Int, gapBefore: Int?) -> CGFloat {
        topInset + origins[index] + (index >= (gapBefore ?? heights.count) ? gapExtent : 0)
    }

    func offset(forRow index: Int, gapBefore: Int?) -> CGFloat {
        y(forRow: index, gapBefore: gapBefore) - anchor
    }

    func y(forGapBefore index: Int) -> CGFloat {
        topInset + origins[index]
    }

    func offset(forGapBefore index: Int) -> CGFloat {
        y(forGapBefore: index) - anchor
    }

    func rows(in bounds: Range<CGFloat>, gapBefore: Int?) -> Range<Int> {
        let first = lowerBound { y(forRow: $0, gapBefore: gapBefore) + heights[$0] > bounds.lowerBound }
        let end = lowerBound { y(forRow: $0, gapBefore: gapBefore) >= bounds.upperBound }
        return first..<max(first, end)
    }

    func row(at position: CGFloat, gapBefore: Int?) -> Int? {
        let index = lowerBound { y(forRow: $0, gapBefore: gapBefore) > position } - 1
        guard index >= 0, position < y(forRow: index, gapBefore: gapBefore) + heights[index] else { return nil }
        return index
    }

    private func lowerBound(where matches: (Int) -> Bool) -> Int {
        var lower = 0
        var upper = heights.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if matches(middle) { upper = middle }
            else { lower = middle + 1 }
        }
        return lower
    }
}
