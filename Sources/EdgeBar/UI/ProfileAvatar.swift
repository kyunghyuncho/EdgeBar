import AppKit
import SwiftUI

/// Shared picture used by the sidebar strip and the URL profile picker.
struct ProfileAvatar: View {
    var icon: ProfileIcon
    var size: CGFloat = 36

    var body: some View {
        ProfileIconGlyph(icon: icon, size: size)
            .clipShape(Circle())
    }
}

enum SidebarMetrics {
    static let width: CGFloat = 208
    static let iconSize: CGFloat = 34
    static let rowHeight: CGFloat = 46
    static let rowSpacing: CGFloat = 4
    static let verticalPadding: CGFloat = 8
    static let horizontalPadding: CGFloat = 8

    static func height(profileCount: Int) -> CGFloat {
        let count = max(profileCount, 1)
        return verticalPadding * 2
            + CGFloat(count) * rowHeight
            + CGFloat(max(count - 1, 0)) * rowSpacing
    }

    /// Index of the row under a point measured from the panel's bottom-left, in screen coordinates' Y.
    static func index(localY: CGFloat, panelHeight: CGFloat, count: Int) -> Int? {
        let fromTop = panelHeight - localY - verticalPadding
        guard fromTop >= 0, count > 0 else { return nil }
        let stride = rowHeight + rowSpacing
        let index = Int(fromTop / stride)
        let within = fromTop - CGFloat(index) * stride
        guard index >= 0, index < count, within <= rowHeight else { return nil }
        return index
    }
}
