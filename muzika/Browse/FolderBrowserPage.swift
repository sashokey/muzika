import AppKit
import SwiftUI

@MainActor
struct FolderBrowserPage: View {
    let route: LibraryRoute
    let library: LibraryStore
    let playback: PlaybackController
    let navigate: (LibraryRoute) -> Void
    let back: () -> Void
    let addFolder: () -> Void

    @State private var query = ""
    @State private var sortByName = true
    @State private var trackSort = TrackSortOrder(key: .title)
    @State private var filters = OfflineTrackFilters()
    @State private var cache = FolderCache()

    private var selectedFolder: URL? {
        guard case .folder(let folder) = route else { return nil }
        return folder
    }

    var body: some View {
        let folder = selectedFolder
        let terms = BrowseSearch.terms(query)
        let data = cache.data(for: DataKey(revision: library.revision, folder: folder, sources: library.sources)) {
            if let folder {
                let listing = FolderListing(folder: folder, tracks: library.tracks)
                let children = listing.children.map { name, tracks in
                    Folder(url: folder.appendingPathComponent(name, isDirectory: true), name: name, tracks: tracks)
                }
                return (descendants: listing.descendants, directTracks: listing.directTracks, folders: children)
            }
            return (descendants: [], directTracks: [], folders: sourceFolders())
        }
        let result = cache.result(for: FilterKey(query: query, sortByName: sortByName, trackSort: trackSort, filters: filters)) {
            let folders = data.folders.filter {
                BrowseSearch.matches(terms, fields: [$0.name, $0.url.path]) ||
                    $0.tracks.contains { $0.matches(query) }
            }.sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                if comparison == .orderedSame { return $0.id.path < $1.id.path }
                return comparison == (sortByName ? .orderedAscending : .orderedDescending)
            }
            let matches = data.directTracks.filter { $0.matches(query) && filters.matches($0) }
            return (folders: folders, tracks: trackSort.sorted(matches))
        }
        let descendants = data.descendants
        let folders = result.folders
        let tracks = result.tracks
        Group {
            if folders.isEmpty, tracks.isEmpty {
                BrowseEmpty(
                    title: terms.isEmpty ? "No Music Folders" : "No Matches",
                    symbol: "folder",
                    detail: folder == nil && terms.isEmpty ? "Add a folder to browse its music." : nil
                )
            } else if folders.isEmpty {
                BrowseTrackTable(library: library, tracks: tracks, playback: playback, sorting: $trackSort, navigate: navigate)
                    .trackTableScrollEdge()
            } else if tracks.isEmpty {
                folderList(folders)
                    .browseScrollUnderHeader()
            } else {
                VSplitView {
                    folderList(folders)
                        .frame(minHeight: 54, idealHeight: min(140, Double(folders.count) * 43))
                    BrowseTrackTable(library: library, tracks: tracks, playback: playback, sorting: $trackSort, navigate: navigate)
                        .frame(minHeight: 110)
                }
                .contentMargins(.bottom, 0, for: .scrollIndicators)
            }
        }
        .padding(.horizontal, 26)
        .browseGlassHeader(spacing: folders.isEmpty && !tracks.isEmpty ? BrowseLayout.headerSpacing : 0) {
            VStack(spacing: 0) {
                BrowseHeading(title: route.title, subtitle: folder.map { _ in trackCount(descendants.count) }, back: folder == nil ? nil : back) {
                    if folder != nil, !descendants.isEmpty {
                        BrowsePlaybackButtons(tracks: descendants, playback: playback)
                    }
                    if folder != nil || !folders.isEmpty {
                        BrowseHeaderMenus(menus: headerMenus(tracks: descendants, includesTrackMenus: folder != nil, hasFolders: !folders.isEmpty))
                    }
                    if folder == nil {
                        Button("Add Folder", systemImage: "folder.badge.plus", action: addFolder)
                            .buttonStyle(GlassHoverButtonStyle.action())
                            .disabled(library.isScanning)
                    }
                }
                if let folder {
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 12)
                }
            }
            .padding(.horizontal, 26)
        }
        .windowLibraryFilter(text: $query, prompt: "Filter Folders")
    }

    private func headerMenus(tracks: [AudioTrack], includesTrackMenus: Bool, hasFolders: Bool) -> [BrowseHeaderMenu] {
        var menus: [BrowseHeaderMenu] = includesTrackMenus ? [
            .trackSort($trackSort), .trackFilters($filters, tracks: tracks)
        ] : []
        if hasFolders {
            menus.append(BrowseHeaderMenu(id: .folderOrder, title: "Folder Order", symbol: "folder", entries: [
                .command(Text("Ascending by Name"), selected: sortByName) { sortByName.toggle() }
            ]))
        }
        return menus
    }

    private func folderList(_ folders: [Folder]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(folders) { item in
                    Button {
                        navigate(.folder(item.url))
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.tint)
                                .frame(width: 36, alignment: .leading)
                            Text(item.name)
                            Spacer()
                            Text(item.detail)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlassHover(outset: BrowseTrackRow.hoverOutset)
                    .contextMenu {
                        Button("Open", systemImage: "arrow.right") { navigate(.folder(item.url)) }
                        if !item.tracks.isEmpty {
                            Divider()
                            PlayTracksMenu(tracks: item.tracks, playback: playback)
                        }
                    }
                    Divider().padding(.leading, 46)
                }
            }
            .padding(.top, 1)
            .padding(.bottom, 12)
        }
        .browseHoverGutter()
    }

    private func belongs(_ file: URL, to folder: URL) -> Bool {
        let folder = folder.standardizedFileURL.path
        return file.standardizedFileURL.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    private func sourceFolders() -> [Folder] {
        library.sources.map { source in
            let url = source.url.standardizedFileURL
            return Folder(
                url: url, name: source.name,
                tracks: library.tracks.filter { belongs($0.url, to: url) },
                detail: source.status == .unavailable ? String(localized: "Unavailable") : nil
            )
        }
    }

    private struct DataKey: Equatable {
        let revision: Int
        let folder: URL?
        let sources: [LibrarySource]
    }

    private struct FilterKey: Equatable {
        let query: String
        let sortByName: Bool
        let trackSort: TrackSortOrder
        let filters: OfflineTrackFilters
    }

    private final class FolderCache {
        typealias Data = (descendants: [AudioTrack], directTracks: [AudioTrack], folders: [Folder])
        typealias Result = (folders: [Folder], tracks: [AudioTrack])

        private var base: (key: DataKey, data: Data)?
        private var display: (key: FilterKey, result: Result)?

        func data(for key: DataKey, build: () -> Data) -> Data {
            if let base, base.key == key { return base.data }
            let data = build()
            base = (key, data)
            display = nil
            return data
        }

        func result(for key: FilterKey, build: () -> Result) -> Result {
            if let display, display.key == key { return display.result }
            let result = build()
            display = (key, result)
            return result
        }
    }

    private struct Folder: Identifiable {
        let url: URL
        let name: String
        let tracks: [AudioTrack]
        var detailOverride: String? = nil

        init(url: URL, name: String, tracks: [AudioTrack], detail: String? = nil) {
            self.url = url
            self.name = name
            self.tracks = tracks
            self.detailOverride = detail
        }

        var id: URL { url }
        var detail: String { detailOverride ?? trackCount(tracks.count) }
    }
}

nonisolated struct FolderListing: Sendable {
    let descendants: [AudioTrack]
    let directTracks: [AudioTrack]
    let children: [String: [AudioTrack]]

    init(folder: URL, tracks: [AudioTrack]) {
        let directory = folder.standardizedFileURL.path
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        var descendants: [AudioTrack] = []
        var direct: [AudioTrack] = []
        var children: [String: [AudioTrack]] = [:]
        for track in tracks {
            let path = track.url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            descendants.append(track)
            let relative = path.dropFirst(prefix.count)
            if let slash = relative.firstIndex(of: "/") {
                children[String(relative[..<slash]), default: []].append(track)
            } else {
                direct.append(track)
            }
        }
        self.descendants = descendants
        directTracks = direct
        self.children = children
    }
}
