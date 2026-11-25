import AppKit
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

struct MainWindow: View {
    let state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.controlSize) private var controlSize
    @State private var shortcutMonitor: Any?
    @State private var showDrop = false
    @State private var libraryToolbarInset: CGFloat?

    var body: some View {
        let scanSchedule = state.scanSchedule
        let playerAnimation: Animation? = reduceMotion ? nil : .easeInOut(duration: state.preferences.heroAnimations ? 0.22 : 0.14)
        ZStack {
            GeometryReader { geometry in
                let inset = geometry.safeAreaInsets.top
                LibraryShell(
                    state: state, playbackArtworkIsVisible: !state.showingPlayer,
                    titlebarInset: state.showingPlayer ? 0 : inset,
                    detailWidth: max(0, geometry.size.width - BrowseLayout.detailLeadingInset),
                    onRouteChange: {
                        if libraryToolbarInset != nil { libraryToolbarInset = nil }
                    }
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
        #if MUZIKA_DEV_LOGS
        .background {
            AnimationTraceProbe(
                area: .player,
                state: "visible=\(state.showingPlayer) panel=\(MuzikaTrace.panelName(state.panel)) route=\(MuzikaTrace.routeName(state.route)) reduce_motion=\(reduceMotion) hero=\(state.preferences.heroAnimations)",
                observesWindow: true
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onChange(of: state.settingsPage) { _, page in
            MuzikaTrace.event(.library, "settings.page", "page=\(page?.rawValue ?? "closed")")
        }
        #endif
        .toolbar(removing: .title)
        .animation(playerAnimation, value: state.showingPlayer)
        .dynamicTypeSize(state.preferences.largerInterface ? max(typeSize, .xxLarge) : typeSize)
        .controlSize(state.preferences.largerInterface ? .large : controlSize)
        .frame(minWidth: 690, minHeight: 520)
        .libraryWindowTitlebar(showsTitle: !state.showingPlayer)
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
