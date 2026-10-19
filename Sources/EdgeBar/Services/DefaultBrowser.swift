import AppKit
import CoreServices
import Foundation

/// Queries and claims the system default HTTP/HTTPS handler via Launch Services.
enum DefaultBrowser {
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.local.EdgeBar"
    }

    /// True when EdgeBar is the registered handler for both `http` and `https`.
    static var isDefault: Bool {
        isHandler(for: "http") && isHandler(for: "https")
    }

    static func isHandler(for scheme: String) -> Bool {
        guard let probe = URL(string: "\(scheme)://edgebar.local/probe"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let id = Bundle(url: appURL)?.bundleIdentifier
        else { return false }
        return id.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
    }

    /// Asks Launch Services to make EdgeBar the default handler for `http` and `https`.
    /// macOS may show a confirmation dialog; the change is not guaranteed until the user accepts.
    @discardableResult
    static func setAsDefault() -> Bool {
        let id = bundleIdentifier as CFString
        let httpStatus = LSSetDefaultHandlerForURLScheme("http" as CFString, id)
        let httpsStatus = LSSetDefaultHandlerForURLScheme("https" as CFString, id)
        return httpStatus == noErr && httpsStatus == noErr
    }
}
