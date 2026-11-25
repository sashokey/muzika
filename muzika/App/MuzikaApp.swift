import AppKit
import SwiftUI

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
        .windowStyle(.titleBar)
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
