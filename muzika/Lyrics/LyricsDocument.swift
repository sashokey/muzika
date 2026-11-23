import Foundation

nonisolated struct LyricsWord: Identifiable, Sendable, Equatable {
    let id: Int
    let start: Double
    let end: Double?
    let range: Range<Int>

    func isActive(at seconds: Double) -> Bool {
        seconds >= start && (end.map { seconds < $0 } ?? true)
    }
}

nonisolated struct LyricsLine: Identifiable, Sendable, Equatable {
    let id: Int
    let text: String
    let start: Double?
    let end: Double?
    let words: [LyricsWord]
    let translation: String?
    let pronunciation: String?
    let translationWords: [LyricsWord]
    let pronunciationWords: [LyricsWord]
    let isBackground: Bool

    init(
        id: Int, text: String, start: Double? = nil, end: Double? = nil,
        words: [LyricsWord] = [], translation: String? = nil, pronunciation: String? = nil,
        translationWords: [LyricsWord] = [], pronunciationWords: [LyricsWord] = [],
        isBackground: Bool = false
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.words = words
        self.translation = translation
        self.pronunciation = pronunciation
        self.translationWords = translationWords
        self.pronunciationWords = pronunciationWords
        self.isBackground = isBackground
    }

    func activeWords(at seconds: Double) -> [LyricsWord] {
        words.filter { $0.isActive(at: seconds) }
    }

    static func knownWordEnd(_ words: [LyricsWord], in text: String) -> Double? {
        guard words.map(\.range.upperBound).max() == text.count,
              words.allSatisfy({ $0.end != nil }) else { return nil }
        return words.compactMap(\.end).max()
    }
}

nonisolated struct LyricsGap: Sendable, Equatable {
    let nextLineID: Int
    let start: Double
    let end: Double
}

nonisolated struct LyricsDocument: Sendable, Equatable {
    let lines: [LyricsLine]
    private let timedIndices: [Int]
    private let maximumEnds: [Double]
    private let gaps: [Int: LyricsGap]
    private let displayTimes: [Double]

    init(lines: [LyricsLine]) {
        self.lines = lines
        timedIndices = lines.indices.filter { index in
            guard let start = lines[index].start else { return false }
            return start.isFinite && (lines[index].end ?? .infinity) > start
        }.sorted {
            let left = lines[$0].start ?? 0
            let right = lines[$1].start ?? 0
            return left == right ? $0 < $1 : left < right
        }
        var maximum = -Double.infinity
        var gaps: [Int: LyricsGap] = [:]
        maximumEnds = timedIndices.map { index in
            let line = lines[index]
            let before = max(0, maximum)
            if let start = line.start, start - before >= 3 - 1e-9 {
                gaps[line.id] = LyricsGap(nextLineID: line.id, start: before, end: start)
            }
            maximum = max(maximum, line.end ?? .infinity)
            return maximum
        }
        self.gaps = gaps
        var displayTimes: Set<Double> = [0]
        for line in lines {
            if let start = line.start, start.isFinite { displayTimes.insert(start) }
            if let end = line.end, end.isFinite { displayTimes.insert(end) }
            for words in [line.words, line.translationWords, line.pronunciationWords] {
                for word in words {
                    if word.start.isFinite { displayTimes.insert(word.start) }
                    if let end = word.end, end.isFinite { displayTimes.insert(end) }
                }
            }
        }
        self.displayTimes = displayTimes.sorted()
    }

    var isTimed: Bool { !timedIndices.isEmpty }

    func displayTime(at seconds: Double) -> Double {
        var lower = 0
        var upper = displayTimes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if displayTimes[middle] <= seconds { lower = middle + 1 }
            else { upper = middle }
        }
        return lower > 0 ? displayTimes[lower - 1] : -Double.greatestFiniteMagnitude
    }

    func activeLine(at seconds: Double) -> LyricsLine? {
        guard seconds.isFinite else { return nil }
        var lower = insertionIndex(at: seconds)
        var background: LyricsLine?
        while lower > 0, maximumEnds[lower - 1] > seconds {
            lower -= 1
            let line = lines[timedIndices[lower]]
            guard (line.end ?? .infinity) > seconds else { continue }
            if !line.isBackground { return line }
            if background == nil { background = line }
        }
        return background
    }

    func gap(before id: Int) -> LyricsGap? { gaps[id] }

    func gap(at seconds: Double) -> LyricsGap? {
        guard seconds.isFinite else { return nil }
        let next = insertionIndex(at: seconds)
        guard next < timedIndices.count,
              let gap = gaps[lines[timedIndices[next]].id], gap.start <= seconds else { return nil }
        return gap
    }

    func lineBeforeShortPause(at seconds: Double) -> LyricsLine? {
        guard seconds.isFinite else { return nil }
        let next = insertionIndex(at: seconds)
        guard next > 0, next < timedIndices.count,
              gaps[lines[timedIndices[next]].id] == nil else { return nil }
        let previousEnd = maximumEnds[next - 1]
        guard previousEnd.isFinite, previousEnd <= seconds else { return nil }
        return activeLine(at: previousEnd.nextDown)
    }

    private func insertionIndex(at seconds: Double) -> Int {
        var lower = 0
        var upper = timedIndices.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if (lines[timedIndices[middle]].start ?? .infinity) <= seconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

nonisolated struct LyricsTextBuilder {
    private struct Mark {
        let range: Range<Int>
        let start: Double
        let end: Double?
    }

    private var text = ""
    private var marks: [Mark] = []
    private(set) var count = 0

    mutating func append(_ fragment: String, start: Double? = nil, end: Double? = nil) {
        let before = count
        text += fragment
        count += fragment.utf16.count
        mark(from: before, start: start, end: end)
    }

    mutating func mark(from lower: Int, start: Double?, end: Double?) {
        guard let start, start.isFinite, lower < count,
              end.map({ $0.isFinite && $0 >= start }) ?? true else { return }
        marks.append(Mark(range: lower..<count, start: start, end: end))
    }

    func finish() -> (text: String, words: [LyricsWord]) {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace }) else { return ("", []) }
        let characters = text[first...last]
        let trimmed = String(characters)
        guard !marks.isEmpty else { return (trimmed, []) }

        var offsets = [text.utf16.distance(from: text.utf16.startIndex, to: first)]
        var spaces: [Bool] = []
        for character in characters {
            offsets.append(offsets[offsets.count - 1] + String(character).utf16.count)
            spaces.append(character.isWhitespace)
        }

        let words = marks.compactMap { mark -> (Range<Int>, Double, Double?)? in
            var upper = boundary(in: offsets, at: mark.range.upperBound)
            var lower = boundary(in: offsets, at: mark.range.lowerBound)
            if lower > 0, lower < offsets.count, offsets[lower] > mark.range.lowerBound {
                lower -= 1
            }
            upper = min(upper, spaces.count)
            while lower < upper && spaces[lower] { lower += 1 }
            while upper > lower && spaces[upper - 1] { upper -= 1 }
            guard lower < upper else { return nil }
            return (lower..<upper, mark.start, mark.end)
        }.enumerated().map { offset, word in
            LyricsWord(id: offset, start: word.1, end: word.2, range: word.0)
        }
        return (trimmed, words)
    }

    private func boundary(in offsets: [Int], at value: Int) -> Int {
        var lower = 0
        var upper = offsets.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if offsets[middle] < value { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
