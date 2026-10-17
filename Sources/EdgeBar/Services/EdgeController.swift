import AppKit
import ApplicationServices
import Foundation

/// Launches Edge profiles via the Mach-O binary and focuses existing windows.
///
/// Profile → window mapping uses each profile's `browser.window_placement` from Preferences
/// matched against live AppleScript window bounds. Only exact geometry matches are trusted.
@MainActor
final class EdgeController: ObservableObject {
    static let shared = EdgeController()

    static let edgeBundleID = "com.microsoft.edgemac"
    static let edgeBinaryPath = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"

    /// Max per-edge drift (points) still treated as the same saved placement.
    /// Keep tiny: adjacent profiles often differ by only a few pixels.
    private static let placementTolerance: CGFloat = 1

    private struct ScriptedWindow {
        let id: String
        let index: Int
        let bounds: NSRect
    }

    private struct Placement {
        let directoryName: String
        let bounds: NSRect
    }

    /// Edge AppleScript window id → profile directory name (exact placement matches only).
    private var windowBindings: [String: String] = [:]
    /// Most recently raised window id per profile (must still exact-match that profile's placement).
    private var lastWindowByProfile: [String: String] = [:]
    @Published private(set) var activeProfileDirectory: String?

    init() {
        loadPersistedBindings()
    }

    func ensureAccessibilityPermission() {
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
        let windows = listScriptedWindows()
        rematchFromPlacements(profiles: profiles, windows: windows)
        guard let front = windows.min(by: { $0.index < $1.index }) else {
            activeProfileDirectory = nil
            return
        }
        if let dir = windowBindings[front.id] {
            lastWindowByProfile[dir] = front.id
            activeProfileDirectory = dir
            persistBindings()
        } else {
            activeProfileDirectory = nil
        }
    }

    // MARK: - Focus existing

    @discardableResult
    private func raiseExistingWindow(for profile: EdgeProfile) -> Bool {
        let windows = listScriptedWindows()
        guard !windows.isEmpty else { return false }

        // Rebuild map from disk placements every click — never trust stale nearest-neighbor guesses.
        rematchFromPlacements(profiles: ProfileStore.shared.profiles, windows: windows)

        let placements = loadPlacements(for: [profile])
        guard let placement = placements.first else {
            // No saved placement yet: fall back to an explicit binding (e.g. manual bind / just spawned).
            return raiseBoundWindow(for: profile, windows: windows)
        }

        // Only windows whose live bounds still match this profile's saved placement.
        let geometricMatches = windows
            .filter { Self.boundsEqual($0.bounds, placement.bounds, tolerance: Self.placementTolerance) }
            .sorted { $0.index < $1.index }

        let target: ScriptedWindow?
        if let last = lastWindowByProfile[profile.directoryName],
           let hit = geometricMatches.first(where: { $0.id == last }) {
            target = hit
        } else {
            target = geometricMatches.first
        }

        guard let target else {
            return raiseBoundWindow(for: profile, windows: windows)
        }
        guard raiseScriptedWindow(id: target.id) else { return false }
        bind(windowID: target.id, to: profile.directoryName)
        activeProfileDirectory = profile.directoryName
        return true
    }

    private func raiseBoundWindow(for profile: EdgeProfile, windows: [ScriptedWindow]) -> Bool {
        let matches = windows
            .filter { windowBindings[$0.id] == profile.directoryName }
            .sorted { $0.index < $1.index }
        guard let target = matches.first else { return false }
        guard raiseScriptedWindow(id: target.id) else { return false }
        bind(windowID: target.id, to: profile.directoryName)
        activeProfileDirectory = profile.directoryName
        return true
    }

    /// Exact geometry match only. Clears prior auto-bindings for live windows first so swaps cannot stick.
    private func rematchFromPlacements(profiles: [EdgeProfile], windows: [ScriptedWindow]? = nil) {
        let placements = loadPlacements(for: profiles)
        let windows = windows ?? listScriptedWindows()
        guard !placements.isEmpty, !windows.isEmpty else { return }

        let liveIDs = Set(windows.map(\.id))
        // Drop auto-bindings for windows we can see; rebuild from placements.
        windowBindings = windowBindings.filter { !liveIDs.contains($0.key) }

        var usedWindows = Set<String>()
        // Prefer uniquely matching placements when two profiles share nearly identical rects.
        let ordered = placements.sorted { lhs, rhs in
            uniquenessScore(lhs, among: placements) > uniquenessScore(rhs, among: placements)
        }

        for placement in ordered {
            let hits = windows.filter {
                !usedWindows.contains($0.id)
                    && Self.boundsEqual($0.bounds, placement.bounds, tolerance: Self.placementTolerance)
            }
            // Require a unique geometric hit — never grab the "closest" other profile's window.
            guard hits.count == 1, let window = hits.first else { continue }
            windowBindings[window.id] = placement.directoryName
            lastWindowByProfile[placement.directoryName] = window.id
            usedWindows.insert(window.id)
        }

        lastWindowByProfile = lastWindowByProfile.filter { liveIDs.contains($0.value) }
        persistBindings()
    }

    /// Higher when this placement is farther from every other profile's placement.
    private func uniquenessScore(_ placement: Placement, among all: [Placement]) -> CGFloat {
        let others = all.filter { $0.directoryName != placement.directoryName }
        guard let nearest = others.map({ Self.boundsDistance(placement.bounds, $0.bounds) }).min() else {
            return .greatestFiniteMagnitude
        }
        return nearest
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
            let windows = self.listScriptedWindows()
            self.rematchFromPlacements(profiles: ProfileStore.shared.profiles, windows: windows)
            if let known = self.windowBindings.first(where: { $0.value == profile.directoryName })?.key {
                self.lastWindowByProfile[profile.directoryName] = known
                _ = self.raiseScriptedWindow(id: known)
                self.persistBindings()
                return
            }
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
        // Ensure a window is only claimed by one profile.
        windowBindings = windowBindings.filter { $0.key != windowID && $0.value != directoryName }
        windowBindings[windowID] = directoryName
        lastWindowByProfile[directoryName] = windowID
        persistBindings()
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
