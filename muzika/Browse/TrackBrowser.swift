import SwiftUI

@MainActor
struct TrackBrowserPage: View {
    let title: String
    let subtitle: String?
    let artwork: AudioTrack?
    let tracks: [AudioTrack]
    let library: LibraryStore
    let playback: PlaybackController
    let back: (() -> Void)?
    let relatedAlbums: [BrowseGroup]
    let presorted: BrowseSort?
    let glassHeader: Bool
    let highlightsCellsOnHover: Bool
    let usesUniformRows: Bool
    let usesSongsArtwork: Bool
    let navigate: ((LibraryRoute) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.controlSize) private var controlSize
    @State private var query = ""
    @State private var sort: TrackSortOrder
    @State private var filters = OfflineTrackFilters()
    @AppStorage("library.artistShowsSongs") private var showsSongs = false

    init(
        title: String,
        subtitle: String? = nil,
        artwork: AudioTrack? = nil,
        tracks: [AudioTrack],
        library: LibraryStore,
        playback: PlaybackController,
        order: BrowseSort = .title,
        back: (() -> Void)? = nil,
        relatedAlbums: [BrowseGroup] = [],
        presorted: BrowseSort? = nil,
        glassHeader: Bool = true,
        highlightsCellsOnHover: Bool = true,
        usesUniformRows: Bool = false,
        usesSongsArtwork: Bool = false,
        navigate: ((LibraryRoute) -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.tracks = tracks
        self.library = library
        self.playback = playback
        self.back = back
        self.relatedAlbums = relatedAlbums
        self.presorted = presorted
        self.glassHeader = glassHeader
        self.highlightsCellsOnHover = highlightsCellsOnHover
        self.usesUniformRows = usesUniformRows
        self.usesSongsArtwork = usesSongsArtwork
        self.navigate = navigate
        self._sort = State(initialValue: TrackSortOrder(key: order))
    }

    var body: some View {
        let onlyAlbums = !relatedAlbums.isEmpty && !showsSongs
        let selectedTracks = onlyAlbums && navigate != nil ? [] : sortedMatchingTracks
        let results = ZStack {
            if onlyAlbums, let navigate {
                relatedAlbumResults(navigate: navigate).transition(.opacity)
            } else {
                trackResults(selectedTracks).transition(.opacity)
            }
        }
        Group {
            if glassHeader {
                results.browseGlassHeader(spacing: selectedTracks.isEmpty ? 0 : BrowseLayout.headerSpacing) {
                    header(onlyAlbums: onlyAlbums, selectedTracks: selectedTracks)
                }
            } else {
                VStack(spacing: 0) {
                    header(onlyAlbums: onlyAlbums, selectedTracks: selectedTracks)
                    results
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: onlyAlbums)
        .windowLibraryFilter(text: $query, prompt: onlyAlbums ? "Filter Albums" : "Filter Songs")
    }

    private var sortedMatchingTracks: [AudioTrack] {
        let terms = AudioTrack.artistKey(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = terms.isEmpty && filters == .init() ? tracks : tracks.filter {
            $0.matches(tokens: terms) && filters.matches($0)
        }
        return !sort.descending && sort.key == presorted ? matches : sort.sorted(matches)
    }

    private func header(onlyAlbums: Bool, selectedTracks: [AudioTrack]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BrowseHeading(title: title, subtitle: subtitle ?? trackCount(tracks.count), back: back) {
                if !onlyAlbums {
                    BrowseHeaderMenus(menus: [.trackSort($sort), .trackFilters($filters, tracks: tracks)])
                }
            }
            if !relatedAlbums.isEmpty {
                Picker("Artist View", selection: $showsSongs) {
                    Text("Albums").tag(false)
                    Text("Songs").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let artwork {
                HStack(alignment: .bottom, spacing: 14) {
                    BrowseArtwork(library: library, track: artwork)
                        .frame(width: 104, height: 104)
                    Text(trackCount(tracks.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, onlyAlbums ? 12 : 0)
            }
            if !onlyAlbums, !selectedTracks.isEmpty {
                BrowsePlaybackButtons(tracks: selectedTracks, playback: playback)
                    .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 26)
    }

    @ViewBuilder
    private func relatedAlbumResults(navigate: @escaping (LibraryRoute) -> Void) -> some View {
        let terms = BrowseSearch.terms(query)
        let albums = relatedAlbums.filter { BrowseSearch.matches(terms, fields: [$0.title, $0.subtitle]) }
        if albums.isEmpty {
            BrowseEmpty(title: "No Matching Albums", symbol: "square.stack")
        } else {
            ScrollView {
                BrowseGroupGrid(groups: albums, library: library, playback: playback, open: navigate)
                    .padding(.top, BrowseLayout.headerSpacing)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 22)
            }
            .browseScrollUnderHeader()
        }
    }

    @ViewBuilder
    private func trackResults(_ selectedTracks: [AudioTrack]) -> some View {
        if selectedTracks.isEmpty {
            BrowseEmpty(
                title: tracks.isEmpty ? "No Songs" : "No Matching Songs",
                symbol: tracks.isEmpty ? "music.note" : "magnifyingglass"
            )
        } else {
            BrowseTrackTable(
                library: library, tracks: selectedTracks, playback: playback, sorting: $sort,
                highlightsCellsOnHover: highlightsCellsOnHover, usesSongsArtwork: usesSongsArtwork, navigate: navigate
            )
            .transformEnvironment(\.defaultMinListRowHeight) { height in
                if usesUniformRows && dynamicTypeSize == .large && controlSize == .regular {
                    height = max(height, 30)
                }
            }
            .trackTableScrollEdge(enabled: glassHeader, usesUniformRows: usesUniformRows)
        }
    }
}
