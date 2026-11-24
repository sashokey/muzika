import AppKit
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

@main
struct MuzikaApp: App {
    @NSApplicationDelegateAdaptor private var audioFiles: AudioFileOpenDelegate
    @State private var state = AppState()

    var body: some Scene {
        Window(ApplicationMetadata.name, id: "library") {
            MainWindow(state: state)
                .onAppear { audioFiles.attach(state) }
        }
        .defaultSize(width: 1250, height: 880)
        .windowResizability(.contentMinSize)
        .commands { MuzikaCommands(state: state) }
    }
}

@MainActor
private final class AudioFileOpenDelegate: NSObject, NSApplicationDelegate {
    private weak var state: AppState?
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let state {
            state.open(urls)
        } else {
            pending.append(contentsOf: urls)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.playback.flush()
        state?.history.flush()
    }

    func attach(_ state: AppState) {
        self.state = state
        guard !pending.isEmpty else { return }
        state.open(pending)
        pending.removeAll()
    }
}

private struct MainWindow: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.controlSize) private var controlSize
    @State private var shortcutMonitor: Any?
    @State private var showDrop = false
    @State private var libraryToolbarInset: CGFloat?

    var body: some View {
        let navigation = Binding(get: { state.route }, set: { state.navigate($0) })
        let scanSchedule = state.scanSchedule
        let playerAnimation: Animation? = reduceMotion ? nil : .easeInOut(duration: state.preferences.heroAnimations ? 0.22 : 0.14)
        ZStack {
            GeometryReader { geometry in
                let inset = geometry.safeAreaInsets.top
                LibraryShell(
                    library: state.library, playback: state.playback, history: state.history,
                    route: navigation, goBack: state.back, playbackArtworkIsVisible: !state.showingPlayer
                ) {
                    PlayerCapsule(state: state)
                } settings: {
                    PreferencesView(state: state)
                }
                .environment(state.preferences)
                .padding(.top, max(0, (libraryToolbarInset ?? inset) - inset))
            }
            .accessibilityHidden(state.showingPlayer)
            .allowsHitTesting(!state.showingPlayer)

            if state.showingPlayer, state.playback.current != nil {
                NowPlayingView(state: state, openingAnimation: playerAnimation) { inset in
                    if inset != nil || !state.showingPlayer { libraryToolbarInset = inset }
                }
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    .zIndex(1)
            }
        }
        .onChange(of: state.route) { _, _ in libraryToolbarInset = nil }
        .toolbar(removing: .title)
        .animation(playerAnimation, value: state.showingPlayer)
        .dynamicTypeSize(state.preferences.largerInterface ? max(typeSize, .xxLarge) : typeSize)
        .controlSize(state.preferences.largerInterface ? .large : controlSize)
        .frame(minWidth: 690, minHeight: 520)
        .background(WindowTitlebar(showsTitle: !state.showingPlayer))
        .overlay(alignment: .topTrailing) {
            if state.importing {
                ProgressView("Opening audio…")
                    .controlSize(.small)
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .padding(18)
            }
        }
        .overlay {
            if showDrop {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $showDrop, perform: receive)
        .task { state.start() }
        .task(id: scanSchedule) { await state.runScheduledScans(scanSchedule) }
        .onChange(of: state.library.revision) { _, _ in
            state.playback.reconcileLibrary()
        }
        .onAppear { installKeyboard() }
        .onDisappear {
            if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
            shortcutMonitor = nil
        }
        .onChange(of: state.playback.current == nil) { _, empty in
            if empty { state.closePlayer() }
        }
        .onChange(of: state.playback.playbackError) { _, message in
            if let message { state.message = message }
        }
        .alert("Audio files", isPresented: Binding(
            get: { state.message != nil },
            set: { if !$0 { state.message = nil } }
        )) {
            Button("OK", role: .cancel) { state.message = nil }
        } message: {
            Text(state.message ?? "")
        }
        .alert("Confirm loud volume", isPresented: Binding(
            get: { state.pendingVolume != nil },
            set: { if !$0 { state.pendingVolume = nil } }
        )) {
            Button("Cancel", role: .cancel) { state.pendingVolume = nil }
            Button("Increase volume") { state.acceptVolume() }
        } message: {
            if let value = state.pendingVolume { Text("Increase the volume to \(value.formatted(.percent))?") }
        }
    }

    private func installKeyboard() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak state] event in
            guard let state, event.window == NSApp.keyWindow, let window = event.window,
                  window.attachedSheet == nil, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else { return event }
            if event.keyCode == 103 {
                AppShortcut.fullscreen.perform(in: state)
                return nil
            }
            if event.keyCode == 49, !NSApp.isFullKeyboardAccessEnabled,
               !(window.firstResponder is NSTextView), !(window.firstResponder is NSControl),
               AppShortcut.playPause.enabled(in: state) {
                if !event.isARepeat { AppShortcut.playPause.perform(in: state) }
                return nil
            }
            if event.keyCode == 53, AppShortcut.dismiss.enabled(in: state),
               !(window.firstResponder is NSTextView) {
                AppShortcut.dismiss.perform(in: state)
                return nil
            }
            return event
        }
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let results = Mutex(Array<URL?>(repeating: nil, count: providers.count))
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { value, _ in
                defer { group.leave() }
                if let url = value as? NSURL {
                    results.withLock { $0[index] = url as URL }
                }
            }
        }
        group.notify(queue: .main) { [state] in
            state.open(results.withLock { $0.compactMap { $0 } })
        }
        return true
    }
}

private struct WindowTitlebar: NSViewRepresentable {
    var showsTitle: Bool

    func makeNSView(context: Context) -> TitlebarView { TitlebarView() }

    func updateNSView(_ view: TitlebarView, context: Context) {
        view.showsTitle = showsTitle
    }

    final class TitlebarView: NSView {
        var showsTitle = true {
            didSet {
                if let window, showsTitle != oldValue { updateAccessory(in: window) }
            }
        }

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

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window, window !== newWindow,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            updateAccessory(in: window)
        }

        private func updateAccessory(in window: NSWindow) {
            let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory)
            if showsTitle {
                if index == nil { window.addTitlebarAccessoryViewController(accessory) }
            } else if let index {
                window.removeTitlebarAccessoryViewController(at: index)
            }
        }
    }
}
