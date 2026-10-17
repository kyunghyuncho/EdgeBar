import Foundation
import Combine

/// Parses and watches Microsoft Edge's `Local State` for profile metadata.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [EdgeProfile] = []
    @Published private(set) var lastError: String?

    private let edgeSupportURL: URL
    private let localStateURL: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var directoryFD: CInt = -1
    private var reloadWorkItem: DispatchWorkItem?

    static let shared = ProfileStore()

    init(edgeSupportURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = edgeSupportURL ?? home
            .appendingPathComponent("Library/Application Support/Microsoft Edge", isDirectory: true)
        self.edgeSupportURL = support
        self.localStateURL = support.appendingPathComponent("Local State", isDirectory: false)
        reload()
        startWatching()
    }

    func reload() {
        do {
            let loaded = try Self.loadProfiles(from: localStateURL, edgeSupportURL: edgeSupportURL)
            profiles = Self.sortProfiles(loaded)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if profiles.isEmpty {
                profiles = []
            }
        }
    }

    // MARK: - Parsing

    nonisolated static func loadProfiles(from localStateURL: URL, edgeSupportURL: URL) throws -> [EdgeProfile] {
        guard FileManager.default.fileExists(atPath: localStateURL.path) else {
            throw ProfileStoreError.localStateMissing(localStateURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: localStateURL, options: [.mappedIfSafe])
        } catch {
            throw ProfileStoreError.readFailed(error.localizedDescription)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileRoot = root["profile"] as? [String: Any],
              let infoCache = profileRoot["info_cache"] as? [String: Any]
        else {
            throw ProfileStoreError.malformedLocalState
        }

        var result: [EdgeProfile] = []
        for (directoryName, value) in infoCache {
            guard let info = value as? [String: Any] else { continue }
            let name = (info["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? directoryName
            let userName = info["user_name"] as? String
            let shortcutName = info["shortcut_name"] as? String
            let highlight = info["profile_highlight_color"] as? Int
                ?? (info["profile_highlight_color"] as? NSNumber)?.intValue

            let profileDir = edgeSupportURL.appendingPathComponent(directoryName, isDirectory: true)
            let avatarPath = resolveAvatar(
                profileDir: profileDir,
                gaiaFileName: info["gaia_picture_file_name"] as? String
            )
            let windowName = readWindowName(profileDir: profileDir)

            result.append(
                EdgeProfile(
                    directoryName: directoryName,
                    name: name.isEmpty ? directoryName : name,
                    userName: userName?.isEmpty == true ? nil : userName,
                    shortcutName: shortcutName?.isEmpty == true ? nil : shortcutName,
                    highlightColorARGB: highlight,
                    avatarPath: avatarPath,
                    windowName: windowName
                )
            )
        }
        return result
    }

    nonisolated private static func resolveAvatar(profileDir: URL, gaiaFileName: String?) -> URL? {
        let candidates: [URL] = [
            profileDir.appendingPathComponent("Edge Profile Picture.png"),
            profileDir.appendingPathComponent("Google Profile Picture.png"),
            gaiaFileName.map { profileDir.appendingPathComponent($0) }
        ].compactMap { $0 }

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    nonisolated private static func readWindowName(profileDir: URL) -> String? {
        let prefsURL = profileDir.appendingPathComponent("Preferences")
        guard FileManager.default.fileExists(atPath: prefsURL.path),
              let data = try? Data(contentsOf: prefsURL, options: [.mappedIfSafe]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let browser = root["browser"] as? [String: Any],
              let windowName = browser["window_name"] as? String,
              !windowName.isEmpty
        else {
            return nil
        }
        return windowName
    }

    nonisolated static func sortProfiles(_ profiles: [EdgeProfile]) -> [EdgeProfile] {
        let order = UserDefaults.standard.stringArray(forKey: PreferencesKeys.profileOrder) ?? []
        return profiles.sorted { lhs, rhs in
            if lhs.directoryName == "Default" { return true }
            if rhs.directoryName == "Default" { return false }
            let li = order.firstIndex(of: lhs.directoryName) ?? Int.max
            let ri = order.firstIndex(of: rhs.directoryName) ?? Int.max
            if li != ri { return li < ri }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: - File watcher

    private func startWatching() {
        stopWatching()
        let dirPath = edgeSupportURL.path
        guard FileManager.default.fileExists(atPath: dirPath) else { return }

        directoryFD = open(dirPath, O_EVTONLY)
        guard directoryFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.directoryFD, fd >= 0 {
                close(fd)
                self?.directoryFD = -1
            }
        }
        watcher = source
        source.resume()
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }
}

enum ProfileStoreError: LocalizedError {
    case localStateMissing(String)
    case readFailed(String)
    case malformedLocalState

    var errorDescription: String? {
        switch self {
        case .localStateMissing(let path):
            return "Microsoft Edge Local State not found at \(path)."
        case .readFailed(let message):
            return "Failed to read Local State: \(message)"
        case .malformedLocalState:
            return "Local State JSON is missing profile.info_cache."
        }
    }
}

enum PreferencesKeys {
    static let profileOrder = "edgebar.profileOrder"
    static let dockSide = "edgebar.dockSide"
    static let visibilityMode = "edgebar.visibilityMode"
    static let panelOriginX = "edgebar.panelOriginX"
    static let panelOriginY = "edgebar.panelOriginY"
    static let pendingURLProfile = "edgebar.pendingURLProfile"
}
