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

    private var selectedFolder: URL? {
        guard case .folder(let folder) = route else { return nil }
        return folder
    }

    var body: some View {
        let folder = selectedFolder
        let terms = BrowseSearch.terms(query)
        let descendants = folder.map { current in library.tracks.filter { belongs($0.url, to: current) } } ?? []
        let folders = entries(for: folder, descendants: descendants).filter {
            BrowseSearch.matches(terms, fields: [$0.name, $0.url.path]) ||
                $0.tracks.contains { $0.matches(query) }
        }
        let matches = descendants.filter {
            $0.url.deletingLastPathComponent().standardizedFileURL.path == folder?.standardizedFileURL.path &&
                $0.matches(query) && filters.matches($0)
        }
        let tracks = trackSort.sorted(matches)
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
                    if folder != nil {
                        BrowseTrackSortMenu(sort: $trackSort.key, descending: $trackSort.descending)
                        BrowseTrackFiltersMenu(filters: $filters, tracks: descendants)
                    }
                    if !folders.isEmpty {
                        Menu("Folder Order", systemImage: "folder") {
                            Toggle("Ascending by Name", isOn: $sortByName)
                        }
                        .glassHoverMenu()
                    }
                    if folder == nil {
                        Button("Add Folder", systemImage: "folder.badge.plus", action: addFolder)
                            .buttonStyle(GlassHoverButtonStyle())
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

    private func entries(for folder: URL?, descendants: [AudioTrack]) -> [Folder] {
        let entries: [Folder]
        if let folder {
            let directory = folder.standardizedFileURL.path
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            let grouped = Dictionary(grouping: descendants) { track in
                track.url.standardizedFileURL.path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)
            }
            var children: [String: [AudioTrack]] = [:]
            for (path, tracks) in grouped where path.count > 1 {
                children[String(path[0]), default: []].append(contentsOf: tracks)
            }
            entries = children.map { name, tracks in
                Folder(url: folder.appendingPathComponent(name, isDirectory: true), name: name, tracks: tracks)
            }
        } else {
            entries = library.sources.map { source in
                let url = source.url.standardizedFileURL
                return Folder(
                    url: url, name: source.name,
                    tracks: library.tracks.filter { belongs($0.url, to: url) },
                    detail: source.status == .unavailable ? String(localized: "Unavailable") : nil
                )
            }
        }
        return entries.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison == .orderedSame { return $0.id.path < $1.id.path }
            return comparison == (sortByName ? .orderedAscending : .orderedDescending)
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
