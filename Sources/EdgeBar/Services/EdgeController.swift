import AppKit
import ApplicationServices
import Foundation

/// Launches Edge profiles via the Mach-O binary and focuses existing windows.
///
/// Primary focusing uses Microsoft Edge's AppleScript dictionary (no Accessibility required).
/// Accessibility remains a secondary path for binding the focused AX window when trusted.
@MainActor
final class EdgeController: ObservableObject {
    static let shared = EdgeController()

    static let edgeBundleID = "com.microsoft.edgemac"
    static let edgeBinaryPath = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"

    private struct ScriptedWindow {
        let id: String
        let index: Int
        let name: String
        let tabTitle: String

        var haystack: String { "\(name)\n\(tabTitle)" }
    }

    /// Edge AppleScript window id → profile directory name.
    private var windowBindings: [String: String] = [:]
    /// Most recently raised/focused Edge window id per profile directory.
    private var lastWindowByProfile: [String: String] = [:]
    @Published private(set) var activeProfileDirectory: String?

    init() {
        loadPersistedBindings()
    }

    func ensureAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Public actions

    /// Focus an existing window for the profile, or spawn one if none match.
    func activate(profile: EdgeProfile, forceNewWindow: Bool = false, url: String? = nil) {
        if let url, !url.isEmpty {
            open(url: url, in: profile)
            return
        }

        if !forceNewWindow, raiseExistingWindow(for: profile) {
            return
        }

        spawn(profile: profile, url: nil)
    }

    func open(url: String, in profile: EdgeProfile) {
        spawn(profile: profile, url: url)
    }

    func openClipboardURL(in profile: EdgeProfile) {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = Self.normalizeURL(raw)
        else { return }
        open(url: url, in: profile)
    }

    func bindFrontmostEdgeWindow(to profile: EdgeProfile) {
        if let front = listScriptedWindows().first {
            bind(windowID: front.id, to: profile.directoryName)
            _ = raiseScriptedWindow(id: front.id)
            activeProfileDirectory = profile.directoryName
            return
        }

        guard isAccessibilityTrusted,
              let edgeApp = edgeRunningApp()
        else { return }
        let appElement = AXUIElementCreateApplication(edgeApp.processIdentifier)
        guard let focused = copyAXElement(appElement, kAXFocusedWindowAttribute) else { return }
        // Best-effort: still activate Edge even if we cannot map an AppleScript id.
        edgeApp.activate()
        AXUIElementPerformAction(focused, kAXRaiseAction as CFString)
        activeProfileDirectory = profile.directoryName
    }

    func refreshActiveProfile(from profiles: [EdgeProfile]) {
        guard let edgeApp = edgeRunningApp(), edgeApp.isActive else {
            activeProfileDirectory = nil
            return
        }

        let windows = listScriptedWindows()
        pruneStaleBindings(liveIDs: Set(windows.map(\.id)))

        guard let front = windows.first else {
            activeProfileDirectory = nil
            return
        }

        if let dir = windowBindings[front.id] {
            lastWindowByProfile[dir] = front.id
            activeProfileDirectory = dir
            persistBindings()
            return
        }

        if let match = matchProfile(haystack: front.haystack, profiles: profiles) {
            bind(windowID: front.id, to: match.directoryName)
            activeProfileDirectory = match.directoryName
            return
        }

        inferMissingBindings(windows: windows, store: ProfileStore.shared)
        if let dir = windowBindings[front.id] {
            lastWindowByProfile[dir] = front.id
            activeProfileDirectory = dir
            persistBindings()
            return
        }

        if let lastUsed = ProfileStore.shared.lastUsedDirectory,
           profiles.contains(where: { $0.directoryName == lastUsed }) {
            bind(windowID: front.id, to: lastUsed)
            activeProfileDirectory = lastUsed
            return
        }

        activeProfileDirectory = nil
    }

    // MARK: - Focus existing

    @discardableResult
    private func raiseExistingWindow(for profile: EdgeProfile) -> Bool {
        var windows = listScriptedWindows()
        guard !windows.isEmpty else { return false }

        pruneStaleBindings(liveIDs: Set(windows.map(\.id)))
        inferMissingBindings(windows: windows, store: ProfileStore.shared)
        windows = listScriptedWindows()

        var matches = windows.filter { windowBindings[$0.id] == profile.directoryName }

        if matches.isEmpty {
            for window in windows where windowBindings[window.id] == nil {
                if matchProfile(haystack: window.haystack, profiles: [profile]) != nil {
                    bind(windowID: window.id, to: profile.directoryName)
                    matches.append(window)
                }
            }
        }

        // Re-check bindings after matching pass.
        if matches.isEmpty {
            matches = windows.filter { windowBindings[$0.id] == profile.directoryName }
        }

        guard !matches.isEmpty else { return false }

        let target: ScriptedWindow
        if let lastID = lastWindowByProfile[profile.directoryName],
           let last = matches.first(where: { $0.id == lastID }) {
            target = last
        } else {
            // AppleScript windows are ordered front-to-back; lowest index is latest/frontmost.
            target = matches.min(by: { $0.index < $1.index }) ?? matches[0]
        }

        guard raiseScriptedWindow(id: target.id) else { return false }
        bind(windowID: target.id, to: profile.directoryName)
        activeProfileDirectory = profile.directoryName
        return true
    }

    private func inferMissingBindings(windows: [ScriptedWindow], store: ProfileStore) {
        let profiles = store.profiles
        guard !windows.isEmpty, !profiles.isEmpty else { return }

        for window in windows where windowBindings[window.id] == nil {
            if let match = matchProfile(haystack: window.haystack, profiles: profiles) {
                bind(windowID: window.id, to: match.directoryName)
            }
        }

        let activeDirs = Set(store.lastActiveDirectories.isEmpty
            ? profiles.map(\.directoryName)
            : store.lastActiveDirectories)
        let boundDirs = Set(windowBindings.values)
        let unboundDirs = activeDirs.subtracting(boundDirs)
        let unboundWindows = windows.filter { windowBindings[$0.id] == nil }

        if unboundDirs.count == 1, unboundWindows.count == 1,
           let dir = unboundDirs.first, let window = unboundWindows.first {
            bind(windowID: window.id, to: dir)
        }
    }

    private func matchProfile(haystack: String, profiles: [EdgeProfile]) -> EdgeProfile? {
        let lower = haystack.lowercased()

        // Prefer email / userName hits — unique and present in many Edge tab titles.
        let emailHits = profiles.filter { profile in
            guard let email = profile.userName?.lowercased(), !email.isEmpty else { return false }
            return lower.contains(email)
        }
        if emailHits.count == 1 { return emailHits[0] }
        if emailHits.count > 1 {
            return emailHits.max(by: { ($0.userName?.count ?? 0) < ($1.userName?.count ?? 0) })
        }

        let ranked = profiles.sorted {
            ($0.titleMatchTokens.map(\.count).max() ?? 0) > ($1.titleMatchTokens.map(\.count).max() ?? 0)
        }
        for profile in ranked {
            if titleMatches(lower, profile: profile) {
                return profile
            }
        }
        return nil
    }

    private func titleMatches(_ lowerHaystack: String, profile: EdgeProfile) -> Bool {
        for token in profile.titleMatchTokens {
            let t = token.lowercased()
            guard !t.isEmpty else { continue }
            // Require structured title segments so page titles (e.g. containing "Ortet") do not steal matches.
            if lowerHaystack.contains(" - \(t) - ")
                || lowerHaystack.contains(" - \(t)\n")
                || lowerHaystack.hasSuffix(" - \(t)")
                || lowerHaystack == t
                || lowerHaystack.contains(" - \(t) - microsoft edge") {
                return true
            }
        }
        if let windowName = profile.windowName?.lowercased(), !windowName.isEmpty {
            if lowerHaystack.contains(windowName) { return true }
        }
        return false
    }

    // MARK: - AppleScript bridge

    private func listScriptedWindows() -> [ScriptedWindow] {
        let source = """
        tell application "Microsoft Edge"
          if (count of windows) is 0 then return ""
          set rs to ASCII character 30
          set out to ""
          repeat with w in windows
            set wid to id of w as text
            set windex to index of w as text
            set wname to name of w as text
            set wtab to ""
            try
              set wtab to title of active tab of w as text
            end try
            set out to out & wid & rs & windex & rs & wname & rs & wtab & linefeed
          end repeat
          return out
        end tell
        """
        guard let output = runAppleScript(source)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty
        else { return [] }

        let rs = String(Character(UnicodeScalar(30)!))
        var result: [ScriptedWindow] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let comps = String(line).components(separatedBy: rs)
            guard comps.count >= 3, let index = Int(comps[1]) else { continue }
            let name = comps[2]
            let tab = comps.count > 3 ? comps[3] : ""
            result.append(ScriptedWindow(id: comps[0], index: index, name: name, tabTitle: tab))
        }
        return result
    }

    private func raiseScriptedWindow(id: String) -> Bool {
        let escaped = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Microsoft Edge"
          activate
          try
            set index of window id "\(escaped)" to 1
            return "ok"
          on error errMsg
            return "err:" & errMsg
          end try
        end tell
        """
        let result = runAppleScript(source) ?? ""
        return result == "ok"
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    // MARK: - Launch

    private func spawn(profile: EdgeProfile, url: String?) {
        let edgeBinary = URL(fileURLWithPath: Self.edgeBinaryPath)
        guard FileManager.default.isExecutableFile(atPath: edgeBinary.path) else { return }

        let existingIDs = Set(listScriptedWindows().map(\.id))

        let process = Process()
        process.executableURL = edgeBinary
        var args = ["--profile-directory=\(profile.directoryName)"]
        if let url, !url.isEmpty {
            args.append(url)
        }
        process.arguments = args
        do {
            try process.run()
        } catch {
            return
        }

        scheduleWindowBinding(profile: profile, excluding: existingIDs, attempts: 25)
        activeProfileDirectory = profile.directoryName
    }

    private func scheduleWindowBinding(profile: EdgeProfile, excluding: Set<String>, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let windows = self.listScriptedWindows()
            if let fresh = windows.first(where: { !excluding.contains($0.id) }) {
                self.bind(windowID: fresh.id, to: profile.directoryName)
                _ = self.raiseScriptedWindow(id: fresh.id)
                return
            }
            self.scheduleWindowBinding(profile: profile, excluding: excluding, attempts: attempts - 1)
        }
    }

    // MARK: - Bindings

    private func bind(windowID: String, to directoryName: String) {
        windowBindings[windowID] = directoryName
        lastWindowByProfile[directoryName] = windowID
        persistBindings()
    }

    private func pruneStaleBindings(liveIDs: Set<String>) {
        let before = windowBindings.count
        windowBindings = windowBindings.filter { liveIDs.contains($0.key) }
        lastWindowByProfile = lastWindowByProfile.filter { liveIDs.contains($0.value) }
        if windowBindings.count != before {
            persistBindings()
        }
    }

    private func persistBindings() {
        UserDefaults.standard.set(windowBindings, forKey: PreferencesKeys.windowBindings)
        UserDefaults.standard.set(lastWindowByProfile, forKey: PreferencesKeys.lastWindowByProfile)
    }

    private func loadPersistedBindings() {
        if let raw = UserDefaults.standard.dictionary(forKey: PreferencesKeys.windowBindings) as? [String: String] {
            // Migrate away from old CGWindowID numeric keys if Edge was restarted; keep whatever is present.
            windowBindings = raw
        }
        if let raw = UserDefaults.standard.dictionary(forKey: PreferencesKeys.lastWindowByProfile) as? [String: String] {
            lastWindowByProfile = raw
        }
    }

    // MARK: - AX helpers (secondary)

    private func edgeRunningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.edgeBundleID
        }
    }

    private func copyAXElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated static func normalizeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return "https://\(trimmed)"
        }
        if let url = URL(string: trimmed), url.scheme != nil {
            return trimmed
        }
        return nil
    }
}
