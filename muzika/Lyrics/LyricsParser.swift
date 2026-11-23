import Foundation

nonisolated enum LyricsParser {
    private static let lineStamp = try! NSRegularExpression(
        pattern: #"^\[(\d+:[0-5]?\d(?:[.,:]\d{1,3})?)\][\t ]*"#
    )
    private static let wordStamp = try! NSRegularExpression(
        pattern: #"<(\d+:[0-5]?\d(?:[.,:]\d{1,3})?)>"#
    )
    private static let metadata = try! NSRegularExpression(
        pattern: #"^\[(?:ti|ar|al|by|offset|length|re|ve|tool|au|la|encoder|instrumental|x-[a-z0-9_-]+):.*\]$"#,
        options: .caseInsensitive
    )
    private static let voice = try! NSRegularExpression(
        pattern: #"^((?:<\d+:[0-5]?\d(?:[.,:]\d{1,3})?>[\t ]*)*)v\d+:[\t ]*"#,
        options: .caseInsensitive
    )
    private static let offsetTag = try! NSRegularExpression(
        pattern: #"^\[offset:\s*([+-]?\d+)\s*\]$"#, options: .caseInsensitive
    )
    private static let supplementTag = try! NSRegularExpression(
        pattern: #"^\[x-(romaji-words|romaji|translation-words|translation):(\d+):([^\]]*)\]$"#,
        options: .caseInsensitive
    )

    private struct Cue {
        let source: Int
        let time: Double?
        let text: String
        let words: [LyricsWord]
        let isBackground: Bool
    }

    private struct SavedWord: Decodable {
        let text: String
        let startTimeMs: Double
        let endTimeMs: Double?
    }

    static func parse(_ source: String) -> LyricsDocument? {
        guard !Task.isCancelled else { return nil }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("<"), text.range(of: #"<(?:[\w.-]+:)?tt(?:[\s>])"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return LyricsTTMLParser.parse(text)
        }
        return parseLRC(text)
    }

    static func merge(base: LyricsDocument?, saved: LyricsDocument) -> LyricsDocument {
        guard let base, !base.lines.isEmpty else { return saved }
        let candidates = Dictionary(grouping: saved.lines, by: { matchKey($0.text) })
        let bothTimed = base.isTimed && saved.isTimed
        var occurrences: [String: Int] = [:]
        let merged = base.lines.map { line in
            let key = matchKey(line.text)
            guard let matches = candidates[key] else { return line }
            let match: LyricsLine?
            if bothTimed {
                guard let start = line.start else { return line }
                match = matches.lazy
                    .compactMap { candidate in candidate.start.map { (candidate, abs($0 - start)) } }
                    .filter { $0.1 <= 0.010000001 }
                    .min { $0.1 < $1.1 }?.0
            } else {
                let occurrence = occurrences[key, default: 0]
                occurrences[key] = occurrence + 1
                match = matches.count == 1 ? matches.first : (matches.indices.contains(occurrence) ? matches[occurrence] : nil)
            }
            guard let match else { return line }
            let translation = match.translation ?? line.translation
            let pronunciation = match.pronunciation ?? line.pronunciation
            let translationWords = bothTimed && !match.translationWords.isEmpty
                ? match.translationWords
                : (line.translation == translation ? line.translationWords : [])
            let pronunciationWords = bothTimed && !match.pronunciationWords.isEmpty
                ? match.pronunciationWords
                : (line.pronunciation == pronunciation ? line.pronunciationWords : [])
            return LyricsLine(
                id: line.id, text: line.text, start: line.start, end: line.end,
                words: bothTimed && line.words.isEmpty && line.text == match.text ? match.words : line.words,
                translation: translation, pronunciation: pronunciation,
                translationWords: translationWords, pronunciationWords: pronunciationWords,
                isBackground: line.isBackground
            )
        }
        return LyricsDocument(lines: merged)
    }

    private static func parseLRC(_ source: String) -> LyricsDocument? {
        var shift = 0.0
        var supplements: [Int: [String: Data]] = [:]
        var cues: [Cue] = []
        for rawRow in source.components(separatedBy: .newlines) {
            if Task.isCancelled { return nil }
            var row = rawRow.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { continue }

            if let tag = captures(in: row, with: supplementTag),
               let key = Int(tag[2]), let value = Data(base64Encoded: tag[3]) {
                let kind = tag[1].lowercased()
                if supplements[key]?[kind] == nil { supplements[key, default: [:]][kind] = value }
                continue
            }
            if let tag = captures(in: row, with: offsetTag), let milliseconds = Double(tag[1]) {
                shift = -milliseconds / 1_000
                continue
            }
            if captures(in: row, with: metadata) != nil { continue }

            var stamps: [Double] = []
            while let tag = captures(in: row, with: lineStamp), let time = timestamp(tag[1]) {
                stamps.append(time)
                row.removeFirst(tag[0].count)
            }
            let isBackground = row.lowercased().hasPrefix("[bg:") && row.hasSuffix("]")
            if isBackground { row = String(row.dropFirst(4).dropLast()) }
            if let tag = captures(in: row, with: voice) {
                row = tag[1].filter { !$0.isWhitespace } + row.dropFirst(tag[0].count)
            }
            let enhanced = parseWords(row)
            if stamps.isEmpty {
                let leadStart = isBackground ? cues.last(where: { !$0.isBackground && $0.time != nil })?.time : nil
                let start = enhanced.words.first?.start ?? leadStart
                if !enhanced.text.isEmpty || start != nil {
                    cues.append(Cue(
                        source: cues.count, time: start, text: enhanced.text,
                        words: enhanced.words, isBackground: isBackground
                    ))
                }
            } else {
                for (index, stamp) in stamps.enumerated() {
                    cues.append(Cue(
                        source: cues.count, time: stamp, text: enhanced.text,
                        words: index == 0 ? enhanced.words : [], isBackground: isBackground
                    ))
                }
            }
        }

        let times = Array(Set(cues.compactMap { $0.isBackground ? nil : $0.time })).sorted()
        let lines = cues.sorted {
            let first = $0.time ?? .infinity
            let second = $1.time ?? .infinity
            return first == second ? $0.source < $1.source : first < second
        }
        var output: [LyricsLine] = []
        for cue in lines where !cue.text.isEmpty {
            if Task.isCancelled { return nil }
            let key = cue.time.flatMap { Int(exactly: ($0 * 1_000).rounded()) } ?? output.count
            let extra = supplements[key] ?? [:]
            let translation = supplemental("translation", in: extra, shift: shift, timed: cue.time != nil)
            let pronunciation = supplemental("romaji", in: extra, shift: shift, timed: cue.time != nil)
            let start = cue.time.map { shifted($0, by: shift) }
            let end = cue.time.flatMap { time in
                if let closingStamp = LyricsLine.knownWordEnd(cue.words, in: cue.text), closingStamp > time {
                    return closingStamp
                }
                return nextTime(after: time, in: times)
            }.map { shifted($0, by: shift) }
            output.append(LyricsLine(
                id: output.count, text: cue.text, start: start, end: end,
                words: shifted(cue.words, by: shift),
                translation: translation.text, pronunciation: pronunciation.text,
                translationWords: translation.words, pronunciationWords: pronunciation.words,
                isBackground: cue.isBackground
            ))
        }
        return output.isEmpty ? nil : LyricsDocument(lines: output)
    }

    private static func nextTime(after time: Double, in times: [Double]) -> Double? {
        var lower = 0
        var upper = times.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if times[middle] <= time { lower = middle + 1 } else { upper = middle }
        }
        return lower < times.count ? times[lower] : nil
    }

    private static func parseWords(_ row: String) -> (text: String, words: [LyricsWord]) {
        let matches = wordStamp.matches(in: row, range: NSRange(row.startIndex..., in: row))
        var builder = LyricsTextBuilder()
        var position = row.startIndex
        var start: Double?
        for match in matches {
            guard let marker = Range(match.range, in: row), let value = Range(match.range(at: 1), in: row),
                  let time = timestamp(String(row[value])) else { continue }
            builder.append(String(row[position..<marker.lowerBound]), start: start, end: time)
            position = marker.upperBound
            start = time
        }
        builder.append(String(row[position...]), start: start)
        return builder.finish()
    }

    private static func supplemental(
        _ kind: String, in values: [String: Data], shift: Double, timed: Bool
    ) -> (text: String?, words: [LyricsWord]) {
        let text = values[kind].flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = values[kind + "-words"].flatMap { try? JSONDecoder().decode([SavedWord].self, from: $0) } ?? []
        var builder = LyricsTextBuilder()
        for piece in pieces {
            builder.append(
                piece.text, start: piece.startTimeMs / 1_000,
                end: piece.endTimeMs.map { $0 / 1_000 }
            )
        }
        let result = builder.finish()
        let rendered = text?.isEmpty == false ? text : (result.text.isEmpty ? nil : result.text)
        let words = timed && result.text == rendered ? shifted(result.words, by: shift) : []
        return (rendered, words)
    }

    private static func matchKey(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping
    }

    private static func shifted(_ words: [LyricsWord], by amount: Double) -> [LyricsWord] {
        words.map {
            LyricsWord(
                id: $0.id, start: shifted($0.start, by: amount),
                end: $0.end.map { shifted($0, by: amount) }, range: $0.range
            )
        }
    }

    private static func shifted(_ time: Double, by amount: Double) -> Double {
        max(0, time + amount)
    }

    private static func timestamp(_ token: String) -> Double? {
        guard let separator = token.firstIndex(of: ":"),
              let minutes = Double(token[..<separator]),
              let seconds = Double(token[token.index(after: separator)...]
                .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: ":", with: ".")),
              seconds < 60 else { return nil }
        let time = minutes * 60 + seconds
        return time.isFinite ? time : nil
    }

    private static func captures(in line: String, with regex: NSRegularExpression) -> [String]? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }
}
