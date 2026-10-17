import AppKit
import Foundation

/// Metadata for a single Microsoft Edge profile directory.
struct EdgeProfile: Identifiable, Hashable, Sendable {
    var id: String { directoryName }

    /// Internal profile directory key (e.g. `"Default"`, `"Profile 1"`).
    let directoryName: String
    /// User-assigned display name.
    let name: String
    /// Signed-in email, if any.
    let userName: String?
    /// Optional shortcut label from Local State.
    let shortcutName: String?
    /// ARGB signed integer highlight color from Local State.
    let highlightColorARGB: Int?
    /// Resolved avatar image path, if present on disk.
    let avatarPath: URL?
    /// Custom window name from Preferences (`browser.window_name`), if set.
    let windowName: String?

    var displayName: String { name.isEmpty ? directoryName : name }

    var highlightColor: NSColor {
        guard let argb = highlightColorARGB else {
            return NSColor.systemBlue
        }
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        // Edge often stores opaque colors with alpha 0 in the high byte; treat that as opaque.
        let alpha = a > 0 ? a : 1.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    var monogram: String {
        let parts = displayName.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }

    /// Substrings that identify this profile in Edge window titles.
    var titleMatchTokens: [String] {
        var tokens: [String] = [displayName]
        if let windowName, !windowName.isEmpty {
            tokens.append(windowName)
        }
        if let shortcutName, !shortcutName.isEmpty {
            tokens.append(shortcutName)
        }
        return tokens
    }
}
