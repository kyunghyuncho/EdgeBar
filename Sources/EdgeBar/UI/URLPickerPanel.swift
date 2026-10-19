import AppKit
import SwiftUI

/// Activating floating panel that asks which Edge profile should open a URL.
final class URLPickerPanel: NSPanel {
    private var resignObserver: NSObjectProtocol?
    var onDismiss: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.onDismiss?()
        }
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
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

    func present(profileCount: Int, near mouse: NSPoint? = nil) {
        let width: CGFloat = 360
        // Match URLPickerView: outer padding + title + URL + spacings + footer,
        // plus per-row height (avatar + vertical padding) and inter-row spacing.
        let count = max(profileCount, 1)
        let chrome: CGFloat = 130
        let rowHeight: CGFloat = 56
        let rowSpacing: CGFloat = 4
        let ideal = chrome
            + CGFloat(count) * rowHeight
            + CGFloat(max(count - 1, 0)) * rowSpacing

        let anchor = mouse ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        // Prefer fitting all profiles; only scroll when taller than ~92% of the screen.
        let height = min(max(ideal, 180), max(visible.height * 0.92, 180))
        let size = NSSize(width: width, height: height)

        var origin = NSPoint(
            x: anchor.x - size.width / 2,
            y: anchor.y - size.height / 2
        )
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)

        setFrame(NSRect(origin: origin, size: size), display: true)
        alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
    }
}
