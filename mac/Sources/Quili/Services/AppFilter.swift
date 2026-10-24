import Foundation

/// Where the ✦ button may appear: everywhere except the listed apps ("hide"), or only in them ("only").
/// An entry is an app's name or bundle id (for example `Slack` or `com.tinyspeck.slackmacgap`), one per line or
/// separated by commas; blank lines and lines starting with `#` are ignored; matching ignores case.
enum AppFilter {
    static let hideMode = "hide", onlyMode = "only"

    /// `names` are the identifiers of the app that owns the focused field (bundle id, name, executable name).
    static func allows(_ names: [String], mode: String, list: String) -> Bool {
        let entries = parse(list)
        let matches = names.contains { name in entries.contains { $0 == name.lowercased() } }
        return mode == onlyMode ? matches : !matches
    }

    static func parse(_ list: String) -> [String] {
        list.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
