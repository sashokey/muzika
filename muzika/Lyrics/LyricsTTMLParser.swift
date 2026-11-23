import Foundation

nonisolated enum LyricsTTMLParser {
    private final class Element {
        enum Content {
            case text(String)
            case element(Element)
        }

        let name: String
        let attributes: [String: String]
        var contents: [Content] = []

        init(name: String, attributes: [String: String]) {
            self.name = Self.localName(name)
            self.attributes = attributes
        }

        subscript(attribute: String) -> String? {
            attributes[attribute] ?? attributes.first {
                Self.localName($0.key) == attribute
            }?.value
        }

        var role: String? { self["role"]?.lowercased() }

        private static func localName(_ value: String) -> String {
            value.split(separator: ":").last.map(String.init) ?? value
        }
    }

    private final class XMLReader: NSObject, XMLParserDelegate {
        var root: Element?
        private var stack: [Element] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
        ) {
            guard !Task.isCancelled, stack.count < 128 else {
                parser.abortParsing()
                return
            }
            let node = Element(name: elementName, attributes: attributes)
            if let parent = stack.last {
                parent.contents.append(.element(node))
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.contents.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            if let string = String(data: data, encoding: .utf8) {
                stack.last?.contents.append(.text(string))
            }
        }
    }

    private struct Interval {
        let begin: Double
        let end: Double?
        let hasBegin: Bool
    }

    private struct Timing {
        let frameRate: Double
        let subFrameRate: Double
        let tickRate: Double
        let absolute: Bool

        init(root: Element) {
            let baseRate = Self.positive(root["frameRate"]) ?? 30
            let ratio = root["frameRateMultiplier"]?.split(whereSeparator: \.isWhitespace) ?? []
            if ratio.count == 2, let numerator = Self.positive(String(ratio[0])),
               let denominator = Self.positive(String(ratio[1])) {
                frameRate = baseRate * numerator / denominator
            } else {
                frameRate = baseRate
            }
            subFrameRate = Self.positive(root["subFrameRate"]) ?? 1
            tickRate = Self.positive(root["tickRate"]) ?? (root["frameRate"] == nil ? 1 : frameRate * subFrameRate)
            absolute = root.attributes.contains {
                $0.key.hasPrefix("xmlns:") && $0.value.contains("apple.com/lyric-ttml")
            }
        }

        func interval(_ node: Element, in parent: Interval, reference: Double? = nil) -> Interval {
            let origin = absolute ? 0 : (reference ?? parent.begin)
            let beginOffset = seconds(node["begin"])
            let endOffset = seconds(node["end"])
            let duration = seconds(node["dur"])
            let begin = beginOffset.map { origin + $0 } ?? (reference ?? parent.begin)
            let candidates = [
                parent.end,
                endOffset.map { origin + $0 },
                duration.map { begin + $0 }
            ]
            return Interval(
                begin: begin,
                end: candidates.compactMap { $0 }.min(),
                hasBegin: parent.hasBegin || reference != nil || beginOffset != nil || endOffset != nil || duration != nil
            )
        }

        private func seconds(_ expression: String?) -> Double? {
            guard let value = expression?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            if value.contains(":") { return clock(value) }
            let units: [(String, Double)] = [
                ("ms", 0.001), ("h", 3_600), ("m", 60), ("s", 1),
                ("f", 1 / frameRate), ("t", 1 / tickRate)
            ]
            for (unit, multiplier) in units where value.hasSuffix(unit) {
                guard let amount = Double(value.dropLast(unit.count)), amount >= 0 else { return nil }
                let result = amount * multiplier
                return result.isFinite ? result : nil
            }
            return nil
        }

        private func clock(_ value: String) -> Double? {
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            guard (2...4).contains(fields.count),
                  let minutes = Double(fields[fields.count == 2 ? 0 : 1]),
                  let seconds = Double(fields[fields.count == 2 ? 1 : 2]),
                  minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
            let hours = fields.count == 2 ? 0 : Double(fields[0])
            guard let hours, hours >= 0, fields.count == 2 || minutes < 60 else { return nil }
            var result = hours * 3_600 + minutes * 60 + seconds
            if fields.count == 4 {
                let frameParts = fields[3].split(separator: ".", omittingEmptySubsequences: false)
                guard (1...2).contains(frameParts.count),
                      let frames = Double(frameParts[0]), frames >= 0, frames < frameRate else { return nil }
                let subframes = frameParts.count == 2 ? Double(frameParts[1]) : 0
                guard let subframes, subframes >= 0, subframes < subFrameRate else { return nil }
                result += (frames + subframes / subFrameRate) / frameRate
            }
            return result.isFinite ? result : nil
        }

        private static func positive(_ value: String?) -> Double? {
            guard let value, let number = Double(value), number.isFinite, number > 0 else { return nil }
            return number
        }
    }

    private enum Purpose: Hashable {
        case original, translation, pronunciation, background

        init(role: String?) {
            switch role {
            case "x-translation", "translation": self = .translation
            case "x-roman", "x-romanization", "x-transliteration", "x-romaji", "romanization": self = .pronunciation
            case "x-bg", "background": self = .background
            default: self = .original
            }
        }
    }

    private struct Text {
        var builder = LyricsTextBuilder()
        var pendingSpace = false

        mutating func append(_ value: String) {
            for character in value {
                if character.isWhitespace {
                    pendingSpace = builder.count > 0
                } else {
                    if pendingSpace { builder.append(" ") }
                    builder.append(String(character))
                    pendingSpace = false
                }
            }
        }

        mutating func newLine() {
            if builder.count > 0 { builder.append("\n") }
            pendingSpace = false
        }
    }

    static func parse(_ source: String) -> LyricsDocument? {
        guard source.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              source.utf8.count <= 8 * 1_024 * 1_024 else { return nil }
        let reader = XMLReader()
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), let root = reader.root, root.name == "tt",
              !Task.isCancelled else { return nil }
        let timing = Timing(root: root)
        let initial = Interval(begin: 0, end: nil, hasBegin: false)
        let supplements = headSupplements(root)
        var lines: [LyricsLine] = []
        for case .element(let body) in root.contents where body.name == "body" {
            read(body, in: initial, timing: timing, supplements: supplements, into: &lines)
        }
        return lines.isEmpty ? nil : LyricsDocument(lines: lines)
    }

    @discardableResult
    private static func read(
        _ node: Element, in parent: Interval, timing: Timing,
        reference: Double? = nil, supplements: [String: [Purpose: Element]], into lines: inout [LyricsLine]
    ) -> Double? {
        guard !Task.isCancelled else { return nil }
        let interval = timing.interval(node, in: parent, reference: reference)
        if node.name == "p" {
            readLine(node, in: interval, timing: timing, supplements: supplements, into: &lines)
            return interval.end
        }
        let sequential = node["timeContainer"] == "seq" && !timing.absolute
        var cursor: Double?
        var lastEnd: Double?
        for case .element(let child) in node.contents {
            let end = read(child, in: interval, timing: timing, reference: cursor, supplements: supplements, into: &lines)
            if sequential { cursor = end }
            if let end { lastEnd = max(lastEnd ?? end, end) }
        }
        return interval.end ?? lastEnd
    }

    private static func readLine(
        _ node: Element, in interval: Interval, timing: Timing,
        supplements: [String: [Purpose: Element]], into lines: inout [LyricsLine]
    ) {
        var fields: [Purpose: Text] = [:]
        var background: [(Element, Interval)] = []
        collect(node, in: interval, timing: timing, purpose: .original, fields: &fields, background: &background)
        let original = fields[.original]?.builder.finish()
        if let original, !original.text.isEmpty {
            let key = node["key"] ?? node["id"] ?? ""
            for purpose in [Purpose.translation, .pronunciation] where fields[purpose] == nil {
                if let extra = supplements[key]?[purpose] {
                    let extraInterval = timing.interval(extra, in: interval)
                    collect(extra, in: extraInterval, timing: timing, purpose: purpose, fields: &fields, background: &background)
                }
            }
            let translation = fields[.translation]?.builder.finish()
            let pronunciation = fields[.pronunciation]?.builder.finish()
            lines.append(LyricsLine(
                id: lines.count, text: original.text,
                start: interval.hasBegin ? interval.begin : original.words.map(\.start).min(),
                end: lineEnd(node, interval: interval, text: original.text, words: original.words), words: original.words,
                translation: translation.flatMap { $0.text.isEmpty ? nil : $0.text },
                pronunciation: pronunciation.flatMap { $0.text.isEmpty ? nil : $0.text },
                translationWords: translation?.words ?? [], pronunciationWords: pronunciation?.words ?? []
            ))
        }
        for (element, span) in background {
            var fields: [Purpose: Text] = [:]
            var nested: [(Element, Interval)] = []
            collect(element, in: span, timing: timing, purpose: .original, fields: &fields, background: &nested)
            guard let value = fields[.original]?.builder.finish(), !value.text.isEmpty else { continue }
            lines.append(LyricsLine(
                id: lines.count, text: value.text, start: span.hasBegin ? span.begin : value.words.map(\.start).min(),
                end: lineEnd(element, interval: span, text: value.text, words: value.words),
                words: value.words, isBackground: true
            ))
        }
    }

    private static func lineEnd(_ node: Element, interval: Interval, text: String, words: [LyricsWord]) -> Double? {
        if node["end"] == nil, node["dur"] == nil,
           let end = LyricsLine.knownWordEnd(words, in: text) {
            return min(end, interval.end ?? end)
        }
        return interval.end
    }

    private static func collect(
        _ node: Element, in interval: Interval, timing: Timing, purpose: Purpose,
        fields: inout [Purpose: Text], background: inout [(Element, Interval)]
    ) {
        guard !Task.isCancelled else { return }
        let position = fields[purpose, default: Text()].builder.count
        let sequential = node["timeContainer"] == "seq" && !timing.absolute
        var cursor: Double?
        for content in node.contents {
            switch content {
            case .text(let value):
                fields[purpose, default: Text()].append(value)
            case .element(let child):
                if child.name == "br" {
                    fields[purpose, default: Text()].newLine()
                    continue
                }
                let childTiming = timing.interval(child, in: interval, reference: cursor)
                let childPurpose = Purpose(role: child.role)
                if childPurpose == .background {
                    background.append((child, childTiming))
                } else {
                    let activePurpose = childPurpose == .original ? purpose : childPurpose
                    collect(child, in: childTiming, timing: timing, purpose: activePurpose, fields: &fields, background: &background)
                }
                if sequential { cursor = childTiming.end }
            }
        }
        if node.name == "span", interval.hasBegin, node["begin"] != nil || node["end"] != nil || node["dur"] != nil {
            fields[purpose, default: Text()].builder.mark(from: position, start: interval.begin, end: interval.end)
        }
    }

    private static func headSupplements(_ root: Element) -> [String: [Purpose: Element]] {
        var supplements: [String: [Purpose: Element]] = [:]
        func visit(_ node: Element, purpose: Purpose?) {
            let active = switch node.name {
            case "translation", "translations": Purpose.translation
            case "transliteration", "transliterations", "romanization": Purpose.pronunciation
            default: purpose
            }
            if let active, let key = node["for"], supplements[key]?[active] == nil {
                supplements[key, default: [:]][active] = node
            }
            for case .element(let child) in node.contents { visit(child, purpose: active) }
        }
        for case .element(let child) in root.contents where child.name == "head" {
            visit(child, purpose: nil)
        }
        return supplements
    }
}
