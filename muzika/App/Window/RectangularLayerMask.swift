import AppKit
import QuartzCore

@MainActor
final class RectangularLayerMask {
    private(set) weak var layer: CALayer?
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
