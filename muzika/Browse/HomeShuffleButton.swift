import AppKit
import QuartzCore
import SwiftUI

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
        private static let cycle: CFTimeInterval = 12
        private static let keyframeCount = 30 * Int(cycle)
        private static let keyTimes = (0...keyframeCount).map { NSNumber(value: Double($0) / Double(keyframeCount)) }
        private static let textures = [
            (red: 56, green: 94, blue: 235, opacity: 0.86),
            (red: 140, green: 59, blue: 227, opacity: 0.74),
            (red: 26, green: 171, blue: 196, opacity: 0.74),
            (red: 71, green: 79, blue: 212, opacity: 0.74)
        ].enumerated().compactMap { index, color in
            makeTexture(red: color.red, green: color.green, blue: color.blue,
                        opacity: color.opacity, phase: Double(index) * .pi / 2)
        }

        private let plumes = GlowView.textures.map { image in
            let plume = CALayer()
            plume.contents = image
            return plume
        }
        private var animates = false
        private var laidOutSize = CGSize.zero

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            for plume in plumes { layer?.addSublayer(plume) }
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            guard bounds.size != laidOutSize else { return }
            laidOutSize = bounds.size
            updatePlumes()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePlumes()
        }

        func setAnimating(_ animates: Bool) {
            guard self.animates != animates else { return }
            self.animates = animates
            updatePlumes()
        }

        private func updatePlumes() {
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let span = min(size.width, size.height * 2.25)
            let now = CACurrentMediaTime()
            let phase = now.truncatingRemainder(dividingBy: Self.cycle)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            for (index, plume) in plumes.enumerated() {
                let offset = Double(index) * .pi / 2
                func placement(_ angle: Double) -> (position: CGPoint, transform: CATransform3D) {
                    let drift = angle + offset
                    let position = CGPoint(
                        x: size.width / 2 + span * 0.105 * cos(drift),
                        y: size.height / 2 - size.height * 0.10 * sin(drift - offset * 0.4)
                    )
                    let tilt = 0.16 * sin(drift + offset)
                    let rotation = CATransform3DMakeRotation(tilt, 0, 0, 1)
                    let transform = CATransform3DScale(rotation, 1 + 0.13 * sin(drift),
                                                       1 + 0.15 * cos(drift * 2), 1)
                    return (position, transform)
                }

                let resting = placement(0)
                plume.bounds = CGRect(x: 0, y: 0, width: span * 0.65, height: size.height * 0.80)
                plume.position = resting.position
                plume.transform = resting.transform
                plume.removeAnimation(forKey: "drift")
                guard animates, window != nil else { continue }

                let frames = (0..<Self.keyframeCount).map {
                    placement(Double($0) * 2 * .pi / Double(Self.keyframeCount))
                }
                let motion = CAKeyframeAnimation(keyPath: "position")
                motion.values = frames.map { NSValue(point: $0.position) }
                motion.calculationMode = .discrete
                motion.keyTimes = Self.keyTimes
                let deformation = CAKeyframeAnimation(keyPath: "transform")
                deformation.values = frames.map { NSValue(caTransform3D: $0.transform) }
                deformation.calculationMode = .discrete
                deformation.keyTimes = Self.keyTimes
                motion.duration = Self.cycle
                deformation.duration = Self.cycle

                let drift = CAAnimationGroup()
                drift.animations = [motion, deformation]
                drift.duration = Self.cycle
                drift.repeatCount = .infinity
                drift.beginTime = plume.convertTime(now - phase, from: nil)
                plume.add(drift, forKey: "drift")
            }
        }

        private static func makeTexture(red: Int, green: Int, blue: Int, opacity: Double, phase: Double) -> CGImage? {
            let side = 128
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            for row in 0..<side {
                let y = (Double(row) + 0.5) / Double(side) * 2 - 1
                for column in 0..<side {
                    let x = (Double(column) + 0.5) / Double(side) * 2 - 1
                    let angle = atan2(y, x)
                    let edge = 0.82 + 0.09 * sin(angle * 3 + phase) + 0.06 * cos(angle * 2 - phase)
                    let fade = max(0, 1 - hypot(x, y) / edge)
                    let alpha = opacity * fade * fade * (3 - 2 * fade)
                    let pixel = (row * side + column) * 4
                    bytes[pixel] = UInt8((Double(red) * alpha).rounded())
                    bytes[pixel + 1] = UInt8((Double(green) * alpha).rounded())
                    bytes[pixel + 2] = UInt8((Double(blue) * alpha).rounded())
                    bytes[pixel + 3] = UInt8((255 * alpha).rounded())
                }
            }
            guard let data = CGDataProvider(data: Data(bytes) as CFData),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: side * 4, space: colorSpace,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: data, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}
