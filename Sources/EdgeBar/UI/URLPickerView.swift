import AppKit
import SwiftUI

struct URLPickerView: View {
    let urlString: String
    let profiles: [EdgeProfile]
    let onSelect: (EdgeProfile) -> Void
    let onCancel: () -> Void

    private var displayURL: String {
        let limit = 72
        guard urlString.count > limit else { return urlString }
        let head = urlString.prefix(limit / 2 - 1)
        let tail = urlString.suffix(limit / 2 - 2)
        return "\(head)…\(tail)"
    }

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 12) {
                Text("Open in profile")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(displayURL)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(urlString)

                if profiles.isEmpty {
                    Text("No Edge profiles found")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                                Button {
                                    onSelect(profile)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack(alignment: .bottomTrailing) {
                                            ProfileAvatar(profile: profile, size: 36)
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                                )

                                            if index < 9 {
                                                Text("\(index + 1)")
                                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                                    .foregroundStyle(.white)
                                                    .padding(3)
                                                    .background(Circle().fill(Color.black.opacity(0.55)))
                                                    .offset(x: 2, y: 2)
                                            }
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(profile.displayName)
                                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            if let userName = profile.userName, !userName.isEmpty {
                                                Text(userName)
                                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }

                                        Spacer(minLength: 0)

                                        if index < 9 {
                                            Text("\(index + 1)")
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                                .foregroundStyle(.tertiary)
                                                .frame(width: 18, height: 18)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                        .fill(Color.primary.opacity(0.08))
                                                )
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Text("Esc to cancel")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
