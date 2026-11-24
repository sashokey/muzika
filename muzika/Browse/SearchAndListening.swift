import SwiftUI

enum BrowseSearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case lyrics = "Lyrics"

    var id: Self { self }

    var displayTitle: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .lyrics: "Lyrics"
        }
    }
}

@MainActor
struct LibrarySearchPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var query: String
    @Binding var scope: BrowseSearchScope
    @Binding var lyricIndex: BrowseLyricsIndex
    let library: LibraryStore
    let playback: PlaybackController
    let groupIndex: LibraryGroupIndex
    let navigate: (LibraryRoute) -> Void

    @AppStorage("search.recentQueries") private var recentData = Data()
    @AppStorage("search.recentDestinations") private var recentDestinationsData = Data()
    @AppStorage("search.resultsAsGrid") private var resultsAsGrid = true
    @Environment(Preferences.self) private var preferences: Preferences?
    @FocusState private var focused: Bool
    @State private var lyricMatches: [AudioTrack] = []
    @State private var searchingLyrics = false
    @State private var indexedCount = 0
    @State private var refresh = 0
    @State private var details: AudioTrack?

    private var terms: [String] { BrowseSearch.terms(query) }

    private var recent: [String] {
        (try? JSONDecoder().decode([String].self, from: recentData)) ?? []
    }

    private var recentDestinations: [BrowseSearchDestination] {
        (try? JSONDecoder().decode([BrowseSearchDestination].self, from: recentDestinationsData)) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            BrowseHeading(title: LibraryRoute.search.title) {
                if scope == .lyrics {
                    Button("Refresh lyrics search", systemImage: "arrow.clockwise", action: refreshLyrics)
                        .buttonStyle(GlassHoverButtonStyle())
                }
                if !terms.isEmpty {
                    Picker("Result View", selection: $resultsAsGrid) {
                        Image(systemName: "list.bullet").accessibilityLabel("List").tag(false)
                        Image(systemName: "square.grid.2x2").accessibilityLabel("Grid").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .liquidGlassHover(in: .capsule)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Library", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { rememberQuery() }
                    .accessibilityLabel("Search Library")
                if !query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Clear Search")
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 8))
            .liquidGlassHover()
            Picker("Search Scope", selection: $scope) {
                ForEach(BrowseSearchScope.allCases) { item in
                    Text(item.displayTitle).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .liquidGlassHover(in: .capsule)
            .padding(.vertical, 12)

            if terms.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        recentSearches
                    }
                    .padding(.bottom, 16)
                }
                .browseHoverGutter()
                if scope == .lyrics && searchingLyrics { lyricsProgress }
            } else if scope == .lyrics {
                if searchingLyrics { lyricsProgress }
                if !lyricMatches.isEmpty {
                    songResults(lyricMatches)
                } else if !searchingLyrics {
                    BrowseEmpty(title: "No Matching Lyrics", symbol: "quote.bubble")
                } else {
                    Spacer()
                }
            } else {
                searchResults
            }
        }
        .padding(.horizontal, 26)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: resultsAsGrid)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: scope)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusLibrarySearch)) { _ in
            focused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshLibraryPage)) { _ in
            if scope == .lyrics { refreshLyrics() }
        }
        .task(id: LyricQuery(scope: scope, terms: terms, revision: library.revision, refresh: refresh)) {
            await findLyrics()
        }
        .sheet(item: $details) { TrackInfoView(library: library, track: $0) }
    }

    private var lyricsProgress: some View {
        ProgressView(
            "Indexing Local Lyrics… \(indexedCount) of \(library.tracks.count)",
            value: Double(indexedCount), total: Double(max(1, library.tracks.count))
        )
        .controlSize(.small)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var recentSearches: some View {
        let destinations = recentDestinations.filter(destinationAvailable)
        if recent.isEmpty, destinations.isEmpty {
            BrowseEmpty(
                title: "Search Your Library",
                symbol: "magnifyingglass",
                detail: "Find artists, albums, songs, and local lyrics."
            )
            .padding(.top, 22)
        } else {
            HStack {
                Text("Recent Searches").font(.title2.bold())
                Spacer()
                Button("Clear") {
                    recentData = Data()
                    recentDestinationsData = Data()
                }
                .buttonStyle(GlassHoverButtonStyle())
            }
            .padding(.vertical, 9)

            ForEach(recent, id: \.self) { item in
                Button {
                    query = item
                    focused = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text(item).lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .liquidGlassHover()
                Divider()
            }
            if !destinations.isEmpty {
                Text("Recently Opened")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 14)
                ForEach(destinations, id: \.self) { item in
                    Button {
                        openRecent(item)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol).foregroundStyle(.secondary)
                            Text(item.displayTitle).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlassHover()
                    Divider()
                }
            }
        }
    }

    private var searchResults: some View {
        let terms = terms
        let songs = scope == .all || scope == .songs ? groupIndex.tracksMatching(query, in: library) : []
        let artists = scope == .all || scope == .artists ? groupIndex.groups(for: .artists, in: library).filter {
            BrowseSearch.matches(terms, fields: [$0.title])
        } : []
        let albums = scope == .all || scope == .albums ? groupIndex.groups(for: .albums, in: library).filter {
            BrowseSearch.matches(terms, fields: [$0.title, $0.subtitle])
        } : []
        let showSongs = !songs.isEmpty
        return Group {
            if artists.isEmpty, albums.isEmpty, !showSongs {
                BrowseEmpty(title: "No Results", symbol: "magnifyingglass", detail: "Try a different search.")
            } else if scope == .songs {
                songResults(songs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !artists.isEmpty {
                            resultHeading(.artists, overflow: scope == .all && artists.count > 6)
                            groupResults(Array(artists.prefix(scope == .all ? 6 : artists.count)), circular: true)
                        }
                        if !albums.isEmpty {
                            resultHeading(.albums, overflow: scope == .all && albums.count > 6)
                            groupResults(Array(albums.prefix(scope == .all ? 6 : albums.count)))
                        }
                        if showSongs {
                            resultHeading(.songs, overflow: songs.count > 12)
                            if resultsAsGrid {
                                BrowseSongGrid(
                                    library: library, tracks: songs, playback: playback,
                                    limit: 12, beforePlay: recordSong
                                )
                            } else {
                                LazyVStack(spacing: 0) {
                                    BrowseTrackRows(
                                        library: library, tracks: songs, playback: playback,
                                        limit: 12, beforePlay: recordSong
                                    )
                                }
                            }
                        }
                    }
                    .padding(.bottom, 22)
                }
                .browseHoverGutter()
            }
        }
    }

    @ViewBuilder
    private func groupResults(_ groups: [BrowseGroup], circular: Bool = false) -> some View {
        if resultsAsGrid {
            BrowseGroupGrid(groups: groups, library: library, playback: playback, open: open, circular: circular)
        } else {
            BrowseGroupList(groups: groups, library: library, playback: playback, open: open, circular: circular)
        }
    }

    @ViewBuilder
    private func songResults(_ songs: [AudioTrack]) -> some View {
        if resultsAsGrid {
            ScrollView {
                BrowseSongGrid(
                    library: library, tracks: songs, playback: playback,
                    beforePlay: recordSong
                )
            }
            .browseHoverGutter([.horizontal, .top])
        } else {
            BrowseTrackTable(library: library, tracks: songs, playback: playback, navigate: open, beforePlay: recordSong)
        }
    }

    private func resultHeading(_ destination: BrowseSearchScope, overflow: Bool) -> some View {
        HStack {
            Text(destination.displayTitle).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Spacer()
            if overflow {
                Button("See All") {
                    rememberQuery()
                    scope = destination
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .liquidGlassHover(in: .capsule, outset: CGSize(width: 6, height: 3))
            }
        }
    }

    private func rememberQuery() {
        let queries = BrowseSearch.record(query, in: recent)
        if let data = try? JSONEncoder().encode(queries) {
            recentData = data
        }
    }

    private func open(_ route: LibraryRoute) {
        rememberQuery()
        switch route {
        case .artist(let key):
            if let group = groupIndex.groups(for: .artists, in: library).first(where: { $0.route == route }) {
                record(.init(kind: .artist, key: key, title: group.title))
            }
        case .album(let key):
            if let group = groupIndex.groups(for: .albums, in: library).first(where: { $0.route == route }) {
                record(.init(kind: .album, key: key, title: group.title))
            }
        default:
            break
        }
        navigate(route)
    }

    private func recordSong(_ track: AudioTrack) {
        rememberQuery()
        record(.init(kind: .song, key: track.id, title: track.title))
    }

    private func record(_ item: BrowseSearchDestination) {
        let next = [item] + recentDestinations.filter { $0.kind != item.kind || $0.key != item.key }
        if let data = try? JSONEncoder().encode(Array(next.prefix(12))) {
            recentDestinationsData = data
        }
    }

    private func destinationAvailable(_ item: BrowseSearchDestination) -> Bool {
        switch item.kind {
        case .artist:
            return library.tracks.contains { track in
                BrowseGroup.artistNames(track.artist.isEmpty ? track.albumArtist : track.artist)
                    .contains { AudioTrack.artistKey($0) == item.key }
            }
        case .album:
            return library.tracks.contains { BrowseGroup.albumRoute($0.albumKey) == .album(item.key) }
        case .song:
            return library.track(id: item.key) != nil
        }
    }

    private func openRecent(_ item: BrowseSearchDestination) {
        record(item)
        switch item.kind {
        case .artist: navigate(.artist(item.key))
        case .album: navigate(.album(item.key))
        case .song:
            if let track = library.track(id: item.key) {
                if preferences?.songTap == .details { details = track }
                else { playback.play(track, in: [track]) }
            }
        }
    }

    private func refreshLyrics() {
        lyricIndex = BrowseLyricsIndex()
        refresh += 1
    }

    private func findLyrics() async {
        guard !Task.isCancelled else { return }
        searchingLyrics = false
        lyricMatches = []
        indexedCount = 0
        let terms = terms
        guard scope == .lyrics, !terms.isEmpty || refresh > 0 else { return }
        lyricIndex.useRevision(library.revision)
        searchingLyrics = true
        do {
            try await Task.sleep(for: .milliseconds(160))
        } catch {
            return
        }

        var batch: [AudioTrack] = []
        for (index, track) in library.tracks.enumerated() {
            guard !Task.isCancelled else { return }
            let lyrics: String
            if let cached = lyricIndex[track.id] {
                lyrics = cached
            } else {
                let lines = await library.rawLyrics(for: track)
                guard !Task.isCancelled else { return }
                lyrics = lyricIndex.add(lines, for: track.id)
            }
            if !terms.isEmpty, terms.allSatisfy({ lyrics.contains($0) }) {
                batch.append(track)
                if batch.count == 12 {
                    lyricMatches.append(contentsOf: batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if (index + 1).isMultiple(of: 8) {
                indexedCount = index + 1
                await Task.yield()
            }
        }
        guard !Task.isCancelled else { return }
        indexedCount = library.tracks.count
        lyricMatches.append(contentsOf: batch)
        searchingLyrics = false
    }

    private struct LyricQuery: Equatable {
        let scope: BrowseSearchScope
        let terms: [String]
        let revision: Int
        let refresh: Int
    }
}

@MainActor
struct ListeningBrowser: View {
    let route: LibraryRoute
    let library: LibraryStore
    let playback: PlaybackController
    let history: HistoryStore
    let recentAlbums: [BrowseGroup]
    let navigate: (LibraryRoute) -> Void
    let back: () -> Void
    var playbackArtworkIsVisible = true

    @Environment(Preferences.self) private var preferences: Preferences?
    @State private var period = ListeningPeriod.all

    var body: some View {
        VStack(spacing: 0) {
            BrowseHeading(title: route.title, back: route == .home ? nil : back) {
                if route == .statistics {
                    Picker("Period", selection: $period) {
                        ForEach(ListeningPeriod.allCases) { period in
                            Text(period.displayTitle).tag(period)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .liquidGlassHover(in: .capsule)
                }
            }

            ScrollView {
                switch route {
                case .home: home.padding(.trailing, 26)
                case .history: timeline
                case .statistics: statistics(since: period.start)
                case .rewind: rewind
                default: EmptyView()
                }
            }
            .browseHoverGutter(route == .home ? .leading : [.horizontal, .top])
        }
        .padding(.horizontal, 26)
    }

    private var home: some View {
        let available = library.sessionTracks
        let recent = BrowseGroup.recentAlbumRepresentatives(history.recent(in: available))
        let latest = recentAlbums
        let repeated = history.onRepeat(in: available)
        let resumable = playback.current.flatMap { current in available.first { $0.id == current.id } }
        return VStack(alignment: .leading, spacing: 20) {
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Recently Played", systemImage: "clock")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Listening Statistics", systemImage: "chevron.right") { navigate(.statistics) }
                            .controlSize(.small)
                            .buttonStyle(GlassHoverButtonStyle())
                    }
                    BrowseSongGrid(
                        library: library, tracks: recent, playback: playback, displayAlbum: true, limit: 6,
                        showsPlaybackEffects: playbackArtworkIsVisible
                    )
                }
            } else if history.events.isEmpty, history.continueListening, let resumable {
                continueListening(resumable)
            }
            if !latest.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recently Added").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("See All") { navigate(.recentlyAdded) }
                            .controlSize(.small)
                            .buttonStyle(GlassHoverButtonStyle())
                    }
                    BrowseGroupGrid(groups: Array(latest.prefix(6)), library: library, playback: playback, open: navigate)
                }
            }
            if !repeated.isEmpty {
                playbackSection("On Repeat", tracks: repeated, symbol: "repeat")
            }
            if recent.isEmpty, latest.isEmpty, resumable == nil {
                BrowseEmpty(
                    title: "Nothing Played Yet",
                    symbol: "clock",
                    detail: "Songs you play from your library will appear here."
                )
                .padding(.vertical, 12)
                Button("Browse Library", systemImage: "music.note.list") { navigate(.recentlyAdded) }
                    .buttonStyle(GlassHoverButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                Button("Listening History", systemImage: LibraryRoute.history.symbol) { navigate(.history) }
                    .buttonStyle(GlassHoverButtonStyle())
                if recent.isEmpty {
                    Button("Listening Statistics", systemImage: LibraryRoute.statistics.symbol) { navigate(.statistics) }
                        .buttonStyle(GlassHoverButtonStyle())
                }
                Button("Listening Rewind", systemImage: LibraryRoute.rewind.symbol) { navigate(.rewind) }
                    .buttonStyle(GlassHoverButtonStyle())
                Spacer()
            }
        }
        .padding(.bottom, 24)
    }

    private func continueListening(_ last: AudioTrack) -> some View {
        HStack(spacing: 12) {
            BrowseArtwork(library: library, track: last, pixelSize: 160)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Continue Listening").font(.headline)
                Text(verbatim: last.artist.isEmpty ? last.title : "\(last.title) · \(last.artist)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Play", systemImage: "play.fill") {
                if playback.current?.id == last.id {
                    if !playback.playing { playback.togglePlayback() }
                } else {
                    playback.play(last, in: [last])
                }
            }
            .buttonStyle(GlassHoverButtonStyle(prominent: true))
        }
        .padding(12)
        .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 10))
    }

    private func playbackSection(_ title: LocalizedStringResource, tracks: [AudioTrack], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                BrowseTrackRows(
                    library: library, tracks: tracks, playback: playback, limit: 6,
                    showsPlaybackEffects: playbackArtworkIsVisible
                )
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let available = library.sessionTracks
        let availableIDs = Set(available.map(\.id))
        let events = history.events.reversed().filter { availableIDs.contains($0.trackID) }
        if history.events.isEmpty {
            BrowseEmpty(title: "No Listening History", symbol: "clock.arrow.circlepath")
                .padding(.top, 22)
        } else if events.isEmpty {
            BrowseEmpty(title: "No Available Songs", symbol: "clock.arrow.circlepath").padding(.top, 22)
        } else if preferences?.historyGrid == true {
            BrowseSongGrid(library: library, tracks: history.recent(in: available), playback: playback)
                .padding(.bottom, 20)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(events) { event in
                    if let track = library.track(id: event.trackID) {
                        Button {
                            playback.play(track, in: [track])
                        } label: {
                            eventRow(event)
                        }
                        .buttonStyle(.plain)
                        .liquidGlassHover()
                        .contextMenu {
                            PlayTracksMenu(tracks: [track], playback: playback)
                        }
                        Divider()
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private func eventRow(_ event: ListeningEvent) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).fontWeight(.medium)
                Text(artistDisplayName(event.artist))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(event.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(timeLabel(event.seconds))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 45, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statistics(since date: Date?) -> some View {
        let summary = history.summarize(since: date)
        let ranked = history.rankings(in: library.sessionTracks, since: date)
        if summary.count == 0 {
            BrowseEmpty(title: "No Listening Data", symbol: "chart.bar").padding(.top, 22)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 10)], alignment: .leading, spacing: 10) {
                    statistic("Plays", value: summary.count.formatted(), symbol: "play")
                    statistic("Listening Time", value: timeLabel(summary.seconds), symbol: "timer")
                    statistic("Songs", value: summary.trackCount.formatted(), symbol: "music.note")
                    statistic("Artists", value: summary.artistCount.formatted(), symbol: "music.mic")
                }
                if !ranked.isEmpty {
                    let rankedTracks = ranked.map(\.track)
                    Text("Top Songs").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ranked.prefix(50))) { result in
                            HStack {
                                Button {
                                    playback.play(result.track, in: rankedTracks)
                                } label: {
                                    BrowseTrackRow(library: library, track: result.track)
                                }
                                .buttonStyle(.plain)
                                .liquidGlassHover(outset: BrowseTrackRow.hoverOutset)
                                .modifier(ArtworkPlaybackModifier(
                                    library: library, target: .track(result.track, queue: rankedTracks),
                                    playback: playback, compact: true
                                ))
                                Text("Plays: \(result.count)")
                                    .frame(minWidth: 60, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var rewind: some View {
        let start = Calendar.current.dateInterval(of: .year, for: .now)?.start
        let tracks = history.rankings(in: library.sessionTracks, since: start).map(\.track)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your Year in Music").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if !tracks.isEmpty {
                    BrowsePlaybackButtons(tracks: tracks, playback: playback)
                }
            }
            statistics(since: start)
        }
    }

    private func statistic(_ title: LocalizedStringResource, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text(value).font(.title2.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 10))
    }

    private enum ListeningPeriod: String, CaseIterable, Identifiable {
        case all = "All Time"
        case week = "Last 7 Days"
        case month = "Last 30 Days"
        case year = "This Year"
        var id: Self { self }

        var displayTitle: LocalizedStringResource {
            switch self {
            case .all: "All Time"
            case .week: "Last 7 Days"
            case .month: "Last 30 Days"
            case .year: "This Year"
            }
        }

        var start: Date? {
            let calendar = Calendar.current
            switch self {
            case .all: return nil
            case .week: return calendar.date(byAdding: .day, value: -7, to: .now)
            case .month: return calendar.date(byAdding: .day, value: -30, to: .now)
            case .year: return calendar.dateInterval(of: .year, for: .now)?.start
            }
        }
    }
}
