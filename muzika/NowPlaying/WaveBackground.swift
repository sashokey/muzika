import MetalKit
import SwiftUI

enum WaveActivity {
    case inactive
    case playing
    case paused
}

struct WaveBackground: NSViewRepresentable {
    let palette: WavePalette
    let activity: WaveActivity
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
        view.activity = activity
    }

    static func dismantleNSView(_ view: NSView, coordinator: UUID) {
        guard let view = view as? WaveMetalView else { return }
        view.activity = .inactive
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
    var activity = WaveActivity.inactive {
        didSet {
            if activity != oldValue {
                #if MUZIKA_DEV_LOGS
                MuzikaTrace.event(.player, "waves.activity", "from=\(oldValue) to=\(activity) target_fps=\(preferredFramesPerSecond)")
                waveFrames = MuzikaFrameMetrics()
                #endif
                updatePresentation()
            }
        }
    }

    private static let opacityAnimationKey = "waveOpacity"
    private let queue: any MTLCommandQueue
    private lazy var imageContext = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
    private var clock: WaveClock
    private var scene = WaveScene()
    private var presentation = WavePresentation()
    private var pendingFrame: (drawable: any CAMetalDrawable, image: CIImage)?
    private var presentedImage: CIImage?
    #if MUZIKA_DEV_LOGS
    private var waveFrames = MuzikaFrameMetrics()
    #endif

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
        #if MUZIKA_DEV_LOGS
        waveFrames.record(at: ProcessInfo.processInfo.systemUptime)
        waveFrames.reportIfReady(.player, "waves.submitted-frames")
        #endif
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        updatePresentation()
    }

    private func updatePresentation() {
        let size = WaveScene.drawableSize(for: convertToBacking(bounds).size)
        let visible = window?.occlusionState.contains(.visible) == true && size != .zero
        let active = activity == .playing && visible
        let clearsFrame = !visible || activity == .inactive || size != presentation.size
        let fadesFrame = activity == .paused && !clearsFrame && presentation.hasFrame
        if presentation.update(active: active, size: size) {
            presentedImage = nil
            clock = WaveClock(framesPerSecond: preferredFramesPerSecond)
        }
        if clearsFrame {
            showFallback()
        } else if fadesFrame {
            setWaveOpacity(0, animated: true)
        }
        if size != .zero && drawableSize != size { drawableSize = size }
        setPaused(!active)
    }

    private func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        onActivityChange?(!paused)
    }

    private func showFallback() {
        presentedImage = nil
        guard let layer, layer.opacity != 0 || layer.animation(forKey: Self.opacityAnimationKey) != nil else { return }
        setWaveOpacity(0, animated: false)
    }

    private func setWaveOpacity(_ opacity: Float, animated: Bool) {
        guard let layer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.opacityAnimationKey)
        layer.opacity = opacity
        if animated && current != opacity {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = current
            animation.toValue = opacity
            animation.duration = 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: Self.opacityAnimationKey)
        }
        CATransaction.commit()
    }

    private func present(generation: UInt64, succeeded: Bool) {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        updatePresentation()
        let valid = succeeded && frame.drawable.layer === layer
        let revealingFirstFrame = !presentation.hasFrame
        guard presentation.complete(generation, succeeded: valid) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame.drawable.present()
        if revealingFirstFrame {
            setWaveOpacity(1, animated: true)
        }
        CATransaction.commit()
        presentedImage = frame.image
    }
}
