import AppKit
import Carbon
import Combine
import SwiftUI

@main
enum EdgeBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingSidebarPanel?
    private var urlPickerPanel: URLPickerPanel?
    private var pendingPickerURL: String?
    private var cancellables = Set<AnyCancellable>()
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var middleClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var pickerKeyMonitor: Any?

    private let store = ProfileStore.shared
    private let controller = EdgeController.shared
    private let focus = FocusMonitor.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.ensureAccessibilityPermission()
        setupStatusItem()
        setupPanel()
        bindPublishers()
        registerHotKeys()
        setupMiddleClickMonitor()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        store.reload()
        relayoutPanel()
        applyVisibility(animated: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterHotKeys()
        focus.shutdown()
        tearDownPickerKeyMonitor()
        if let middleClickMonitor {
            NSEvent.removeMonitor(middleClickMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        route(urls: urls)
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else { return }
        route(urls: [url])
    }

    private func route(urls: [URL]) {
        guard let first = urls.first,
              let urlString = Self.resolveRoutableURL(from: first)
        else { return }
        presentURLPicker(for: urlString)
    }

    /// Unwraps `edgebar:` wrappers so Edge receives a normal http(s) URL.
    private static func resolveRoutableURL(from url: URL) -> String? {
        let absolute = url.absoluteString
        if url.scheme?.lowercased() == "edgebar" {
            let lowered = absolute.lowercased()
            if let httpRange = lowered.range(of: "https://") ?? lowered.range(of: "http://") {
                let start = absolute.index(
                    absolute.startIndex,
                    offsetBy: lowered.distance(from: lowered.startIndex, to: httpRange.lowerBound)
                )
                let extracted = String(absolute[start...])
                return EdgeController.normalizeURL(extracted) ?? extracted
            }
            if let host = url.host, !host.isEmpty {
                let path = url.path
                let candidate = path.isEmpty ? host : "\(host)\(path)"
                return EdgeController.normalizeURL(candidate)
            }
            return nil
        }
        return absolute
    }

    private func presentURLPicker(for urlString: String) {
        pendingPickerURL = urlString
        let picker = urlPickerPanel ?? URLPickerPanel()
        picker.onDismiss = { [weak self] in
            self?.dismissURLPicker(open: false)
        }
        picker.host(
            URLPickerView(
                urlString: urlString,
                profiles: store.profiles,
                onSelect: { [weak self] profile in
                    self?.selectPickerProfile(profile)
                },
                onCancel: { [weak self] in
                    self?.dismissURLPicker(open: false)
                }
            )
        )
        urlPickerPanel = picker
        picker.present(profileCount: store.profiles.count)
        installPickerKeyMonitor()
    }

    private func selectPickerProfile(_ profile: EdgeProfile) {
        guard let url = pendingPickerURL else {
            dismissURLPicker(open: false)
            return
        }
        controller.open(url: url, in: profile)
        dismissURLPicker(open: true)
    }

    private func dismissURLPicker(open _: Bool) {
        tearDownPickerKeyMonitor()
        pendingPickerURL = nil
        // Clear onDismiss before resign/orderOut to avoid re-entrancy.
        urlPickerPanel?.onDismiss = nil
        urlPickerPanel?.dismiss()
    }

    private func installPickerKeyMonitor() {
        tearDownPickerKeyMonitor()
        pickerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.pendingPickerURL != nil else { return event }
            if event.keyCode == 53 { // Escape
                self.dismissURLPicker(open: false)
                return nil
            }
            if let chars = event.charactersIgnoringModifiers,
               let digit = chars.first,
               digit >= "1", digit <= "9",
               !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control),
               !event.modifierFlags.contains(.option) {
                let index = Int(String(digit))! - 1
                if index >= 0, index < self.store.profiles.count {
                    self.selectPickerProfile(self.store.profiles[index])
                    return nil
                }
            }
            return event
        }
    }

    private func tearDownPickerKeyMonitor() {
        if let pickerKeyMonitor {
            NSEvent.removeMonitor(pickerKeyMonitor)
            self.pickerKeyMonitor = nil
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.split.1x2",
                accessibilityDescription: "EdgeBar"
            )
            button.image?.isTemplate = true
        }
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if store.profiles.isEmpty {
            let empty = NSMenuItem(title: store.lastError ?? "No Edge profiles found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, profile) in store.profiles.enumerated() {
                let title: String
                if let userName = profile.userName, !userName.isEmpty {
                    title = "\(profile.displayName) — \(userName)"
                } else {
                    title = profile.displayName
                }
                let key = index < 9 ? "\(index + 1)" : ""
                let item = NSMenuItem(
                    title: title,
                    action: #selector(menuActivateProfile(_:)),
                    keyEquivalent: key
                )
                item.target = self
                item.representedObject = profile.directoryName
                if index < 9 {
                    item.keyEquivalentModifierMask = [.command]
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let edgeAware = NSMenuItem(
            title: VisibilityMode.edgeAware.menuTitle,
            action: #selector(setVisibilityEdgeAware),
            keyEquivalent: ""
        )
        edgeAware.target = self
        edgeAware.state = focus.visibilityMode == .edgeAware ? .on : .off
        menu.addItem(edgeAware)

        let always = NSMenuItem(
            title: VisibilityMode.alwaysVisible.menuTitle,
            action: #selector(setVisibilityAlways),
            keyEquivalent: ""
        )
        always.target = self
        always.state = focus.visibilityMode == .alwaysVisible ? .on : .off
        menu.addItem(always)

        menu.addItem(.separator())

        let left = NSMenuItem(
            title: DockSide.left.menuTitle,
            action: #selector(dockLeft),
            keyEquivalent: ""
        )
        left.target = self
        left.state = focus.dockSide == .left ? .on : .off
        menu.addItem(left)

        let right = NSMenuItem(
            title: DockSide.right.menuTitle,
            action: #selector(dockRight),
            keyEquivalent: ""
        )
        right.target = self
        right.state = focus.dockSide == .right ? .on : .off
        menu.addItem(right)

        menu.addItem(.separator())

        let defaultBrowserTitle: String
        if DefaultBrowser.isDefault {
            defaultBrowserTitle = "EdgeBar Is Default Browser"
        } else {
            defaultBrowserTitle = "Use EdgeBar as Default Browser…"
        }
        let defaultBrowser = NSMenuItem(
            title: defaultBrowserTitle,
            action: DefaultBrowser.isDefault ? nil : #selector(makeDefaultBrowser),
            keyEquivalent: ""
        )
        defaultBrowser.target = self
        defaultBrowser.state = DefaultBrowser.isDefault ? .on : .off
        if DefaultBrowser.isDefault {
            defaultBrowser.isEnabled = false
        }
        menu.addItem(defaultBrowser)

        let reload = NSMenuItem(
            title: "Reload Profiles from Local State",
            action: #selector(reloadProfiles),
            keyEquivalent: "r"
        )
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit EdgeBar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func makeDefaultBrowser() {
        _ = DefaultBrowser.setAsDefault()
        // macOS may show a confirmation; refresh status after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.rebuildMenu()
        }
        rebuildMenu()
    }

    @objc private func menuActivateProfile(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String,
              let profile = store.profiles.first(where: { $0.directoryName == dir })
        else { return }
        controller.activate(profile: profile)
    }

    @objc private func setVisibilityEdgeAware() {
        focus.visibilityMode = .edgeAware
        rebuildMenu()
    }

    @objc private func setVisibilityAlways() {
        focus.visibilityMode = .alwaysVisible
        rebuildMenu()
    }

    @objc private func dockLeft() {
        focus.dockSide = .left
        panel?.snapToDock(.left, screen: NSScreen.main)
        rebuildMenu()
    }

    @objc private func dockRight() {
        focus.dockSide = .right
        panel?.snapToDock(.right, screen: NSScreen.main)
        rebuildMenu()
    }

    @objc private func reloadProfiles() {
        store.reload()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Panel

    private func setupPanel() {
        let panel = FloatingSidebarPanel(contentRect: NSRect(x: 0, y: 0, width: 56, height: 200))
        panel.host(
            SidebarView(store: store, controller: controller, focus: focus)
        )
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func bindPublishers() {
        store.$profiles
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
                self?.relayoutPanel()
                self?.controller.refreshActiveProfile(from: self?.store.profiles ?? [])
            }
            .store(in: &cancellables)

        focus.$shouldShowSidebar
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                self?.applyVisibility(visible: visible, animated: true)
            }
            .store(in: &cancellables)

        focus.$dockSide
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] side in
                self?.panel?.snapToDock(side, screen: NSScreen.main)
            }
            .store(in: &cancellables)

        Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.controller.refreshActiveProfile(from: self.store.profiles)
            }
            .store(in: &cancellables)
    }

    private func relayoutPanel() {
        panel?.layoutForProfiles(
            count: max(store.profiles.count, 1),
            dockSide: focus.dockSide,
            screen: NSScreen.main
        )
        // Re-host so SwiftUI reflects new height.
        panel?.host(SidebarView(store: store, controller: controller, focus: focus))
    }

    private func applyVisibility(animated: Bool = true) {
        applyVisibility(visible: focus.shouldShowSidebar, animated: animated)
    }

    private func applyVisibility(visible: Bool, animated: Bool) {
        panel?.setVisible(visible, animated: animated)
    }

    // MARK: - Hotkeys (⌃⌥1…9)

    private func registerHotKeys() {
        var handlerSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                Task { @MainActor in
                    delegate.handleHotKey(id: Int(hotKeyID.id))
                }
                return noErr
            },
            1,
            &handlerSpec,
            userData,
            &eventHandler
        )

        let keyCodes: [UInt32] = [
            18, 19, 20, 21, 23, 22, 26, 28, 25 // 1…9
        ]
        let modifiers: UInt32 = UInt32(controlKey | optionKey)
        hotKeyRefs = []
        for (index, keyCode) in keyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x45444742), id: UInt32(index + 1)) // 'EDGB'
            RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            hotKeyRefs.append(ref)
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func handleHotKey(id: Int) {
        let index = id - 1
        guard index >= 0, index < store.profiles.count else { return }
        controller.activate(profile: store.profiles[index])
    }

    private func setupMiddleClickMonitor() {
        middleClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            guard event.buttonNumber == 2 else { return }
            Task { @MainActor in
                self?.handleMiddleClick(at: event.locationInWindow, inScreen: NSEvent.mouseLocation)
            }
        }
        // Also local (when panel is key).
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            if event.buttonNumber == 2 {
                Task { @MainActor in
                    self?.handleMiddleClick(at: event.locationInWindow, inScreen: NSEvent.mouseLocation)
                }
            }
            return event
        }
    }

    private func handleMiddleClick(at _: NSPoint, inScreen screenPoint: NSPoint) {
        guard let panel, panel.frame.contains(screenPoint) else { return }
        // Map Y within panel to profile index.
        let localY = screenPoint.y - panel.frame.minY
        let padding: CGFloat = 10
        let rowHeight: CGFloat = 48
        let fromTop = panel.frame.height - localY - padding
        let index = Int(fromTop / rowHeight)
        guard index >= 0, index < store.profiles.count else { return }
        controller.activate(profile: store.profiles[index], forceNewWindow: true)
    }
}
