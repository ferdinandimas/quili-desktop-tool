import AppKit
import ApplicationServices

/// "Check setup…" and "Check for updates…" from the menu, and the quiet daily update check at startup.
@MainActor
enum Checkups {
    private static let latestReleaseUrl = "https://api.github.com/repos/ferdinandimas/quili-desktop-tool/releases/latest"
    private static let day: TimeInterval = 24 * 3600

    // MARK: Setup

    /// Settings, the server and the Accessibility permission, one line each (✓ works, ✗ needs attention).
    static func checkSetup(settings: Settings) async {
        var lines: [(ok: Bool, text: String)] = []
        let ready = settings.mockMode || (!settings.serverUrl.trimmingCharacters(in: .whitespaces).isEmpty && !settings.apiKey.isEmpty)
        if settings.mockMode { lines.append((true, "Mock server (offline) is on")) }
        else if ready { lines.append((true, "Settings: server URL and API key are set")) }
        else { lines.append((false, "Settings: set the server URL and API key")) }

        if ready, !settings.mockMode { lines.append(await serverLine(settings)) }

        let trusted = AXIsProcessTrusted()
        lines.append((trusted, trusted ? "Accessibility permission: granted"
                                       : "Accessibility permission: not granted. Open System Settings → Privacy & Security → Accessibility"))

        let allOk = lines.allSatisfy(\.ok)
        let alert = NSAlert()
        alert.messageText = "Quili setup"
        alert.informativeText = lines.map { ($0.ok ? "✓ " : "✗ ") + $0.text }.joined(separator: "\n")
        alert.alertStyle = allOk ? .informational : .warning
        alert.addButton(withTitle: "OK")
        if !trusted { alert.addButton(withTitle: "Open Accessibility Settings") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// An empty POST to the paraphrase endpoint: a reachable server with a good key answers 422 (nothing to rewrite).
    private static func serverLine(_ settings: Settings) async -> (ok: Bool, text: String) {
        guard let url = URL(string: ParaphraseClient.normalize(settings.serverUrl) + "/api/paraphrase") else {
            return (false, "Can't reach the server")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = Data("{}".utf8)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 422: return (true, "Server reachable and the API key works")
            case 401: return (false, "The server rejected the API key")
            case 503: return (false, "The server has no API key configured")
            case let status: return (false, "The server answered with status \(status)")
            }
        } catch {
            return (false, "Can't reach the server")
        }
    }

    // MARK: Updates

    private struct Release {
        let tag: String
        let url: String
    }

    private static func latestRelease() async -> Release? {
        guard let url = URL(string: latestReleaseUrl) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Quili/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let page = json["html_url"] as? String else { return nil }
        return Release(tag: tag, url: page)
    }

    /// The menu's "Check for updates…": says where things stand either way.
    static func checkForUpdates() async {
        let release = await latestRelease()
        let alert = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        guard let release else {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Try again later."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        if VersionCompare.isNewer(release.tag, than: AppInfo.version) {
            alert.messageText = "Quili \(release.tag) is available"
            alert.informativeText = "Open the release page?"
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: release.url) { NSWorkspace.shared.open(url) }
        } else {
            alert.messageText = "Quili is up to date"
            alert.informativeText = "You have version \(AppInfo.version)."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// At startup, with "Check for updates once a day" on and the last check more than a day old: asks GitHub quietly and
    /// only speaks up when there is a newer release. The time is saved after every attempt, failed or not.
    static func checkInBackground(settings: Settings) async {
        guard settings.autoUpdateCheck, Date().timeIntervalSince(settings.lastUpdateCheck) > day else { return }
        let release = await latestRelease()
        settings.lastUpdateCheck = Date()
        guard let release, VersionCompare.isNewer(release.tag, than: AppInfo.version) else { return }
        DebugLog.write("update available: \(release.tag)")
        Notifier.show("Quili \(release.tag) is available", "Open the menu and choose Check for updates… to get it.")
    }
}
