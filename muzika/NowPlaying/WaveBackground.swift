import MetalKit
import SwiftUI

struct WaveBackground: NSViewRepresentable {
    let palette: WavePalette
    let isActive: Bool
    let playback: PlaybackController
    var framesPerSecond = WaveClock.playerFramesPerSecond

    func makeCoordinator() -> UUID { UUID() }

    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return NSView() }
        return WaveMetalView(device: device, queue: queue, framesPerSecond: framesPerSecond)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? WaveMetalView else { return }
        let client = context.coordinator
        view.palette = palette
        view.spectrum = { [weak playback] in playback?.spectrum() ?? [] }
        view.onActivityChange = { [weak playback] active in playback?.setSpectrumEnabled(active, from: client) }
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: NSView, coordinator: UUID) {
        guard let view = view as? WaveMetalView else { return }
        view.isActive = false
        view.spectrum = nil
        view.onActivityChange = nil
    }
}

struct WavePresentation {
    private(set) var size: CGSize = .zero
    private(set) var hasFrame = false
    private var active = false
    private var rendering = false
    private var generation: UInt64 = 0

    var canDraw: Bool { active && !rendering && size != .zero }

    mutating func update(active: Bool, size: CGSize) -> Bool {
        guard self.active != active || self.size != size else { return false }
        self.active = active
        self.size = size
        invalidate()
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        hasFrame = false
    }

    mutating func submit() -> UInt64 {
        rendering = true
        return generation
    }

    mutating func complete(_ frame: UInt64, succeeded: Bool) -> Bool {
        rendering = false
        guard frame == generation else { return false }
        hasFrame = succeeded
        return succeeded
    }
}

private final class WaveMetalView: MTKView, MTKViewDelegate {
    var palette = WavePalette.defaultPalette
    var spectrum: (@MainActor () -> [Float])?
    var onActivityChange: (@MainActor (Bool) -> Void)?
    var isActive = false {
        didSet {
            if isActive != oldValue { updatePresentation() }
        }
    }

    private let queue: any MTLCommandQueue
    private lazy var imageContext = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
    private var clock: WaveClock
    private var scene = WaveScene()
    private var presentation = WavePresentation()
    private var pendingFrame: (drawable: any CAMetalDrawable, image: CIImage)?
    private var presentedImage: CIImage?

    init(device: any MTLDevice, queue: any MTLCommandQueue, framesPerSecond: Int) {
        self.queue = queue
        clock = WaveClock(framesPerSecond: framesPerSecond)
        super.init(frame: .zero, device: device)
        isPaused = true
        preferredFramesPerSecond = framesPerSecond
        autoResizeDrawable = false
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        colorspace = WaveScene.colorSpace
        presentsWithTransaction = true
        layer?.isOpaque = false
        layer?.opacity = 0
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        setPaused(true)
        _ = presentation.update(active: false, size: .zero)
        showFallback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowVisibilityChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        layer?.isOpaque = false
        showFallback()
        updatePresentation()
    }

    override func layout() {
        super.layout()
        updatePresentation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePresentation()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        updatePresentation()
        guard presentation.canDraw, let spectrum,
              let elapsed = clock.delta(at: ProcessInfo.processInfo.systemUptime) else { return }
        let size = presentation.size
        let extent = CGRect(origin: .zero, size: size)
        let frame = scene.frame(palette: palette, spectrum: spectrum(), delta: elapsed, extent: extent)
        guard frame !== presentedImage,
              let buffer = queue.makeCommandBuffer(),
              let drawable = view.currentDrawable,
              drawable.texture.width == Int(size.width),
              drawable.texture.height == Int(size.height) else { return }

        let generation = presentation.submit()
        pendingFrame = (drawable, frame)
        imageContext.render(frame, to: drawable.texture, commandBuffer: buffer, bounds: extent, colorSpace: WaveScene.colorSpace)
        buffer.addCompletedHandler { [weak self] completed in
            let succeeded = completed.status == .completed
            Task { @MainActor [weak self] in
                self?.present(generation: generation, succeeded: succeeded)
            }
        }
        buffer.commit()
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        updatePresentation()
    }

    private func updatePresentation() {
        let active = isActive && window?.occlusionState.contains(.visible) == true
        let size = WaveScene.drawableSize(for: convertToBacking(bounds).size)
        if presentation.update(active: active, size: size) {
            showFallback()
            clock = WaveClock(framesPerSecond: preferredFramesPerSecond)
        }
        if size != .zero && drawableSize != size { drawableSize = size }
        setPaused(!active || size == .zero)
    }

    private func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        onActivityChange?(!paused)
    }

    private func showFallback() {
        presentedImage = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.removeAnimation(forKey: "waveReveal")
        layer?.opacity = 0
        CATransaction.commit()
    }

    private func present(generation: UInt64, succeeded: Bool) {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        updatePresentation()
        let valid = succeeded && frame.drawable.layer === layer
        let revealingFirstFrame = !presentation.hasFrame
        guard presentation.complete(generation, succeeded: valid) else {
            if !presentation.hasFrame { showFallback() }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame.drawable.present()
        layer?.opacity = 1
        if revealingFirstFrame {
            let reveal = CABasicAnimation(keyPath: "opacity")
            reveal.fromValue = 0
            reveal.toValue = 1
            reveal.duration = 0.22
            reveal.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(reveal, forKey: "waveReveal")
        }
        CATransaction.commit()
        presentedImage = frame.image
    }
}
