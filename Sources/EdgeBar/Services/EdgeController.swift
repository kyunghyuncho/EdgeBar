import AppKit
import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Launches Edge profiles via the Mach-O binary and focuses existing windows via Accessibility.
@MainActor
final class EdgeController: ObservableObject {
    static let shared = EdgeController()

    static let edgeBundleID = "com.microsoft.edgemac"
    static let edgeBinaryPath = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"

    /// In-memory map of CGWindowID → profile directory name.
    private var windowBindings: [CGWindowID: String] = [:]
    /// Most recently focused/raised window per profile directory.
    private var lastWindowByProfile: [String: CGWindowID] = [:]
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

        if !forceNewWindow, let window = findWindow(for: profile) {
            raise(window: window, profile: profile)
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
        guard let edgeApp = edgeRunningApp() else { return }
        let appElement = AXUIElementCreateApplication(edgeApp.processIdentifier)
        guard let focused = copyAXElement(appElement, kAXFocusedWindowAttribute),
              let windowID = windowID(of: focused)
        else { return }
        bind(windowID: windowID, to: profile.directoryName)
        raise(window: focused, profile: profile)
    }

    func refreshActiveProfile(from profiles: [EdgeProfile]) {
        guard let edgeApp = edgeRunningApp(), edgeApp.isActive else {
            activeProfileDirectory = nil
            return
        }
        let appElement = AXUIElementCreateApplication(edgeApp.processIdentifier)
        guard let focused = copyAXElement(appElement, kAXFocusedWindowAttribute) else {
            activeProfileDirectory = nil
            return
        }

        pruneStaleBindings()

        if let id = windowID(of: focused), let dir = windowBindings[id] {
            lastWindowByProfile[dir] = id
            activeProfileDirectory = dir
            persistBindings()
            return
        }

        if let match = identifyProfile(of: focused, profiles: profiles) {
            if let id = windowID(of: focused) {
                bind(windowID: id, to: match.directoryName)
            }
            activeProfileDirectory = match.directoryName
            return
        }

        inferMissingBindings(using: ProfileStore.shared)
        if let id = windowID(of: focused), let dir = windowBindings[id] {
            lastWindowByProfile[dir] = id
            activeProfileDirectory = dir
            persistBindings()
            return
        }
        activeProfileDirectory = nil
    }

    // MARK: - Launch

    private func spawn(profile: EdgeProfile, url: String?) {
        let edgeBinary = URL(fileURLWithPath: Self.edgeBinaryPath)
        guard FileManager.default.isExecutableFile(atPath: edgeBinary.path) else { return }

        let existingIDs = Set(enumerateEdgeWindows().compactMap { windowID(of: $0) })

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

        // Bind newly created window within ~2s.
        scheduleWindowBinding(profile: profile, excluding: existingIDs, attempts: 20)
        activeProfileDirectory = profile.directoryName
    }

    private func scheduleWindowBinding(profile: EdgeProfile, excluding: Set<CGWindowID>, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let windows = self.enumerateEdgeWindows()
            for window in windows {
                guard let id = self.windowID(of: window), !excluding.contains(id) else { continue }
                // Prefer title / chrome match; otherwise bind the newest unbound window.
                if self.identifyProfile(of: window, profiles: [profile]) != nil
                    || self.windowBindings[id] == nil {
                    self.bind(windowID: id, to: profile.directoryName)
                    self.raise(window: window, profile: profile)
                    return
                }
            }
            self.scheduleWindowBinding(profile: profile, excluding: excluding, attempts: attempts - 1)
        }
    }

    // MARK: - Window matching / raise

    /// Prefer the most recently focused window for this profile; otherwise the frontmost match.
    private func findWindow(for profile: EdgeProfile) -> AXUIElement? {
        pruneStaleBindings()
        inferMissingBindings(using: ProfileStore.shared)

        let windows = enumerateEdgeWindows()
        guard !windows.isEmpty else { return nil }

        var byID: [CGWindowID: AXUIElement] = [:]
        var matches: [AXUIElement] = []

        for window in windows {
            guard let id = windowID(of: window) else { continue }
            byID[id] = window

            if windowBindings[id] == profile.directoryName {
                matches.append(window)
                continue
            }
            if identifyProfile(of: window, profiles: [profile]) != nil {
                bind(windowID: id, to: profile.directoryName)
                matches.append(window)
            }
        }

        guard !matches.isEmpty else { return nil }

        if let lastID = lastWindowByProfile[profile.directoryName],
           let last = byID[lastID],
           matches.contains(where: { windowID(of: $0) == lastID }) {
            return last
        }

        let frontToBack = frontToBackEdgeWindowIDs()
        let ranked = matches.sorted { lhs, rhs in
            let lid = windowID(of: lhs) ?? 0
            let rid = windowID(of: rhs) ?? 0
            let li = frontToBack.firstIndex(of: lid) ?? .max
            let ri = frontToBack.firstIndex(of: rid) ?? .max
            return li < ri
        }
        return ranked.first
    }

    /// Fill gaps when exactly one unbound browser window remains for one unbound active profile,
    /// and attribute the focused Edge window to Local State's `last_used` when unknown.
    private func inferMissingBindings(using store: ProfileStore) {
        let windows = enumerateEdgeWindows()
        guard !windows.isEmpty else { return }

        if let focusedApp = edgeRunningApp(), focusedApp.isActive {
            let appElement = AXUIElementCreateApplication(focusedApp.processIdentifier)
            if let focused = copyAXElement(appElement, kAXFocusedWindowAttribute),
               let id = windowID(of: focused),
               windowBindings[id] == nil,
               let lastUsed = store.lastUsedDirectory,
               store.profiles.contains(where: { $0.directoryName == lastUsed }) {
                bind(windowID: id, to: lastUsed)
            }
        }

        let activeDirs = Set(store.lastActiveDirectories.isEmpty
            ? store.profiles.map(\.directoryName)
            : store.lastActiveDirectories)
        let boundDirs = Set(windowBindings.values)
        let unboundDirs = activeDirs.subtracting(boundDirs)
        let unboundWindows = windows.compactMap { window -> CGWindowID? in
            guard let id = windowID(of: window), windowBindings[id] == nil else { return nil }
            return id
        }

        if unboundDirs.count == 1, unboundWindows.count == 1,
           let dir = unboundDirs.first, let id = unboundWindows.first {
            bind(windowID: id, to: dir)
        }
    }

    private func identifyProfile(of window: AXUIElement, profiles: [EdgeProfile]) -> EdgeProfile? {
        if let title = copyAttribute(window, kAXTitleAttribute) as? String {
            if let match = matchProfile(title: title, profiles: profiles) {
                return match
            }
        }
        // Edge often omits the profile from the window title; chrome controls may still expose it.
        return matchProfileInChrome(window, profiles: profiles)
    }

    /// Shallow scan for an accessibility label that exactly matches a known profile token.
    private func matchProfileInChrome(_ window: AXUIElement, profiles: [EdgeProfile]) -> EdgeProfile? {
        let tokens: [(String, EdgeProfile)] = profiles.flatMap { profile in
            profile.titleMatchTokens
                .filter { !$0.isEmpty }
                .map { ($0, profile) }
        }
        guard !tokens.isEmpty else { return nil }

        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 120, depth < 6 {
            visited += 1
            let title = (copyAttribute(element, kAXTitleAttribute) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = (copyAttribute(element, kAXDescriptionAttribute) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let help = (copyAttribute(element, "AXHelp") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            for candidate in [title, description, help] where !candidate.isEmpty {
                for (token, profile) in tokens {
                    if candidate.compare(token, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                        return profile
                    }
                }
            }

            if depth < 5 {
                for child in copyAXElementArray(element, kAXChildrenAttribute).reversed() {
                    stack.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    private func titleMatches(_ title: String, profile: EdgeProfile) -> Bool {
        let lower = title.lowercased()
        for token in profile.titleMatchTokens {
            let t = token.lowercased()
            guard !t.isEmpty else { continue }
            // Edge titles often look like: "Page - ProfileName - Microsoft Edge"
            if lower.contains(" - \(t) - microsoft edge")
                || lower.hasSuffix(" - \(t)")
                || lower.contains(" - \(t) - ")
                || lower == t {
                return true
            }
        }
        if let windowName = profile.windowName?.lowercased(), !windowName.isEmpty {
            if lower.contains(windowName) { return true }
        }
        return false
    }

    private func matchProfile(title: String, profiles: [EdgeProfile]) -> EdgeProfile? {
        // Prefer longer tokens to avoid ambiguous short-name collisions.
        let ranked = profiles.sorted {
            ($0.titleMatchTokens.map(\.count).max() ?? 0) > ($1.titleMatchTokens.map(\.count).max() ?? 0)
        }
        for profile in ranked {
            if titleMatches(title, profile: profile) {
                return profile
            }
        }
        return nil
    }

    private func raise(window: AXUIElement, profile: EdgeProfile) {
        guard let edgeApp = edgeRunningApp() else { return }
        edgeApp.activate(options: [.activateIgnoringOtherApps])
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let id = windowID(of: window) {
            bind(windowID: id, to: profile.directoryName)
        }
        activeProfileDirectory = profile.directoryName
    }

    private func enumerateEdgeWindows() -> [AXUIElement] {
        guard let edgeApp = edgeRunningApp() else { return [] }
        let appElement = AXUIElementCreateApplication(edgeApp.processIdentifier)
        return copyAXElementArray(appElement, kAXWindowsAttribute)
            .filter { isNormalBrowserWindow($0) }
    }

    private func isNormalBrowserWindow(_ window: AXUIElement) -> Bool {
        let role = copyAttribute(window, kAXRoleAttribute) as? String
        if role != nil && role != (kAXWindowRole as String) { return false }
        let subrole = copyAttribute(window, kAXSubroleAttribute) as? String
        if let subrole, subrole == (kAXDialogSubrole as String) || subrole == "AXSystemDialog" {
            return false
        }
        return true
    }

    private func frontToBackEdgeWindowIDs() -> [CGWindowID] {
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [CGWindowID] = []
        for entry in info {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  owner == "Microsoft Edge",
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            result.append(number)
        }
        return result
    }

    private func edgeRunningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.edgeBundleID
        }
    }

    private func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        let err = _AXUIElementGetWindow(element, &id)
        return err == .success ? id : nil
    }

    private func bind(windowID: CGWindowID, to directoryName: String) {
        windowBindings[windowID] = directoryName
        lastWindowByProfile[directoryName] = windowID
        persistBindings()
    }

    private func pruneStaleBindings() {
        let live = Set(enumerateEdgeWindows().compactMap { windowID(of: $0) })
        let before = windowBindings.count
        windowBindings = windowBindings.filter { live.contains($0.key) }
        lastWindowByProfile = lastWindowByProfile.filter { live.contains($0.value) }
        if windowBindings.count != before {
            persistBindings()
        }
    }

    private func persistBindings() {
        let bindings = Dictionary(uniqueKeysWithValues: windowBindings.map { (String($0.key), $0.value) })
        let last = Dictionary(uniqueKeysWithValues: lastWindowByProfile.map { ($0.key, String($0.value)) })
        UserDefaults.standard.set(bindings, forKey: PreferencesKeys.windowBindings)
        UserDefaults.standard.set(last, forKey: PreferencesKeys.lastWindowByProfile)
    }

    private func loadPersistedBindings() {
        if let raw = UserDefaults.standard.dictionary(forKey: PreferencesKeys.windowBindings) as? [String: String] {
            for (key, value) in raw {
                if let id = CGWindowID(key) {
                    windowBindings[id] = value
                }
            }
        }
        if let raw = UserDefaults.standard.dictionary(forKey: PreferencesKeys.lastWindowByProfile) as? [String: String] {
            for (dir, value) in raw {
                if let id = CGWindowID(value) {
                    lastWindowByProfile[dir] = id
                }
            }
        }
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    private func copyAXElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func copyAXElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return [] }
        let array = value as! CFArray
        var result: [AXUIElement] = []
        let count = CFArrayGetCount(array)
        for i in 0..<count {
            let ptr = CFArrayGetValueAtIndex(array, i)
            let window = unsafeBitCast(ptr, to: AXUIElement.self)
            result.append(window)
        }
        return result
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
