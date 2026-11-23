import Foundation

enum ApplicationMetadata {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MUZIKA?"
    static let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "—"
    static let version = Int(build).map { "v\($0)" } ?? "—"
    static let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
}
