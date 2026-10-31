import AppKit
import ApplicationServices
import Foundation

/// Launches Edge profiles via the Mach-O binary and treats each profile as a workspace.
///
/// Selecting a profile restores windows EdgeBar previously hid for it, raises the last-focused
/// one, and minimizes windows bound to every other profile. Unidentified windows are left alone.
/// A profile may own many windows. Geometry (`browser.window_placement`) claims an unbound
/// window only when the match is unique; later windows inherit the front profile, or the spawn
/// that created them.
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
        let minimized: Bool
        let minimizable: Bool
    }

    private struct Placement {
        let directoryName: String
        let bounds: NSRect
    }

    private struct PendingSpawn {
        let token: UUID
        let directoryName: String
        /// Window ids that already existed when the spawn was issued.
        let excluding: Set<String>
    }

    private enum WorkspaceResult {
        case shown
        case noWindow
        case failed
    }

    /// Edge AppleScript window id → profile directory name. Many windows may share a directory.
    private var windowBindings: [String: String] = [:]
    /// Window ids bound via the context-menu action; geometry must not overwrite these.
    private var manualWindowIDs: Set<String> = []
    /// Most recently focused window id per profile (must still be bound to that profile).
    private var lastWindowByProfile: [String: String] = [:]
    /// Windows this app minimized on a profile switch. User-minimized windows are not in this set.
    private var workspaceHiddenIDs: Set<String> = []
    private var observedWindowIDs: Set<String> = []
    private var observedFrontDirectory: String?
    private var hasObservedWindows = false
    private var pendingSpawn: PendingSpawn?

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

    /// Show this profile's workspace, or spawn a window when it has none.
    func activate(profile: EdgeProfile, forceNewWindow: Bool = false, url: String? = nil) {
        if let url, !url.isEmpty {
            open(url: url, in: profile)
            return
        }

        switch showWorkspace(for: profile) {
        case .shown:
            if !forceNewWindow { return }
            spawn(profile: profile, url: nil)
        case .noWindow:
            spawn(profile: profile, url: nil)
        case .failed:
            if forceNewWindow {
                spawn(profile: profile, url: nil)
            }
        }
    }

    func open(url: String, in profile: EdgeProfile) {
        _ = showWorkspace(for: profile)
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
        guard edgeIsRunning else { return }
        let windows = listScriptedWindows()
        guard let front = windows.filter({ !$0.minimized }).min(by: { $0.index < $1.index })
            ?? windows.min(by: { $0.index < $1.index })
        else { return }
        manualWindowIDs.insert(front.id)
        bind(windowID: front.id, to: profile.directoryName)
        _ = showWorkspace(for: profile, preferredID: front.id)
    }

    func refreshActiveProfile(from profiles: [EdgeProfile]) {
        guard edgeIsRunning else {
            activeProfileDirectory = nil
            resetObservation()
            return
        }

        let windows = listScriptedWindows()
        rematchFromPlacements(profiles: profiles, windows: windows)
        if let directory = adoptNewWindows(among: windows),
           let profile = profiles.first(where: { $0.directoryName == directory }) {
            _ = showWorkspace(for: profile)
            return
        }

        guard edgeRunningApp()?.isActive == true else {
            activeProfileDirectory = nil
            observedWindowIDs = Set(windows.map(\.id))
            hasObservedWindows = true
            return
        }

        let visibleFront = windows.filter { !$0.minimized }.min(by: { $0.index < $1.index })
        if let visibleFront, let dir = windowBindings[visibleFront.id] {
            lastWindowByProfile[dir] = visibleFront.id
            activeProfileDirectory = dir
            persistBindings()
            noteObservation(windows, frontDirectory: dir)
        } else {
            activeProfileDirectory = nil
            let frontDirectory = visibleFront.flatMap { windowBindings[$0.id] }
            noteObservation(windows, frontDirectory: frontDirectory)
        }
    }

    // MARK: - Workspace

    /// Minimizes other profiles, restores windows this app hid for `profile`, and raises one window.
    @discardableResult
    private func showWorkspace(for profile: EdgeProfile, preferredID: String? = nil) -> WorkspaceResult {
        guard edgeIsRunning else { return .noWindow }

        if let pending = pendingSpawn, pending.directoryName != profile.directoryName {
            pendingSpawn = nil
        }

        let windows = listScriptedWindows()
        guard !windows.isEmpty else { return .noWindow }

        rematchFromPlacements(profiles: ProfileStore.shared.profiles, windows: windows)
        _ = adoptNewWindows(among: windows)

        let ours = windows.filter { windowBindings[$0.id] == profile.directoryName }
        let minimizeIDs = windows.compactMap { window -> String? in
            guard let owner = windowBindings[window.id], owner != profile.directoryName else { return nil }
            guard window.minimizable, !window.minimized else { return nil }
            return window.id
        }

        guard !ours.isEmpty else {
            if minimizeIDs.isEmpty {
                noteObservation(windows, frontDirectory: observedFrontDirectory)
                return .noWindow
            }
            guard applyWindowWorkspace(minimize: minimizeIDs, restore: [], raise: nil) else {
                return .failed
            }
            workspaceHiddenIDs.formUnion(minimizeIDs)
            noteObservation(windows, frontDirectory: observedFrontDirectory)
            persistBindings()
            return .noWindow
        }

        let raise = chooseWindowToRaise(among: ours, profile: profile, preferredID: preferredID)
        var restoreIDs = ours.filter { workspaceHiddenIDs.contains($0.id) && $0.minimized }.map(\.id)
        if let raise, raise.minimized, !restoreIDs.contains(raise.id) {
            let someoneElseVisible = ours.contains { !$0.minimized && $0.id != raise.id }
            let someoneElseHidden = ours.contains { workspaceHiddenIDs.contains($0.id) && $0.id != raise.id }
            if !someoneElseVisible && !someoneElseHidden {
                restoreIDs.append(raise.id)
            }
        }

        guard applyWindowWorkspace(minimize: minimizeIDs, restore: restoreIDs, raise: raise?.id) else {
            return .failed
        }

        workspaceHiddenIDs.formUnion(minimizeIDs)
        workspaceHiddenIDs.subtract(restoreIDs)
        if let raise {
            lastWindowByProfile[profile.directoryName] = raise.id
        }
        activeProfileDirectory = profile.directoryName
        noteObservation(windows, frontDirectory: profile.directoryName)
        persistBindings()
        return .shown
    }

    /// Prefer the last-focused window when it is already visible or was hidden by a profile switch.
    /// A window the user minimized stays down while another window of the profile can be shown.
    private func chooseWindowToRaise(
        among ours: [ScriptedWindow],
        profile: EdgeProfile,
        preferredID: String?
    ) -> ScriptedWindow? {
        if let preferredID, let hit = ours.first(where: { $0.id == preferredID }) {
            return hit
        }

        func rank(_ window: ScriptedWindow) -> Int {
            if !window.minimized { return 0 }
            if workspaceHiddenIDs.contains(window.id) { return 1 }
            return 2
        }

        guard let best = ours.map(rank).min() else { return nil }
        if let lastID = lastWindowByProfile[profile.directoryName],
           let last = ours.first(where: { $0.id == lastID }),
           rank(last) == best {
            return last
        }
        return ours.filter { rank($0) == best }.min(by: { $0.index < $1.index })
    }

    /// Binds windows that appeared since the last observation.
    /// Returns a profile directory when a pending spawn received a window that should be shown.
    private func adoptNewWindows(among windows: [ScriptedWindow]) -> String? {
        guard hasObservedWindows else { return nil }
        let newcomers = windows.filter { !observedWindowIDs.contains($0.id) }
        guard !newcomers.isEmpty else { return nil }

        if let pending = pendingSpawn {
            let arrived = newcomers.filter { !pending.excluding.contains($0.id) }
            let unbound = arrived.filter { windowBindings[$0.id] == nil }
            if unbound.count == 1, let only = unbound.first {
                bind(windowID: only.id, to: pending.directoryName)
            }
            let satisfied = arrived.contains { windowBindings[$0.id] == pending.directoryName }
            guard satisfied else { return nil }
            pendingSpawn = nil
            return pending.directoryName
        }

        guard let inherit = observedFrontDirectory else { return nil }
        for window in newcomers where windowBindings[window.id] == nil {
            bind(windowID: window.id, to: inherit)
        }
        return nil
    }

    private func noteObservation(_ windows: [ScriptedWindow], frontDirectory: String?) {
        observedWindowIDs = Set(windows.map(\.id))
        observedFrontDirectory = frontDirectory
        hasObservedWindows = true
    }

    private func resetObservation() {
        observedWindowIDs = []
        observedFrontDirectory = nil
        hasObservedWindows = false
        pendingSpawn = nil
    }

    /// Unique geometry claims unbound windows only. Existing and manual bindings stay.
    private func rematchFromPlacements(profiles: [EdgeProfile], windows: [ScriptedWindow]? = nil) {
        let placements = loadPlacements(for: profiles)
        let windows = windows ?? listScriptedWindows()
        guard !windows.isEmpty else { return }

        let liveIDs = Set(windows.map(\.id))
        manualWindowIDs = manualWindowIDs.intersection(liveIDs)
        windowBindings = windowBindings.filter { liveIDs.contains($0.key) }
        workspaceHiddenIDs = workspaceHiddenIDs.intersection(liveIDs)
        let revealed = Set(windows.filter { !$0.minimized }.map(\.id))
        workspaceHiddenIDs.subtract(revealed)

        var claimed = Set<String>()
        let ordered = placements.sorted { lhs, rhs in
            uniquenessScore(lhs, among: placements) > uniquenessScore(rhs, among: placements)
        }

        for placement in ordered {
            let hits = windows.filter { window in
                !claimed.contains(window.id)
                    && !manualWindowIDs.contains(window.id)
                    && windowBindings[window.id] == nil
                    && Self.boundsEqual(window.bounds, placement.bounds, tolerance: Self.placementTolerance)
            }
            guard hits.count == 1, let window = hits.first else { continue }
            windowBindings[window.id] = placement.directoryName
            claimed.insert(window.id)
            let currentLast = lastWindowByProfile[placement.directoryName]
            let lastIsLive = currentLast.map { liveIDs.contains($0) && windowBindings[$0] == placement.directoryName } ?? false
            if !lastIsLive {
                lastWindowByProfile[placement.directoryName] = window.id
            }
        }

        lastWindowByProfile = lastWindowByProfile.filter { directory, id in
            liveIDs.contains(id) && windowBindings[id] == directory
        }
        persistBindings()
    }

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

    private var edgeIsRunning: Bool { edgeRunningApp() != nil }

    private func listScriptedWindows() -> [ScriptedWindow] {
        // Never `tell application "Microsoft Edge"` when it is quit — that launches it.
        guard edgeIsRunning else { return [] }

        let source = """
        tell application "Microsoft Edge"
          if (count of windows) is 0 then return ""
          set rs to ASCII character 30
          set out to ""
          repeat with w in windows
            set wid to id of w as text
            set windex to index of w as text
            set b to bounds of w
            set mini to minimized of w as text
            set canMini to minimizable of w as text
            set out to out & wid & rs & windex & rs & (item 1 of b as text) & rs & (item 2 of b as text) & rs & (item 3 of b as text) & rs & (item 4 of b as text) & rs & mini & rs & canMini & linefeed
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
            guard c.count >= 8,
                  !c[0].isEmpty,
                  let index = Int(c[1]),
                  let left = Double(c[2]),
                  let top = Double(c[3]),
                  let right = Double(c[4]),
                  let bottom = Double(c[5])
            else { continue }
            // Minimized windows sometimes report an empty rect. Keep them so they can be restored.
            let bounds: NSRect
            if right > left, bottom > top {
                bounds = NSRect(x: left, y: top, width: right - left, height: bottom - top)
            } else {
                bounds = .zero
            }
            result.append(
                ScriptedWindow(
                    id: c[0],
                    index: index,
                    bounds: bounds,
                    minimized: Self.appleScriptBool(c[6]),
                    minimizable: Self.appleScriptBool(c[7])
                )
            )
        }
        return result
    }

    private func applyWindowWorkspace(minimize: [String], restore: [String], raise: String?) -> Bool {
        guard edgeIsRunning else { return false }

        func guarded(_ statements: [String]) -> String {
            statements.map { statement in
                """
                try
                  \(statement)
                end try
                """
            }.joined(separator: "\n")
        }

        let minimizeLines = guarded(minimize.map {
            "set minimized of window id \"\(Self.escapeAppleScript($0))\" to true"
        })
        let restoreLines = guarded(restore.map {
            "set minimized of window id \"\(Self.escapeAppleScript($0))\" to false"
        })
        let raiseLines: String
        if let raise {
            raiseLines = guarded([
                "set index of window id \"\(Self.escapeAppleScript(raise))\" to 1"
            ])
        } else {
            raiseLines = ""
        }

        let source = """
        tell application "Microsoft Edge"
          activate
          \(minimizeLines)
          \(restoreLines)
          \(raiseLines)
          return "ok"
        end tell
        """
        return (runAppleScript(source) ?? "") == "ok"
    }

    private static func appleScriptBool(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "true" || value == "yes"
    }

    private static func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
        let pending = PendingSpawn(
            token: UUID(),
            directoryName: profile.directoryName,
            excluding: existingIDs
        )
        pendingSpawn = pending
        activeProfileDirectory = profile.directoryName

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
            pendingSpawn = nil
            return
        }

        scheduleWindowBinding(profile: profile, pending: pending, attempts: 30)
    }

    private func scheduleWindowBinding(profile: EdgeProfile, pending: PendingSpawn, attempts: Int) {
        guard attempts > 0 else {
            if pendingSpawn?.token == pending.token {
                pendingSpawn = nil
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.edgeIsRunning else { return }
            guard self.pendingSpawn?.token == pending.token else { return }
            let windows = self.listScriptedWindows()
            self.rematchFromPlacements(profiles: ProfileStore.shared.profiles, windows: windows)

            let fresh = windows.filter { !pending.excluding.contains($0.id) }
            let arrived = fresh.filter { self.windowBindings[$0.id] == profile.directoryName }
            let unboundFresh = fresh.filter { self.windowBindings[$0.id] == nil }

            // A single new window belongs to this spawn. Cold start restores many windows;
            // those stay attributed by geometry instead of being claimed in bulk.
            if fresh.count == 1, let only = fresh.first {
                self.bind(windowID: only.id, to: profile.directoryName)
                self.pendingSpawn = nil
                _ = self.showWorkspace(for: profile, preferredID: only.id)
                return
            }

            if !arrived.isEmpty && unboundFresh.isEmpty {
                self.pendingSpawn = nil
                let raiseID = arrived.min(by: { $0.index < $1.index })?.id
                _ = self.showWorkspace(for: profile, preferredID: raiseID)
                return
            }

            if attempts == 1 {
                self.pendingSpawn = nil
                if windows.contains(where: { self.windowBindings[$0.id] == profile.directoryName }) {
                    _ = self.showWorkspace(for: profile)
                }
                return
            }

            self.scheduleWindowBinding(profile: profile, pending: pending, attempts: attempts - 1)
        }
    }

    // MARK: - Bindings

    private func bind(windowID: String, to directoryName: String) {
        if let previous = windowBindings[windowID], previous != directoryName,
           lastWindowByProfile[previous] == windowID {
            lastWindowByProfile[previous] = windowBindings.first(where: {
                $0.key != windowID && $0.value == previous
            })?.key
        }
        windowBindings[windowID] = directoryName
        lastWindowByProfile[directoryName] = windowID
        persistBindings()
    }

    private func persistBindings() {
        UserDefaults.standard.set(windowBindings, forKey: PreferencesKeys.windowBindings)
        UserDefaults.standard.set(lastWindowByProfile, forKey: PreferencesKeys.lastWindowByProfile)
        UserDefaults.standard.set(Array(manualWindowIDs), forKey: PreferencesKeys.manualWindowIDs)
        UserDefaults.standard.set(Array(workspaceHiddenIDs), forKey: PreferencesKeys.workspaceHiddenWindowIDs)
    }

    private func loadPersistedBindings() {
        if let raw = UserDefaults.standard.dictionary(forKey: PreferencesKeys.windowBindings) as? [String: String] {
            windowBindings = raw
        }
        if let raw = UserDefaults.standard.dictionary(forKey: PreferencesKeys.lastWindowByProfile) as? [String: String] {
            lastWindowByProfile = raw
        }
        if let raw = UserDefaults.standard.array(forKey: PreferencesKeys.manualWindowIDs) as? [String] {
            manualWindowIDs = Set(raw)
        }
        if let raw = UserDefaults.standard.array(forKey: PreferencesKeys.workspaceHiddenWindowIDs) as? [String] {
            workspaceHiddenIDs = Set(raw)
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
