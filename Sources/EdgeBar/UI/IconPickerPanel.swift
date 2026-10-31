import AppKit
import SwiftUI

/// Grid of profile pictures, shown beside the sidebar.
final class IconPickerPanel: NSPanel {
    private var resignObserver: NSObjectProtocol?
    var onDismiss: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 332, height: 360),
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
        isMovableByWindowBackground = false
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

    func present(near anchor: NSPoint) {
        let size = NSSize(width: 332, height: 368)
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        var origin = NSPoint(x: anchor.x, y: anchor.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(NSRect(origin: origin, size: size), display: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}

struct IconPickerView: View {
    let profileName: String
    let selectedID: String
    let onSelect: (ProfileIcon) -> Void
    let onCancel: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6)

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 12) {
                Text(profileName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(ProfileIcon.catalog) { icon in
                        Button {
                            onSelect(icon)
                        } label: {
                            ProfileIconGlyph(icon: icon, size: 40)
                                .overlay(
                                    Circle()
                                        .stroke(icon.id == selectedID ? Color.accentColor : Color.white.opacity(0.12), lineWidth: icon.id == selectedID ? 2.5 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(icon.symbol)
                    }
                }
            }
            .padding(14)
        }
        .onExitCommand(perform: onCancel)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ProfileIconGlyph: View {
    let icon: ProfileIcon
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(icon.color)
            Image(systemName: icon.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .symbolRenderingMode(.monochrome)
        }
        .frame(width: size, height: size)
    }
}
