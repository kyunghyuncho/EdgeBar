import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var controller: EdgeController
    @ObservedObject var focus: FocusMonitor
    @ObservedObject var icons: ProfileIconStore
    var onPickIcon: (EdgeProfile) -> Void

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(spacing: SidebarMetrics.rowSpacing) {
                if store.profiles.isEmpty {
                    Text("—")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .help(store.lastError ?? "No Edge profiles found")
                        .frame(height: SidebarMetrics.rowHeight)
                } else {
                    ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                        ProfileButton(
                            profile: profile,
                            icon: icons.icon(for: profile.directoryName),
                            index: index,
                            isActive: controller.activeProfileDirectory == profile.directoryName,
                            onActivate: { forceNew in
                                controller.activate(profile: profile, forceNewWindow: forceNew)
                            },
                            onOpenURL: { url in
                                controller.open(url: url, in: profile)
                            },
                            onBindWindow: {
                                controller.bindFrontmostEdgeWindow(to: profile)
                            },
                            onOpenClipboard: {
                                controller.openClipboardURL(in: profile)
                            },
                            onPickIcon: {
                                onPickIcon(profile)
                            }
                        )
                    }
                }
            }
            .padding(.vertical, SidebarMetrics.verticalPadding)
            .padding(.horizontal, SidebarMetrics.horizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProfileButton: View {
    let profile: EdgeProfile
    let icon: ProfileIcon
    let index: Int
    let isActive: Bool
    let onActivate: (Bool) -> Void
    let onOpenURL: (String) -> Void
    let onBindWindow: () -> Void
    let onOpenClipboard: () -> Void
    let onPickIcon: () -> Void

    @State private var isTargeted = false

    var body: some View {
        Button {
            let flags = NSEvent.modifierFlags
            let forceNew = flags.contains(.shift) || flags.contains(.command)
            onActivate(forceNew)
        } label: {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileAvatar(icon: icon, size: SidebarMetrics.iconSize)
                        .overlay(
                            Circle()
                                .stroke(isActive ? Color.accentColor : Color.white.opacity(0.18), lineWidth: isActive ? 2 : 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

                    if index < 9 {
                        Text("\(index + 1)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .offset(x: 2, y: 2)
                    }
                }

                Text(profile.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SidebarMetrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onDrop(of: [.url, .text, .plainText], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .contextMenu {
            Button("Change Icon…") {
                onPickIcon()
            }
            Divider()
            Button("Bind Frontmost Edge Window to \(profile.displayName)") {
                onBindWindow()
            }
            Button("Open Clipboard URL in \(profile.displayName)") {
                onOpenClipboard()
            }
            Button("Copy --profile-directory CLI flag") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "--profile-directory=\(profile.directoryName)",
                    forType: .string
                )
            }
            Divider()
            Button("Open New Window") {
                onActivate(true)
            }
        }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                // Middle-click is handled via NSEvent monitor in AppDelegate when needed;
                // shift/command already covered in the button action.
            }
        )
    }

    private var rowFill: Color {
        if isTargeted { return Color.accentColor.opacity(0.28) }
        if isActive { return Color.white.opacity(0.08) }
        return Color.clear
    }

    private var helpText: String {
        var lines = [profile.displayName]
        if let userName = profile.userName {
            lines.append(userName)
        }
        if index < 9 {
            lines.append("⌃⌥\(index + 1)")
        }
        return lines.joined(separator: "\n")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    let urlString: String?
                    if let url = item as? URL {
                        urlString = url.absoluteString
                    } else if let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urlString = url.absoluteString
                    } else if let str = item as? String {
                        urlString = EdgeController.normalizeURL(str)
                    } else {
                        urlString = nil
                    }
                    if let urlString {
                        DispatchQueue.main.async {
                            onOpenURL(urlString)
                        }
                    }
                }
                return true
            }
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string,
                          let url = EdgeController.normalizeURL(string)
                    else { return }
                    DispatchQueue.main.async {
                        onOpenURL(url)
                    }
                }
                return true
            }
        }
        return false
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
