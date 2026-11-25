import AppKit
import SwiftUI

@MainActor
struct LibraryShell<Player: View, Settings: View>: View {
    let state: AppState
    var playbackArtworkIsVisible = true
    var titlebarInset: CGFloat = 0
    let detailWidth: CGFloat
    var onRouteChange: (() -> Void)? = nil
    @ViewBuilder let player: () -> Player
    @ViewBuilder let settings: () -> Settings

    var body: some View {
        let hasPlayer = state.playback.current != nil
        let footerInset: CGFloat = hasPlayer ? 72 : 0
        HStack(spacing: 0) {
            LibrarySidebar(state: state)

            Divider()
                .frame(width: BrowseLayout.dividerWidth)
                .ignoresSafeArea(.container, edges: .top)

            LibraryPages(state: state, playbackArtworkIsVisible: playbackArtworkIsVisible,
                         titlebarInset: titlebarInset, onRouteChange: onRouteChange, settings: settings)
                .frame(width: detailWidth)
                .contentMargins(.bottom, -footerInset, for: .scrollIndicators)
                .safeAreaPadding(.bottom, footerInset)
                .overlay(alignment: .bottom) {
                    if hasPlayer {
                        player()
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                    }
                }
        }
        .environment(\.libraryPlaybackEffectsVisible, playbackArtworkIsVisible)
    }
}

private struct LibrarySidebar: View {
    let state: AppState

    private static let categories: [LibraryRoute] = [.recentlyAdded, .artists, .albums, .songs, .genres, .folders]

    var body: some View {
        let selected = state.route.sidebarRoute
        List(selection: selection) {
            item(.search, selected: selected)
            item(.home, selected: selected)

            Section("Library") {
                ForEach(Self.categories, id: \.self) { item($0, selected: selected) }
            }

            item(.settings, selected: selected)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden(true, for: .top)
        .frame(width: BrowseLayout.sidebarWidth)
        .hideTitlebarScrollEdge(enabled: state.route != .songs)
        .background {
            LibrarySidebarBackground()
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Sidebar")
    }

    private var selection: Binding<LibraryRoute?> {
        Binding(
            get: { state.route.sidebarRoute },
            set: { destination in
                guard let destination, destination != state.route else { return }
                state.navigate(destination)
            }
        )
    }

    private func item(_ destination: LibraryRoute, selected: LibraryRoute) -> some View {
        LibrarySidebarEntry(destination: destination, selected: destination == selected)
            .equatable()
            .tag(destination)
    }
}

private struct LibrarySidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct LibrarySidebarEntry: View, Equatable {
    let destination: LibraryRoute
    let selected: Bool

    var body: some View {
        Label(destination.title, systemImage: destination.symbol)
            .liquidGlassSidebarHover(selectionTint: selected)
    }
}

@MainActor
private struct LibraryPages<Settings: View>: View {
    let state: AppState
    let playbackArtworkIsVisible: Bool
    let titlebarInset: CGFloat
    let onRouteChange: (() -> Void)?
    @ViewBuilder let settings: () -> Settings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Preferences.self) private var preferences: Preferences?
    @State private var searchQuery = ""
    @State private var searchScope = BrowseSearchScope.all
    @State private var lyricIndex = BrowseLyricsIndex()
    @State private var groupIndex = LibraryGroupIndex()

    private var library: LibraryStore { state.library }
    private var playback: PlaybackController { state.playback }
    private var route: LibraryRoute { state.route }

    var body: some View {
        let revision = LibraryGroupIndex.Revision(of: library)
        let requiresData = needsBrowseSnapshot
        let snapshot = requiresData ? groupIndex.snapshot(for: revision) : nil
        ZStack {
            Group {
                if requiresData && snapshot == nil {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    page(snapshot)
                }
            }
            .id(route)
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if titlebarInset > 0, !usesGlassHeader(snapshot) {
                GeometryReader { geometry in
                    BrowseGlassSurface().frame(width: geometry.size.width, height: titlebarInset)
                }
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .animation(!reduceMotion && preferences?.heroAnimations != false ? .easeInOut(duration: 0.14) : nil, value: route)
        .onChange(of: route) { _, _ in onRouteChange?() }
        .task(id: revision) {
            await groupIndex.prepare(library, revision: revision)
        }
    }

    private func usesGlassHeader(_ snapshot: LibraryBrowseSnapshot?) -> Bool {
        switch route {
        case .home, .recentlyAdded, .artists, .albums, .songs, .genres:
            snapshot != nil
        case .folders, .folder:
            true
        case .artist, .album, .genre:
            snapshot?.group(for: route) != nil
        case .search, .history, .statistics, .rewind, .settings:
            false
        }
    }

    private var needsBrowseSnapshot: Bool {
        switch route {
        case .home, .search, .recentlyAdded, .artists, .albums, .genres, .songs, .artist, .album, .genre:
            true
        case .history, .statistics, .rewind, .folders, .folder, .settings:
            false
        }
    }

    @ViewBuilder
    private func page(_ snapshot: LibraryBrowseSnapshot?) -> some View {
        switch route {
        case .home, .history, .statistics, .rewind:
            ListeningBrowser(
                route: route,
                library: library,
                playback: playback,
                history: state.history,
                recentAlbums: snapshot?.recentAlbums ?? [],
                navigate: state.navigate,
                back: state.back,
                playbackArtworkIsVisible: playbackArtworkIsVisible
            )
        case .search:
            LibrarySearchPage(
                query: $searchQuery, scope: $searchScope, lyricIndex: $lyricIndex,
                library: library, playback: playback, groupIndex: groupIndex, navigate: state.navigate
            )
        case .recentlyAdded:
            RecentlyAddedPage(
                library: library, playback: playback, albums: snapshot?.recentAlbums ?? [],
                navigate: state.navigate, addFolder: addFolder
            )
        case .artists:
            groupPage(snapshot?.artists ?? [])
        case .albums:
            groupPage(snapshot?.albums ?? [])
        case .genres:
            groupPage(snapshot?.genres ?? [])
        case .songs:
            TrackBrowserPage(
                title: route.title, tracks: snapshot?.songs ?? [], library: library, playback: playback,
                presorted: .title, glassHeader: true, highlightsCellsOnHover: false,
                usesUniformRows: true, usesSongsArtwork: true, navigate: state.navigate
            )
        case .folders, .folder:
            FolderBrowserPage(
                route: route, library: library, playback: playback, navigate: state.navigate,
                back: state.back, addFolder: addFolder
            )
        case .artist, .album, .genre:
            if let snapshot, let group = snapshot.group(for: route) {
                TrackBrowserPage(
                    title: group.title, subtitle: group.subtitle, artwork: group.artworkTrack,
                    tracks: group.tracks, library: library, playback: playback,
                    order: route.sidebarRoute == .albums ? .trackNumber : .title,
                    back: state.back, relatedAlbums: relatedAlbums(for: group, in: snapshot),
                    navigate: state.navigate
                )
            } else {
                VStack {
                    BrowseHeading(title: route.title, back: state.back) { EmptyView() }
                    BrowseEmpty(title: "No Longer Available", symbol: route.symbol)
                }
                .padding(.horizontal, 26)
            }
        case .settings:
            settings()
        }
    }

    private func groupPage(_ groups: [BrowseGroup]) -> some View {
        GroupBrowserPage(route: route, groups: groups, library: library, playback: playback, navigate: state.navigate)
    }

    private func relatedAlbums(for group: BrowseGroup, in snapshot: LibraryBrowseSnapshot) -> [BrowseGroup] {
        guard case .artist = group.route else { return [] }
        let routes = Set(group.tracks.lazy.map { BrowseGroup.albumRoute($0.albumKey) })
        return snapshot.albums.filter { routes.contains($0.route) }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add Library Folders")
        panel.prompt = String(localized: "Add")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls {
                    await library.addSource(url)
                }
            }
        }
    }
}

@MainActor
@Observable
final class LibraryGroupIndex {
    struct Revision: Hashable {
        let library: ObjectIdentifier
        let number: Int

        @MainActor
        init(of library: LibraryStore) {
            self.library = ObjectIdentifier(library)
            number = library.revision
        }
    }

    private var prepared: (revision: Revision, snapshot: LibraryBrowseSnapshot)?
    @ObservationIgnored private var lastSearch: (revision: Revision, query: String, tracks: [AudioTrack])?

    func prepare(_ library: LibraryStore, revision: Revision) async {
        guard !Task.isCancelled, prepared?.revision != revision, Revision(of: library) == revision else { return }
        let tracks = library.tracks
        let worker = Task.detached(priority: .userInitiated) {
            LibraryBrowseSnapshot(tracks: tracks)
        }
        let snapshot = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, Revision(of: library) == revision, let snapshot else { return }
        prepared = (revision, snapshot)
    }

    func snapshot(for revision: Revision) -> LibraryBrowseSnapshot? {
        guard let prepared, prepared.revision == revision else { return nil }
        return prepared.snapshot
    }

    func groups(for category: LibraryRoute, in library: LibraryStore) -> [BrowseGroup] {
        snapshot(for: Revision(of: library))?.groups(for: category) ?? []
    }

    func tracksMatching(_ query: String, in library: LibraryStore) -> [AudioTrack] {
        let revision = Revision(of: library)
        if let lastSearch, lastSearch.revision == revision, lastSearch.query == query { return lastSearch.tracks }
        let tracks = library.matchingTracks(query)
        lastSearch = (revision, query, tracks)
        return tracks
    }
}

extension Notification.Name {
    static let focusLibrarySearch = Self("focusLibrarySearch")
}

@MainActor
private struct RecentlyAddedPage: View {
    private static let shortcutVerticalPadding: CGFloat = 9

    let library: LibraryStore
    let playback: PlaybackController
    let albums: [BrowseGroup]
    let navigate: (LibraryRoute) -> Void
    let addFolder: () -> Void

    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                if query.isEmpty {
                    quickLinks
                }
                Text(query.isEmpty ? "Recently Added" : "Albums")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                let terms = BrowseSearch.terms(query)
                let groups = terms.isEmpty ? albums : albums.filter {
                    BrowseSearch.matches(terms, fields: [$0.title, $0.subtitle])
                }
                if groups.isEmpty {
                    BrowseEmpty(
                        title: query.isEmpty ? "No Music Yet" : "No Matching Albums",
                        symbol: query.isEmpty ? "music.note.list" : "magnifyingglass",
                        detail: query.isEmpty ? "Add a folder to start your library." : nil
                    )
                    .padding(.vertical, 16)
                } else {
                    BrowseGroupGrid(
                        groups: groups, library: library, playback: playback, open: navigate
                    )
                }
            }
            .padding(.top, BrowseLayout.headerSpacing - (query.isEmpty ? Self.shortcutVerticalPadding : 0))
            .padding(.horizontal, 26)
            .padding(.bottom, 24)
        }
        .browseScrollUnderHeader()
        .browseGlassHeader {
            VStack(spacing: 0) {
                BrowseHeading(title: String(localized: "Library")) {
                    Button("Add Folder", systemImage: "folder.badge.plus", action: addFolder)
                        .buttonStyle(GlassHoverButtonStyle.action())
                        .disabled(library.isScanning)
                }
                status
            }
            .padding(.horizontal, 26)
        }
        .windowLibraryFilter(text: $query, prompt: "Filter Library")
    }

    @ViewBuilder
    private var status: some View {
        if library.isScanning {
            HStack {
                ProgressView().controlSize(.small)
                Text("Scanning Library…").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 12)
        } else if let error = library.scanError {
            Label(String(describing: error), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
        }
    }

    private var quickLinks: some View {
        VStack(spacing: 0) {
            ForEach([LibraryRoute.artists, .albums, .songs, .genres, .folders], id: \.self) { destination in
                Button {
                    navigate(destination)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: destination.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 17, alignment: .leading)
                        Text(destination.title)
                        Spacer()
                        Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, Self.shortcutVerticalPadding)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .liquidGlassHover()
            }
        }
        .padding(.bottom, 9)
    }
}

@MainActor
struct GroupBrowserPage: View {
    let route: LibraryRoute
    let groups: [BrowseGroup]
    let library: LibraryStore
    let playback: PlaybackController
    let navigate: (LibraryRoute) -> Void

    @State private var query = ""
    @State private var arrangement = GroupArrangement.title
    @State private var completeness: AlbumCompleteness?

    var body: some View {
        let groups = displayedGroups
        Group {
            if groups.isEmpty {
                BrowseEmpty(
                    title: query.isEmpty && completeness == nil ? emptyLibraryTitle : "No Matches",
                    symbol: route.symbol
                )
            } else {
                ScrollView {
                    Group {
                        if route == .albums {
                            BrowseGroupGrid(groups: groups, library: library, playback: playback, open: navigate)
                        } else {
                            BrowseGroupList(
                                groups: groups, library: library, playback: playback, open: navigate,
                                circular: route == .artists
                            )
                        }
                    }
                    .padding(.top, BrowseLayout.headerSpacing - (route == .albums ? 0 : BrowseGroupList.rowVerticalPadding))
                    .padding(.horizontal, 26)
                    .padding(.bottom, 22)
                }
                .browseScrollUnderHeader()
            }
        }
        .browseGlassHeader {
            BrowseHeading(title: route.title, subtitle: String(localized: "Total: \(self.groups.count)")) {
                BrowseHeaderMenus(menus: headerMenus)
            }
            .padding(.horizontal, 26)
        }
        .windowLibraryFilter(text: $query, prompt: filterPrompt)
    }

    private var headerMenus: [BrowseHeaderMenu] {
        let sort = BrowseHeaderMenu(id: .sort, title: "Sort", symbol: "arrow.up.arrow.down", entries:
            BrowseHeaderMenuEntry.choices(GroupArrangement.allCases, selection: $arrangement) { Text($0.displayTitle) }
        )
        guard route == .albums else { return [sort] }
        let filters = BrowseHeaderMenu(id: .filters, title: "Filters", symbol: "line.3.horizontal.decrease", entries: [
            .submenu("Album Completeness",
                BrowseHeaderMenuEntry.choices([nil] + AlbumCompleteness.allCases.map(Optional.some), selection: $completeness) {
                    if let status = $0 { Text(status.displayTitle) } else { Text("All Albums") }
                }
            )
        ])
        return [filters, sort]
    }

    private var emptyLibraryTitle: LocalizedStringResource {
        switch route {
        case .artists: "No Artists"
        case .albums: "No Albums"
        case .genres: "No Genres"
        default: "No Matches"
        }
    }

    private var filterPrompt: LocalizedStringResource {
        switch route {
        case .artists: "Filter Artists"
        case .albums: "Filter Albums"
        case .genres: "Filter Genres"
        default: "Filter Library"
        }
    }

    private var displayedGroups: [BrowseGroup] {
        let terms = BrowseSearch.terms(query)
        let groups: [BrowseGroup]
        if terms.isEmpty, completeness == nil {
            groups = self.groups
        } else {
            let unavailable = completeness == nil ? [] : library.sources.filter { $0.status == .unavailable }
            groups = self.groups.filter { group in
                guard BrowseSearch.matches(terms, fields: [group.title, group.subtitle]) else { return false }
                guard let completeness else { return true }
                return AlbumCompleteness(tracks: group.tracks, unavailable: unavailable) == completeness
            }
        }
        switch arrangement {
        case .title: return groups
        case .recentlyAdded: return groups.sorted { $0.latest > $1.latest }
        case .trackCount: return groups.sorted { $0.tracks.count > $1.tracks.count }
        }
    }

    private enum GroupArrangement: String, CaseIterable {
        case title = "Title"
        case recentlyAdded = "Date Added"
        case trackCount = "Song Count"

        var displayTitle: LocalizedStringResource {
            switch self {
            case .title: "Title"
            case .recentlyAdded: "Date Added"
            case .trackCount: "Song Count"
            }
        }
    }
}

@MainActor
struct BrowseGroupList: View {
    nonisolated static let rowVerticalPadding: CGFloat = 5

    let groups: [BrowseGroup]
    let library: LibraryStore
    let playback: PlaybackController
    let open: (LibraryRoute) -> Void
    var circular = false

    var body: some View {
        BrowseGroupGrid(groups: groups, library: library, playback: playback, open: open, circular: circular,
                        presentation: .list)
    }
}
