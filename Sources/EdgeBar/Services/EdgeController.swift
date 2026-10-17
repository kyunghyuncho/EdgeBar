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
    @Published private(set) var activeProfileDirectory: String?

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
            raise(window: window)
            activeProfileDirectory = profile.directoryName
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
        windowBindings[windowID] = profile.directoryName
        activeProfileDirectory = profile.directoryName
        raise(window: focused)
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
        if let id = windowID(of: focused), let dir = windowBindings[id] {
            activeProfileDirectory = dir
            return
        }
        if let title = copyAttribute(focused, kAXTitleAttribute) as? String,
           let match = matchProfile(title: title, profiles: profiles) {
            if let id = windowID(of: focused) {
                windowBindings[id] = match.directoryName
            }
            activeProfileDirectory = match.directoryName
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

        // Bind newly created window within ~800ms.
        scheduleWindowBinding(profile: profile, excluding: existingIDs, attempts: 8)
        activeProfileDirectory = profile.directoryName
    }

    private func scheduleWindowBinding(profile: EdgeProfile, excluding: Set<CGWindowID>, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let windows = self.enumerateEdgeWindows()
            for window in windows {
                guard let id = self.windowID(of: window), !excluding.contains(id) else { continue }
                // Prefer title match; otherwise bind the newest unbound window.
                if let title = self.copyAttribute(window, kAXTitleAttribute) as? String,
                   self.titleMatches(title, profile: profile) {
                    self.windowBindings[id] = profile.directoryName
                    return
                }
                if self.windowBindings[id] == nil {
                    self.windowBindings[id] = profile.directoryName
                    return
                }
            }
            self.scheduleWindowBinding(profile: profile, excluding: excluding, attempts: attempts - 1)
        }
    }

    // MARK: - Window matching / raise

    private func findWindow(for profile: EdgeProfile) -> AXUIElement? {
        let windows = enumerateEdgeWindows()

        for window in windows {
            if let id = windowID(of: window), windowBindings[id] == profile.directoryName {
                return window
            }
        }

        for window in windows {
            guard let title = copyAttribute(window, kAXTitleAttribute) as? String else { continue }
            if titleMatches(title, profile: profile) {
                if let id = windowID(of: window) {
                    windowBindings[id] = profile.directoryName
                }
                return window
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
                || lower.contains(" - \(t) - ") {
                return true
            }
        }
        if let windowName = profile.windowName?.lowercased(), !windowName.isEmpty {
            if lower.contains(windowName) { return true }
        }
        return false
    }

    private func matchProfile(title: String, profiles: [EdgeProfile]) -> EdgeProfile? {
        for profile in profiles {
            if titleMatches(title, profile: profile) {
                return profile
            }
        }
        return nil
    }

    private func raise(window: AXUIElement) {
        guard let edgeApp = edgeRunningApp() else { return }
        edgeApp.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func enumerateEdgeWindows() -> [AXUIElement] {
        guard let edgeApp = edgeRunningApp() else { return [] }
        let appElement = AXUIElementCreateApplication(edgeApp.processIdentifier)
        return copyAXElementArray(appElement, kAXWindowsAttribute)
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
