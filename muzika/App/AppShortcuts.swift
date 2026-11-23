import AppKit
import SwiftUI

extension Notification.Name {
    static let refreshLibraryPage = Self("refreshLibraryPage")
}

enum ShortcutGroup: CaseIterable, Identifiable {
    case file, controls, navigation, view

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .file: "File"
        case .controls: "Controls"
        case .navigation: "Navigation"
        case .view: "View"
        }
    }
}

enum AppShortcut: CaseIterable, Identifiable {
    case files, folder
    case playPause, previous, next, volumeUp, volumeDown
    case home, library, search, settings, back, forward, refresh, dismiss
    case lyrics, queue, fullscreen

    var id: Self { self }

    var group: ShortcutGroup {
        switch self {
        case .files, .folder: .file
        case .playPause, .previous, .next, .volumeUp, .volumeDown: .controls
        case .home, .library, .search, .settings, .back, .forward, .refresh, .dismiss: .navigation
        case .lyrics, .queue, .fullscreen: .view
        }
    }

    var title: String {
        switch self {
        case .files: String(localized: "Open audio files")
        case .folder: String(localized: "Play folder")
        case .playPause: String(localized: "Play/Pause")
        case .previous: String(localized: "Previous track")
        case .next: String(localized: "Next track")
        case .volumeUp: String(localized: "Increase volume")
        case .volumeDown: String(localized: "Decrease volume")
        case .home: String(localized: "Home")
        case .library: String(localized: "Library")
        case .search: String(localized: "Search")
        case .settings: String(localized: "Settings")
        case .back: String(localized: "Back")
        case .forward: String(localized: "Forward")
        case .refresh: String(localized: "Refresh")
        case .dismiss: String(localized: "Close dialog or page")
        case .lyrics: String(localized: "Lyrics")
        case .queue: String(localized: "Up Next")
        case .fullscreen: String(localized: "Full screen")
        }
    }

    var key: KeyEquivalent? {
        switch self {
        case .files, .folder: "o"
        case .playPause, .dismiss, .fullscreen: nil
        case .previous: .leftArrow
        case .next: .rightArrow
        case .volumeUp: .upArrow
        case .volumeDown: .downArrow
        case .home: "1"
        case .library: "2"
        case .search: "f"
        case .settings: ","
        case .back: "["
        case .forward: "]"
        case .refresh: "r"
        case .lyrics: "l"
        case .queue: "u"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .folder, .lyrics, .queue: [.command, .shift]
        case .fullscreen: [.command, .control]
        default: .command
        }
    }

    var hint: String {
        switch self {
        case .playPause: return String(localized: "Space")
        case .dismiss: return "⎋"
        case .fullscreen: return "⌃⌘F · F11"
        case .settings: return "⌘, · ⌘4"
        default:
            let prefixes = (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.shift) ? "⇧" : "") + "⌘"
            let symbol: String = switch key {
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .upArrow: "↑"
            case .downArrow: "↓"
            case let value?: String(value.character).uppercased()
            case nil: ""
            }
            return prefixes + symbol
        }
    }

    @MainActor
    func enabled(in state: AppState) -> Bool {
        switch self {
        case .playPause, .previous, .next, .lyrics, .queue: state.playback.current != nil
        case .back, .dismiss: state.canGoBack
        case .forward: state.canGoForward
        default: true
        }
    }

    @MainActor
    func perform(in state: AppState) {
        switch self {
        case .files: state.chooseFiles()
        case .folder: state.chooseFiles(folder: true)
        case .playPause: state.playback.togglePlayback()
        case .previous: state.playback.previous()
        case .next: state.playback.next()
        case .volumeUp: state.setVolume(state.playback.volume + 0.05)
        case .volumeDown: state.setVolume(state.playback.volume - 0.05)
        case .home: state.navigate(.home)
        case .library: state.openLibrary()
        case .search: state.navigate(.search)
        case .settings: state.navigate(.settings)
        case .back: state.back()
        case .forward: state.forward()
        case .refresh: state.refresh()
        case .dismiss: state.dismiss()
        case .lyrics: state.togglePanel(.lyrics)
        case .queue: state.togglePanel(.queue)
        case .fullscreen: NSApp.keyWindow?.toggleFullScreen(nil)
        }
    }
}

struct MuzikaCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(ApplicationMetadata.name)") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: ApplicationMetadata.name,
                    .applicationVersion: ApplicationMetadata.version,
                    .version: ApplicationMetadata.build
                ])
            }
        }
        CommandGroup(replacing: .appSettings) { menu(.settings) }
        CommandGroup(replacing: .newItem) {
            menu(.files)
            menu(.folder)
        }
        CommandMenu("Controls") {
            menu(.playPause)
            menu(.previous)
            menu(.next)
            Divider()
            menu(.volumeUp)
            menu(.volumeDown)
        }
        CommandMenu("Navigation") {
            menu(.home)
            menu(.library)
            menu(.search)
            menu(.settings, key: "4")
            Divider()
            menu(.back)
            menu(.forward)
            menu(.refresh)
        }
        CommandGroup(after: .toolbar) {
            menu(.lyrics)
            menu(.queue)
        }
    }

    @ViewBuilder
    private func menu(_ command: AppShortcut, key override: KeyEquivalent? = nil) -> some View {
        let button = Button(command.title) { command.perform(in: state) }
            .disabled(!command.enabled(in: state))
        if let key = override ?? command.key {
            button.keyboardShortcut(key, modifiers: command.modifiers)
        } else {
            button
        }
    }
}
