import AppKit
import SwiftUI

/// Non-activating floating panel that hosts the profile sidebar.
final class FloatingSidebarPanel: NSPanel {
    private var moveObserver: NSObjectProtocol?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.persistOrigin()
        }
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func host<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        if animated {
            animator().alphaValue = visible ? 1.0 : 0.0
        } else {
            alphaValue = visible ? 1.0 : 0.0
        }
        if visible {
            orderFrontRegardless()
        }
        // Keep the panel ordered when faded so edge-hover can restore it quickly.
    }

    func layoutForProfiles(count: Int, dockSide: DockSide, screen: NSScreen?) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = 56
        let rowHeight: CGFloat = 48
        let padding: CGFloat = 12
        let height = max(CGFloat(count) * rowHeight + padding * 2, 72)

        let defaults = UserDefaults.standard
        let hasSaved = defaults.object(forKey: PreferencesKeys.panelOriginX) != nil
        var origin: NSPoint
        if hasSaved {
            origin = NSPoint(
                x: defaults.double(forKey: PreferencesKeys.panelOriginX),
                y: defaults.double(forKey: PreferencesKeys.panelOriginY)
            )
        } else {
            let x: CGFloat
            switch dockSide {
            case .left:
                x = visible.minX + 4
            case .right:
                x = visible.maxX - width - 4
            }
            let y = visible.midY - height / 2
            origin = NSPoint(x: x, y: y)
        }

        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    func snapToDock(_ side: DockSide, screen: NSScreen?) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        var frame = self.frame
        switch side {
        case .left:
            frame.origin.x = visible.minX + 4
        case .right:
            frame.origin.x = visible.maxX - frame.width - 4
        }
        setFrame(frame, display: true, animate: true)
        persistOrigin()
    }

    private func persistOrigin() {
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.origin.x), forKey: PreferencesKeys.panelOriginX)
        defaults.set(Double(frame.origin.y), forKey: PreferencesKeys.panelOriginY)
    }
}
