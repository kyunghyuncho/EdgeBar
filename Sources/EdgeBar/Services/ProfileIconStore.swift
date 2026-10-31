import Foundation

/// Remembers which picture each Edge profile uses. A profile with no choice receives a random unused picture.
@MainActor
final class ProfileIconStore: ObservableObject {
    static let shared = ProfileIconStore()

    @Published private var assignments: [String: String] = [:]

    init() {
        if let raw = UserDefaults.standard.dictionary(forKey: PreferencesKeys.profileIcons) as? [String: String] {
            assignments = raw
        }
    }

    func icon(for directoryName: String) -> ProfileIcon {
        if let id = assignments[directoryName], let icon = ProfileIcon.byID[id] {
            return icon
        }
        return ProfileIcon.catalog[0]
    }

    func ensureIcons(for directoryNames: [String]) {
        var used = Set(assignments.values.filter { ProfileIcon.byID[$0] != nil })
        var changed = false
        for directory in directoryNames {
            if let id = assignments[directory], ProfileIcon.byID[id] != nil {
                continue
            }
            let available = ProfileIcon.catalog.filter { !used.contains($0.id) }
            let pool = available.isEmpty ? ProfileIcon.catalog : available
            guard let pick = pool.randomElement() else { continue }
            assignments[directory] = pick.id
            used.insert(pick.id)
            changed = true
        }
        if changed {
            persist()
        }
    }

    func setIcon(_ icon: ProfileIcon, for directoryName: String) {
        assignments[directoryName] = icon.id
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(assignments, forKey: PreferencesKeys.profileIcons)
    }
}
