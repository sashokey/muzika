import Foundation

enum BrowseSearch {
    static func terms(_ query: String) -> [String] {
        folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ terms: [String], fields: [String]) -> Bool {
        let fields = fields.map(folded)
        return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
    }

    static func record(_ query: String, in history: [String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history }
        let key = folded(query)
        return Array(([query] + history.filter { folded($0) != key }).prefix(20))
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

struct BrowseLyricsIndex {
    private(set) var revision: Int?
    private var data = [String: String]()

    mutating func useRevision(_ value: Int) {
        guard value != revision else { return }
        self = Self(revision: value)
    }

    init(revision: Int? = nil) {
        self.revision = revision
    }

    subscript(id: String) -> String? { data[id] }

    mutating func add(_ lines: [String], for id: String) -> String {
        let text = BrowseSearch.folded(lines.joined(separator: "\n"))
        data[id] = text
        return text
    }
}

struct BrowseSearchDestination: Hashable, Codable {
    enum Kind: String, Codable {
        case artist, album, song
    }

    let kind: Kind
    let key: String
    let title: String

    var displayTitle: String {
        switch kind {
        case .artist where key.isEmpty: artistDisplayName("")
        case .album where key.hasPrefix("0:"): albumDisplayName("")
        default: title
        }
    }

    var symbol: String {
        switch kind {
        case .artist: "music.mic"
        case .album: "square.stack"
        case .song: "music.note"
        }
    }
}
