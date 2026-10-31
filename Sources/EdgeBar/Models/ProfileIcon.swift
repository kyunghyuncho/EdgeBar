import SwiftUI

/// A selectable profile picture, in the spirit of the macOS user-picture grid.
struct ProfileIcon: Identifiable, Hashable {
    let symbol: String
    let red: Double
    let green: Double
    let blue: Double

    var id: String { symbol }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    static func == (lhs: ProfileIcon, rhs: ProfileIcon) -> Bool {
        lhs.symbol == rhs.symbol
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(symbol)
    }

    static let catalog: [ProfileIcon] = [
        ProfileIcon(symbol: "hare.fill", red: 0.96, green: 0.55, blue: 0.18),
        ProfileIcon(symbol: "tortoise.fill", red: 0.22, green: 0.62, blue: 0.36),
        ProfileIcon(symbol: "dog.fill", red: 0.62, green: 0.42, blue: 0.24),
        ProfileIcon(symbol: "cat.fill", red: 0.55, green: 0.36, blue: 0.78),
        ProfileIcon(symbol: "bird.fill", red: 0.20, green: 0.52, blue: 0.90),
        ProfileIcon(symbol: "fish.fill", red: 0.12, green: 0.62, blue: 0.70),
        ProfileIcon(symbol: "ladybug.fill", red: 0.86, green: 0.22, blue: 0.24),
        ProfileIcon(symbol: "pawprint.fill", red: 0.86, green: 0.42, blue: 0.58),
        ProfileIcon(symbol: "leaf.fill", red: 0.28, green: 0.68, blue: 0.32),
        ProfileIcon(symbol: "flame.fill", red: 0.92, green: 0.38, blue: 0.16),
        ProfileIcon(symbol: "bolt.fill", red: 0.92, green: 0.72, blue: 0.12),
        ProfileIcon(symbol: "star.fill", red: 0.95, green: 0.62, blue: 0.10),
        ProfileIcon(symbol: "moon.stars.fill", red: 0.32, green: 0.36, blue: 0.78),
        ProfileIcon(symbol: "sun.max.fill", red: 0.95, green: 0.58, blue: 0.12),
        ProfileIcon(symbol: "book.fill", red: 0.22, green: 0.42, blue: 0.82),
        ProfileIcon(symbol: "graduationcap.fill", red: 0.36, green: 0.28, blue: 0.72),
        ProfileIcon(symbol: "briefcase.fill", red: 0.48, green: 0.36, blue: 0.24),
        ProfileIcon(symbol: "heart.fill", red: 0.88, green: 0.24, blue: 0.38),
        ProfileIcon(symbol: "music.note", red: 0.78, green: 0.22, blue: 0.48),
        ProfileIcon(symbol: "paintbrush.fill", red: 0.58, green: 0.32, blue: 0.86),
        ProfileIcon(symbol: "camera.fill", red: 0.28, green: 0.40, blue: 0.52),
        ProfileIcon(symbol: "airplane", red: 0.18, green: 0.48, blue: 0.82),
        ProfileIcon(symbol: "car.fill", red: 0.78, green: 0.22, blue: 0.22),
        ProfileIcon(symbol: "bicycle", red: 0.16, green: 0.58, blue: 0.48),
        ProfileIcon(symbol: "cup.and.saucer.fill", red: 0.55, green: 0.36, blue: 0.22),
        ProfileIcon(symbol: "fork.knife", red: 0.82, green: 0.42, blue: 0.18),
        ProfileIcon(symbol: "gamecontroller.fill", red: 0.42, green: 0.28, blue: 0.82),
        ProfileIcon(symbol: "globe.americas.fill", red: 0.16, green: 0.50, blue: 0.72),
        ProfileIcon(symbol: "lightbulb.fill", red: 0.90, green: 0.70, blue: 0.16),
        ProfileIcon(symbol: "hammer.fill", red: 0.42, green: 0.44, blue: 0.48),
        ProfileIcon(symbol: "paperplane.fill", red: 0.20, green: 0.56, blue: 0.92),
        ProfileIcon(symbol: "headphones", red: 0.36, green: 0.32, blue: 0.62),
        ProfileIcon(symbol: "gift.fill", red: 0.84, green: 0.28, blue: 0.32),
        ProfileIcon(symbol: "key.fill", red: 0.78, green: 0.62, blue: 0.18),
        ProfileIcon(symbol: "cloud.fill", red: 0.35, green: 0.62, blue: 0.82),
        ProfileIcon(symbol: "snowflake", red: 0.28, green: 0.68, blue: 0.86),
    ]

    static let byID: [String: ProfileIcon] = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
}
