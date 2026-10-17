import AppKit
import ApplicationServices
import Foundation

/// Launches Edge profiles via the Mach-O binary and focuses existing windows.
///
/// Profile → window mapping uses each profile's `browser.window_placement` from Preferences
/// matched against live AppleScript window bounds (deterministic, no title scraping).
@MainActor
final class EdgeController: ObservableObject {
    static let shared = EdgeController()

    static let edgeBundleID = "com.microsoft.edgemac"
    static let edgeBinaryPath = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"

    private struct ScriptedWindow {
        let id: String
        let index: Int
        let bounds: NSRect
    }

    private struct Placement {
        let directoryName: String
        let bounds: NSRect
    }

    /// Edge AppleScript window id → profile directory name.
    private var windowBindings: [String: String] = [:]
    /// Most recently raised/focused Edge window id per profile directory.
    private var lastWindowByProfile: [String: String] = [:]
    private var learnTimer: Timer?
    @Published private(set) var activeProfileDirectory: String?

    init() {
        loadPersistedBindings()
        startLearning()
    }

    func ensureAccessibilityPermission() {
        // Kept for optional AX features; focusing no longer depends on Accessibility.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

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
        guard let front = listScriptedWindows().min(by: { $0.index < $1.index }) else { return }
        bind(windowID: front.id, to: profile.directoryName)
        _ = raiseScriptedWindow(id: front.id)
        activeProfileDirectory = profile.directoryName
    }

    func refreshActiveProfile(from profiles: [EdgeProfile]) {
        guard edgeRunningApp()?.isActive == true else {
            activeProfileDirectory = nil
            return
        }
        learnFromFrontWindow(profiles: profiles)
    }

    // MARK: - Focus existing

    @discardableResult
    private func raiseExistingWindow(for profile: EdgeProfile) -> Bool {
        let windows = listScriptedWindows()
        guard !windows.isEmpty else { return false }
        rematchFromPlacements(profiles: ProfileStore.shared.profiles, windows: windows)

        let live = Set(windows.map(\.id))
        pruneStaleBindings(liveIDs: live)

        // Prefer last-raised for this profile, else frontmost (lowest index) among matches.
        let matches = windows
            .filter { windowBindings[$0.id] == profile.directoryName }
            .sorted { $0.index < $1.index }

        let target: ScriptedWindow?
        if let last = lastWindowByProfile[profile.directoryName],
           let hit = matches.first(where: { $0.id == last }) {
            target = hit
        } else {
            target = matches.first
        }

        guard let target else { return false }
        guard raiseScriptedWindow(id: target.id) else { return false }
        bind(windowID: target.id, to: profile.directoryName)
        activeProfileDirectory = profile.directoryName
        return true
    }

    /// Match live window bounds to each profile's saved `browser.window_placement`.
    private func rematchFromPlacements(profiles: [EdgeProfile], windows: [ScriptedWindow]? = nil) {
        let placements = loadPlacements(for: profiles)
        guard !placements.isEmpty else { return }

        let windows = windows ?? listScriptedWindows()
        guard !windows.isEmpty else { return }

        var usedWindows = Set<String>()
        var usedProfiles = Set<String>()

        // Exact matches first.
        for placement in placements {
            if let window = windows.first(where: {
                !usedWindows.contains($0.id) && Self.boundsEqual($0.bounds, placement.bounds, tolerance: 2)
            }) {
                bind(windowID: window.id, to: placement.directoryName)
                usedWindows.insert(window.id)
                usedProfiles.insert(placement.directoryName)
            }
        }

        // Nearest remaining pairs within a small slack (window moved slightly before Preferences flushed).
        let remainingPlacements = placements.filter { !usedProfiles.contains($0.directoryName) }
        let remainingWindows = windows.filter { !usedWindows.contains($0.id) }
        for placement in remainingPlacements {
            let best = remainingWindows
                .map { (window: $0, distance: Self.boundsDistance($0.bounds, placement.bounds)) }
                .filter { $0.distance <= 24 }
                .min(by: { $0.distance < $1.distance })
            if let best, !usedWindows.contains(best.window.id) {
                bind(windowID: best.window.id, to: placement.directoryName)
                usedWindows.insert(best.window.id)
            }
        }
    }

    private func loadPlacements(for profiles: [EdgeProfile]) -> [Placement] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Microsoft Edge", isDirectory: true)
        var result: [Placement] = []
        for profile in profiles {
            let prefsURL = support
                .appendingPathComponent(profile.directoryName, isDirectory: true)
                .appendingPathComponent("Preferences")
            guard let data = try? Data(contentsOf: prefsURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let browser = root["browser"] as? [String: Any],
                  let placement = browser["window_placement"] as? [String: Any]
            else { continue }

            func num(_ key: String) -> CGFloat? {
                if let i = placement[key] as? Int { return CGFloat(i) }
                if let d = placement[key] as? Double { return CGFloat(d) }
                if let n = placement[key] as? NSNumber { return CGFloat(truncating: n) }
                return nil
            }
            guard let left = num("left"),
                  let top = num("top"),
                  let right = num("right"),
                  let bottom = num("bottom"),
                  right > left, bottom > top
            else { continue }

            result.append(
                Placement(
                    directoryName: profile.directoryName,
                    bounds: NSRect(x: left, y: top, width: right - left, height: bottom - top)
                )
            )
        }
        return result
    }

    private static func boundsEqual(_ a: NSRect, _ b: NSRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance
            && abs(a.maxY - b.maxY) <= tolerance
    }

    private static func boundsDistance(_ a: NSRect, _ b: NSRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.maxX - b.maxX) + abs(a.maxY - b.maxY)
    }

    // MARK: - Learning

    private func startLearning() {
        learnTimer?.invalidate()
        // Light touch: only track the front window id while Edge is active.
        learnTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.learnFromFrontWindow(profiles: ProfileStore.shared.profiles)
            }
        }
    }

    private func learnFromFrontWindow(profiles: [EdgeProfile]) {
        guard edgeRunningApp()?.isActive == true else { return }
        guard let frontID = frontScriptedWindowID() else { return }
        if let dir = windowBindings[frontID] {
            lastWindowByProfile[dir] = frontID
            activeProfileDirectory = dir
            persistBindings()
            return
        }
        if let lastUsed = ProfileStore.shared.lastUsedDirectory,
           profiles.contains(where: { $0.directoryName == lastUsed }) {
            bind(windowID: frontID, to: lastUsed)
            activeProfileDirectory = lastUsed
        }
    }

    private func frontScriptedWindowID() -> String? {
        let source = """
        tell application "Microsoft Edge"
          if (count of windows) is 0 then return ""
          return id of window 1 as text
        end tell
        """
        let value = runAppleScript(source)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
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
            set b to bounds of w
            set out to out & wid & rs & windex & rs & (item 1 of b as text) & rs & (item 2 of b as text) & rs & (item 3 of b as text) & rs & (item 4 of b as text) & linefeed
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
            let c = String(line).components(separatedBy: rs)
            guard c.count >= 6,
                  let index = Int(c[1]),
                  let left = Double(c[2]),
                  let top = Double(c[3]),
                  let right = Double(c[4]),
                  let bottom = Double(c[5]),
                  right > left, bottom > top
            else { continue }
            result.append(
                ScriptedWindow(
                    id: c[0],
                    index: index,
                    bounds: NSRect(x: left, y: top, width: right - left, height: bottom - top)
                )
            )
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
          on error
            return "err"
          end try
        end tell
        """
        return (runAppleScript(source) ?? "") == "ok"
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

        scheduleWindowBinding(profile: profile, excluding: existingIDs, attempts: 30)
        activeProfileDirectory = profile.directoryName
    }

    private func scheduleWindowBinding(profile: EdgeProfile, excluding: Set<String>, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            // Prefer placement rematch once Preferences catch up; also bind any brand-new id.
            self.rematchFromPlacements(profiles: ProfileStore.shared.profiles)
            if let known = self.lastWindowByProfile[profile.directoryName]
                ?? self.windowBindings.first(where: { $0.value == profile.directoryName })?.key {
                _ = self.raiseScriptedWindow(id: known)
                return
            }
            if let fresh = self.listScriptedWindows().first(where: { !excluding.contains($0.id) }) {
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
            windowBindings = raw
        }
        if let raw = UserDefaults.standard.dictionary(forKey: PreferencesKeys.lastWindowByProfile) as? [String: String] {
            lastWindowByProfile = raw
        }
    }

    private func edgeRunningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.edgeBundleID
        }
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
