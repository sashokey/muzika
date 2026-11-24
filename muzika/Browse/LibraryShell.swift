import AppKit
import SwiftUI

@MainActor
struct LibraryShell<Player: View, Settings: View>: View {
    @Bindable var library: LibraryStore
    @Bindable var playback: PlaybackController
    let history: HistoryStore
    @Binding var route: LibraryRoute
    var goBack: (() -> Void)? = nil
    var playbackArtworkIsVisible = true
    @ViewBuilder let player: () -> Player
    @ViewBuilder let settings: () -> Settings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Preferences.self) private var preferences: Preferences?
    @State private var previousRoute: LibraryRoute?
    @State private var searchQuery = ""
    @State private var searchScope = BrowseSearchScope.all
    @State private var lyricIndex = BrowseLyricsIndex()
    @State private var groupIndex = LibraryGroupIndex()

    private let categories: [LibraryRoute] = [.recentlyAdded, .artists, .albums, .songs, .genres, .folders]

    var body: some View {
        HStack(spacing: 0) {
            List(selection: sidebarSelection) {
                sidebarRow(.search)
                sidebarRow(.home)

                Section("Library") {
                    ForEach(categories, id: \.self) { sidebarRow($0) }
                }

                sidebarRow(.settings)
            }
            .listStyle(.sidebar)
            .frame(width: 209)
            .accessibilityLabel("Sidebar")

            Divider()
                .ignoresSafeArea(.container, edges: .top)

            ZStack {
                detail
                    .id(route)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(!reduceMotion && preferences?.heroAnimations != false ? .easeInOut(duration: 0.14) : nil, value: route)
            .safeAreaPadding(.bottom, playback.current == nil ? 0 : 72)
            .overlay(alignment: .bottom) {
                if playback.current != nil {
                    player()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }
            }
        }
        .environment(\.libraryPlaybackEffectsVisible, playbackArtworkIsVisible)
    }

    private var sidebarSelection: Binding<LibraryRoute?> {
        Binding(
            get: { route.sidebarRoute },
            set: { destination in
                guard let destination, destination != route else { return }
                previousRoute = nil
                route = destination
            }
        )
    }

    private func sidebarRow(_ destination: LibraryRoute) -> some View {
        Label(destination.title, systemImage: destination.symbol)
            .tag(destination)
    }

    @ViewBuilder
    private var detail: some View {
        switch route {
        case .home, .history, .statistics, .rewind:
            ListeningBrowser(
                route: route,
                library: library,
                playback: playback,
                history: history,
                recentAlbums: route == .home ? groupIndex.recentAlbums(in: library) : [],
                navigate: navigate,
                back: back,
                playbackArtworkIsVisible: playbackArtworkIsVisible
            )
        case .search:
            LibrarySearchPage(
                query: $searchQuery, scope: $searchScope, lyricIndex: $lyricIndex,
                library: library, playback: playback, groupIndex: groupIndex, navigate: navigate
            )
        case .recentlyAdded:
            RecentlyAddedPage(
                library: library, playback: playback, albums: groupIndex.recentAlbums(in: library),
                navigate: navigate, addFolder: addFolder
            )
        case .artists:
            GroupBrowserPage(
                route: route, groups: groupIndex.groups(for: .artists, in: library),
                library: library, playback: playback, navigate: navigate
            )
        case .albums:
            GroupBrowserPage(
                route: route, groups: groupIndex.groups(for: .albums, in: library),
                library: library, playback: playback, navigate: navigate
            )
        case .genres:
            GroupBrowserPage(
                route: route, groups: groupIndex.groups(for: .genres, in: library),
                library: library, playback: playback, navigate: navigate
            )
        case .songs:
            TrackBrowserPage(
                title: route.title, tracks: groupIndex.songs(in: library), library: library, playback: playback,
                presorted: .title, glassHeader: true, navigate: navigate
            )
        case .folders, .folder:
            FolderBrowserPage(
                route: route, library: library, playback: playback, navigate: navigate,
                back: back, addFolder: addFolder
            )
        case .artist, .album, .genre:
            if let group = groupIndex.groups(for: route.sidebarRoute, in: library).first(where: { $0.route == route }) {
                TrackBrowserPage(
                    title: group.title, subtitle: group.subtitle, artwork: group.artworkTrack,
                    tracks: group.tracks, library: library, playback: playback,
                    order: route.sidebarRoute == .albums ? .trackNumber : .title,
                    back: back, relatedAlbums: relatedAlbums(for: group),
                    navigate: navigate
                )
            } else {
                VStack {
                    BrowseHeading(title: route.title, back: back) { EmptyView() }
                    BrowseEmpty(title: "No Longer Available", symbol: route.symbol)
                }
                .padding(.horizontal, 26)
            }
        case .settings:
            settings()
        }
    }

    private func relatedAlbums(for group: BrowseGroup) -> [BrowseGroup] {
        guard case .artist = group.route else { return [] }
        let routes = Set(group.tracks.lazy.map { BrowseGroup.albumRoute($0.albumKey) })
        return groupIndex.groups(for: .albums, in: library).filter { routes.contains($0.route) }
    }

    private func navigate(to destination: LibraryRoute) {
        guard route != destination else { return }
        previousRoute = route
        route = destination
    }

    private func back() {
        if let goBack {
            goBack()
            return
        }
        let destination = previousRoute ?? route.sidebarRoute
        previousRoute = nil
        route = destination
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
final class LibraryGroupIndex {
    private weak var library: LibraryStore?
    private var revision: Int?
    private var grouped: [LibraryRoute: [BrowseGroup]] = [:]
    private var sortedSongs: [AudioTrack]?
    private var sortedRecentAlbums: [BrowseGroup]?
    private var lastSearch: (query: String, tracks: [AudioTrack])?

    func groups(for category: LibraryRoute, in library: LibraryStore) -> [BrowseGroup] {
        updateRevision(in: library)
        if let groups = grouped[category] { return groups }
        let groups: [BrowseGroup]
        switch category {
        case .artists: groups = BrowseGroup.artists(library.tracks)
        case .albums: groups = BrowseGroup.albums(library.tracks)
        case .genres: groups = BrowseGroup.genres(library.tracks)
        default: return []
        }
        grouped[category] = groups
        return groups
    }

    func songs(in library: LibraryStore) -> [AudioTrack] {
        updateRevision(in: library)
        if let sortedSongs { return sortedSongs }
        let songs = BrowseSort.title.sorted(library.tracks)
        sortedSongs = songs
        return songs
    }

    func recentAlbums(in library: LibraryStore) -> [BrowseGroup] {
        updateRevision(in: library)
        if let sortedRecentAlbums { return sortedRecentAlbums }
        let albums = groups(for: .albums, in: library).sorted { $0.latest > $1.latest }
        sortedRecentAlbums = albums
        return albums
    }

    func tracksMatching(_ query: String, in library: LibraryStore) -> [AudioTrack] {
        updateRevision(in: library)
        if let lastSearch, lastSearch.query == query { return lastSearch.tracks }
        let tracks = library.matchingTracks(query)
        lastSearch = (query, tracks)
        return tracks
    }

    private func updateRevision(in library: LibraryStore) {
        let revision = library.revision
        guard self.library !== library || self.revision != revision else { return }
        self.library = library
        self.revision = revision
        grouped.removeAll()
        sortedSongs = nil
        sortedRecentAlbums = nil
        lastSearch = nil
    }
}

extension Notification.Name {
    static let focusLibrarySearch = Self("focusLibrarySearch")
}

@MainActor
private struct RecentlyAddedPage: View {
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
            .padding(.horizontal, 26)
            .padding(.bottom, 24)
        }
        .browseGlassHeader {
            VStack(spacing: 0) {
                BrowseHeading(title: String(localized: "Library")) {
                    Button("Add Folder", systemImage: "folder.badge.plus", action: addFolder)
                        .disabled(library.isScanning)
                }
                status
            }
            .padding(.horizontal, 26)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter Library")
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
                            .frame(width: 21)
                        Text(destination.title)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
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
                    .padding(.horizontal, 26)
                    .padding(.bottom, 22)
                }
            }
        }
        .browseGlassHeader {
            BrowseHeading(title: route.title, subtitle: String(localized: "Total: \(self.groups.count)")) {
                if route == .albums {
                    Menu("Filters", systemImage: "line.3.horizontal.decrease") {
                        Picker("Album Completeness", selection: $completeness) {
                            Text("All Albums").tag(AlbumCompleteness?.none)
                            ForEach(AlbumCompleteness.allCases, id: \.self) { status in
                                Text(status.displayTitle).tag(Optional(status))
                            }
                        }
                    }
                }
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort", selection: $arrangement) {
                        ForEach(GroupArrangement.allCases, id: \.self) { item in
                            Text(item.displayTitle).tag(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text(filterPrompt))
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
        let unavailable = library.sources.filter { $0.status == .unavailable }
        let groups = groups.filter { group in
            guard BrowseSearch.matches(terms, fields: [group.title, group.subtitle]) else { return false }
            guard let completeness else { return true }
            return AlbumCompleteness(tracks: group.tracks, unavailable: unavailable) == completeness
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
    let groups: [BrowseGroup]
    let library: LibraryStore
    let playback: PlaybackController
    let open: (LibraryRoute) -> Void
    var circular = false

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(groups) { group in
                Button {
                    open(group.route)
                } label: {
                    HStack(spacing: 10) {
                        BrowseArtwork(
                            library: library, track: group.artworkTrack, symbol: group.route.symbol,
                            pixelSize: 96, circular: circular
                        )
                        .frame(width: 36, height: 36)
                        Text(group.title).lineLimit(1)
                        Spacer()
                        Text(group.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(ArtworkPlaybackModifier(
                    library: library, target: .group(group.tracks), playback: playback, compact: true
                ))
                .contextMenu {
                    Button("Open", systemImage: "arrow.right") { open(group.route) }
                    Divider()
                    PlayTracksMenu(tracks: group.tracks, playback: playback)
                }
                Divider().padding(.leading, 46)
            }
        }
    }
}

@MainActor
struct BrowseGroupGrid: View {
    let groups: [BrowseGroup]
    let library: LibraryStore
    let playback: PlaybackController
    let open: (LibraryRoute) -> Void
    var circular = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 208), spacing: 16)], alignment: .leading, spacing: 19) {
            ForEach(groups) { group in
                Button {
                    open(group.route)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        BrowseArtwork(
                            library: library, track: group.artworkTrack, symbol: group.route.symbol,
                            circular: circular
                        )
                        Text(group.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(group.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.title)
                .accessibilityHint(group.subtitle)
                .modifier(ArtworkPlaybackModifier(
                    library: library, target: .group(group.tracks), playback: playback, compact: false
                ))
                .contextMenu {
                    Button("Open", systemImage: "arrow.right") { open(group.route) }
                    Divider()
                    PlayTracksMenu(tracks: group.tracks, playback: playback)
                }
            }
        }
    }
}
