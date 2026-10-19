import AppKit
import SwiftUI

/// Shared avatar used by the sidebar strip and the URL profile picker.
struct ProfileAvatar: View {
    let profile: EdgeProfile
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let path = profile.avatarPath,
               let image = NSImage(contentsOf: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(nsColor: profile.highlightColor))
                    Text(profile.monogram)
                        .font(.system(size: size * 0.33, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
