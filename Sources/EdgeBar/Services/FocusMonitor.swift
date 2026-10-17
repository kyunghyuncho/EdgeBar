import AppKit
import Combine
import Foundation

enum VisibilityMode: String, CaseIterable {
    case edgeAware = "edgeAware"
    case alwaysVisible = "alwaysVisible"

    var menuTitle: String {
        switch self {
        case .edgeAware: return "Show Only When Edge is Active"
        case .alwaysVisible: return "Always Visible"
        }
    }
}

enum DockSide: String, CaseIterable {
    case left
    case right

    var menuTitle: String {
        switch self {
        case .left: return "Dock Left"
        case .right: return "Dock Right"
        }
    }
}

/// Tracks frontmost application and mouse proximity for sidebar visibility.
@MainActor
final class FocusMonitor: ObservableObject {
    @Published private(set) var edgeIsFrontmost: Bool = false
    @Published private(set) var mouseNearEdge: Bool = false
    @Published var visibilityMode: VisibilityMode {
        didSet {
            UserDefaults.standard.set(visibilityMode.rawValue, forKey: PreferencesKeys.visibilityMode)
            recomputeDesiredVisibility()
        }
    }
    @Published var dockSide: DockSide {
        didSet {
            UserDefaults.standard.set(dockSide.rawValue, forKey: PreferencesKeys.dockSide)
        }
    }
    @Published private(set) var shouldShowSidebar: Bool = true

    private var mouseTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    static let shared = FocusMonitor()

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: PreferencesKeys.visibilityMode),
           let mode = VisibilityMode(rawValue: raw) {
            visibilityMode = mode
        } else {
            visibilityMode = .edgeAware
        }
        if let raw = defaults.string(forKey: PreferencesKeys.dockSide),
           let side = DockSide(rawValue: raw) {
            dockSide = side
        } else {
            dockSide = .left
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        updateFrontmost()
        startMousePolling()
        recomputeDesiredVisibility()
    }

    func shutdown() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func frontAppChanged(_ note: Notification) {
        updateFrontmost()
        EdgeController.shared.refreshActiveProfile(from: ProfileStore.shared.profiles)
    }

    private func updateFrontmost() {
        let front = NSWorkspace.shared.frontmostApplication
        edgeIsFrontmost = front?.bundleIdentifier == EdgeController.edgeBundleID
            || front?.bundleIdentifier == "com.local.EdgeBar"
        recomputeDesiredVisibility()
    }

    private func startMousePolling() {
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollMouse()
            }
        }
    }

    private func pollMouse() {
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        let frame = screen.frame
        let threshold: CGFloat = 4
        let near: Bool
        switch dockSide {
        case .left:
            near = mouse.x <= frame.minX + threshold
        case .right:
            near = mouse.x >= frame.maxX - threshold
        }
        if near != mouseNearEdge {
            mouseNearEdge = near
            recomputeDesiredVisibility()
        }
    }

    private func recomputeDesiredVisibility() {
        switch visibilityMode {
        case .alwaysVisible:
            shouldShowSidebar = true
        case .edgeAware:
            shouldShowSidebar = edgeIsFrontmost || mouseNearEdge
        }
    }
}
