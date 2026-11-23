import Foundation
import Observation

struct ListeningEvent: Codable, Identifiable, Sendable {
    var id = UUID()
    let trackID: String
    let timestamp: Date
    let title: String
    let artist: String
    var seconds: Double
    var started: Bool
}

struct ListeningSummary {
    let count: Int
    let seconds: Double
    let trackCount: Int
    let artistCount: Int
}

struct TrackListening: Identifiable {
    var id: String { track.id }
    let track: AudioTrack
    let count: Int
    let seconds: Double
}

@MainActor
@Observable
final class HistoryStore {
    private(set) var events: [ListeningEvent]
    var continueListening = UserDefaults.standard.object(forKey: "appearance.continueListening") as? Bool ?? true
    @ObservationIgnored private var pendingStart: (id: String, date: Date)?
    @ObservationIgnored private var currentEventIndex: Int?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(file: URL? = nil) {
        let target = file ?? URL.applicationSupportDirectory
            .appending(path: "muzika", directoryHint: .isDirectory)
            .appending(path: "listening.json")
        self.file = target
        if let data = try? Data(contentsOf: target),
           let decoded = try? JSONDecoder().decode([ListeningEvent].self, from: data) {
            events = decoded
        } else {
            events = []
        }
    }

    func started(_ track: AudioTrack) {
        pendingStart = (track.id, .now)
        currentEventIndex = nil
    }

    func listened(_ track: AudioTrack, seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        if let index = currentEventIndex, events[index].trackID == track.id {
            events[index].seconds += seconds
        } else {
            let date = pendingStart?.id == track.id ? pendingStart?.date ?? .now : .now
            events.append(ListeningEvent(
                trackID: track.id, timestamp: date, title: track.title, artist: track.artist,
                seconds: seconds, started: true
            ))
            currentEventIndex = events.indices.last
            pendingStart = nil
        }
        scheduleSave()
    }

    func recent(in library: [AudioTrack]) -> [AudioTrack] {
        let available = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return events.reversed().compactMap { event in
            guard let track = available[event.trackID], seen.insert(track.id).inserted else { return nil }
            return track
        }
    }

    func last(in library: [AudioTrack]) -> AudioTrack? {
        let available = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return events.reversed().lazy.compactMap { available[$0.trackID] }.first
    }

    func onRepeat(in library: [AudioTrack]) -> [AudioTrack] {
        let week = Calendar.current.date(byAdding: .day, value: -7, to: .now)
        return rankings(in: library, since: week).filter { $0.count > 1 }.map(\.track)
    }

    func rankings(in library: [AudioTrack], since: Date? = nil) -> [TrackListening] {
        let grouped = Dictionary(grouping: events(since: since), by: \.trackID)
        return library.compactMap { track in
            guard let plays = grouped[track.id] else { return nil }
            return TrackListening(
                track: track, count: plays.filter(\.started).count,
                seconds: plays.reduce(0) { $0 + $1.seconds }
            )
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            return $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending
        }
    }

    func summarize(since: Date? = nil) -> ListeningSummary {
        let plays = events(since: since)
        return ListeningSummary(
            count: plays.filter(\.started).count,
            seconds: plays.reduce(0) { $0 + $1.seconds },
            trackCount: Set(plays.map(\.trackID)).count,
            artistCount: Set(plays.map { $0.artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }).count
        )
    }

    func clear() {
        events.removeAll()
        pendingStart = nil
        currentEventIndex = nil
        flush()
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(events).write(to: file, options: .atomic)
        } catch {
            MuzikaDiagnostics.report("Listening history: \(error.localizedDescription)")
        }
    }

    private func events(since: Date?) -> [ListeningEvent] {
        guard let since else { return events }
        return events.filter { $0.timestamp >= since }
    }

    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
                self?.flush()
            } catch {}
        }
    }
}
