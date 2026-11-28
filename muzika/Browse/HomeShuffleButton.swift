import AppKit
import QuartzCore
import SwiftUI

func shuffleGlowNeedsClipping(frame: CGRect, movingBy offset: CGPoint, inside bounds: CGRect) -> Bool {
    let traveledFrame = frame.union(frame.offsetBy(dx: offset.x, dy: offset.y))
    return !bounds.contains(traveledFrame)
}

struct HomeShuffleButton: View {
    let allowsMotion: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    @State private var visible = false

    var body: some View {
        let animates = allowsMotion && visible && scenePhase == .active && !reduceMotion

        ZStack {
            ShuffleGlow(animates: animates)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Button(action: action) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.65), radius: 8, y: 1)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 58)
                    .overlay {
                        if focused {
                            Capsule().strokeBorder(.white.opacity(0.78), lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .buttonPointer()
            .focused($focused)
            .liquidGlassHover(in: Capsule(), outset: .zero, stableTracking: true)
        }
        .frame(maxWidth: 620)
        .frame(height: 218)
        .onScrollVisibilityChange(threshold: 0.25) { visible = $0 }
        .frame(maxWidth: .infinity)
    }
}

private struct ShuffleGlow: NSViewRepresentable {
    let animates: Bool

    func makeNSView(context: Context) -> GlowView { GlowView() }

    func updateNSView(_ view: GlowView, context: Context) {
        view.setAnimating(animates)
    }

    final class GlowView: NSView {
        private static let framesPerSecond = 20
        private static let cycle = 12
        private static let displacement = CGPoint(x: 13, y: -5)
        private static let steps = framesPerSecond * cycle
        private static let keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        private static let offsets = (0..<steps).map { step in
            let phase = 2 * Double.pi * Double(step) / Double(steps)
            let shift = (1 - cos(phase)) / 2
            return NSValue(point: CGPoint(x: displacement.x * shift, y: displacement.y * shift))
        }
        private static let texture: CGImage? = {
            guard let url = Bundle.main.url(forResource: "ShuffleGlow", withExtension: "png") else { return nil }
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                          bitmapInfo: bitmap) else { return image }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context.makeImage() ?? image
        }()

        private let glow = CALayer()
        private var animates = false
        private var laidOutSize = CGSize.zero

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            glow.contents = Self.texture
            layer?.addSublayer(glow)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            guard bounds.size != laidOutSize else { return }
            laidOutSize = bounds.size
            let span = min(bounds.width, bounds.height * 2.25)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.bounds = CGRect(x: 0, y: 0, width: span * 300 / 320, height: bounds.height * 112 / 144)
            glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
            layer?.masksToBounds = shuffleGlowNeedsClipping(frame: glow.frame, movingBy: Self.displacement, inside: bounds)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateAnimation()
        }

        func setAnimating(_ animates: Bool) {
            guard self.animates != animates else { return }
            self.animates = animates
            updateAnimation()
        }

        private func updateAnimation() {
            guard animates, window != nil, glow.contents != nil else {
                glow.removeAnimation(forKey: "drift")
                return
            }
            guard glow.animation(forKey: "drift") == nil else { return }
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.values = Self.offsets
            drift.keyTimes = Self.keyTimes
            drift.calculationMode = .discrete
            drift.isAdditive = true
            drift.duration = Double(Self.cycle)
            let rate = Float(Self.framesPerSecond)
            drift.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: rate, preferred: rate)
            drift.repeatCount = .infinity
            glow.add(drift, forKey: "drift")
        }
    }
}
