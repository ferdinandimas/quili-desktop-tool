import Foundation

enum VersionCompare {
    /// Whether the release tag (like "v1.4.0") is newer than the running version, comparing the numeric dotted parts.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        v = String(v.prefix { $0.isNumber || $0 == "." })
        return v.split(separator: ".").map { Int($0) ?? 0 }
    }
}
