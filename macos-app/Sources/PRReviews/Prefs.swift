import Foundation

enum Prefs {
    static let pollMinutesKey = "pollMinutes"
    static let includeDraftsKey = "includeDrafts"
    static let excludeTitleKey = "excludeTitleRegex"
    static let ghPathKey = "ghPath"

    static let defaultExcludeTitle = "DO NOT REVIEW|WIP"

    private static var defaults: UserDefaults { .standard }

    static var pollMinutes: Int {
        let value = defaults.integer(forKey: pollMinutesKey)
        return value > 0 ? value : 1
    }

    static var includeDrafts: Bool { defaults.bool(forKey: includeDraftsKey) }
    static var excludeTitleRegex: String { defaults.string(forKey: excludeTitleKey) ?? defaultExcludeTitle }
    static var ghPath: String { defaults.string(forKey: ghPathKey) ?? "" }
}
