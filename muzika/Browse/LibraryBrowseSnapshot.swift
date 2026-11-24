import Foundation

nonisolated struct LibraryBrowseSnapshot: Sendable {
    let artists: [BrowseGroup]
    let albums: [BrowseGroup]
    let genres: [BrowseGroup]
    let songs: [AudioTrack]
    let recentAlbums: [BrowseGroup]
    private let groupsByRoute: [LibraryRoute: BrowseGroup]

    init?(tracks: [AudioTrack]) {
        guard !Task.isCancelled else { return nil }
        albums = BrowseGroup.albums(tracks)
        guard !Task.isCancelled else { return nil }
        artists = BrowseGroup.artists(tracks)
        guard !Task.isCancelled else { return nil }
        songs = BrowseSort.title.sorted(tracks)
        guard !Task.isCancelled else { return nil }
        genres = BrowseGroup.genres(tracks)
        guard !Task.isCancelled else { return nil }
        recentAlbums = albums.sorted { $0.latest > $1.latest }
        var index: [LibraryRoute: BrowseGroup] = [:]
        index.reserveCapacity(artists.count + albums.count + genres.count)
        for category in [artists, albums, genres] {
            for group in category { index[group.route] = group }
        }
        groupsByRoute = index
    }

    func groups(for category: LibraryRoute) -> [BrowseGroup] {
        switch category {
        case .artists: artists
        case .albums: albums
        case .genres: genres
        default: []
        }
    }

    func group(for route: LibraryRoute) -> BrowseGroup? {
        groupsByRoute[route]
    }
}
