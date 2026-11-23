import Foundation

struct LibraryScanSchedule: Equatable {
    let interval: TimeInterval?
    let lastCompletion: Date?
    let hasSources: Bool

    func delay(now: Date) -> Duration? {
        guard hasSources, let interval else { return nil }
        let remaining = lastCompletion.map { interval - now.timeIntervalSince($0) } ?? 0
        return .seconds(max(0, remaining))
    }
}
