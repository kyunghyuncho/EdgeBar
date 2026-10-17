# PLAN.md — EdgeBar: Lightweight macOS Floating Profile Switcher & URL Router for Microsoft Edge

## 1. Objective & Architecture Overview
Build a zero-dependency, lightweight native macOS utility (`EdgeBar`) in Swift (AppKit + SwiftUI) that provides:
1. **A Non-Activating Floating Sidebar (`NSPanel`):** A slim vertical dock anchored to the screen edge (or auto-shown when Microsoft Edge is the active application) displaying all Microsoft Edge profiles with their custom avatars, names, and shortcuts (`⌘1`–`⌘9`).
2. **Deterministic Profile Switching & Window Focusing:** Clicking a profile button or pressing its hotkey raises the existing Microsoft Edge window for that profile if open, or spawns a new window in that profile via direct Mach-O binary invocation without creating duplicate browser processes.
3. **Optional URL Routing Receiver:** Registers as a handler for `http`/`https` (or custom URL scheme / drag-and-drop onto a profile icon) so links dropped onto or routed through a profile open directly in that isolated Edge profile.

### Core Design Constraints
- **Zero External Dependencies:** Pure Swift (`AppKit`, `SwiftUI`, `Foundation`, `ApplicationServices`). No third-party packages, no Electron, no WebViews.
- **CLI Buildable:** Structured as a Swift Package (`Package.swift`) with a build script (`scripts/bundle.sh`) that compiles the release binary and packages a valid macOS `.app` bundle (`LSUIElement = true`) from the terminal.
- **Resource Footprint:** < 25 MB RAM, 0% idle CPU (event-driven via `NSWorkspace` notifications and `DispatchSourceFileSystemObject` on Edge's `Local State` file).

---

## 2. Project Directory Structure

```text
EdgeBar/
├── Package.swift
├── Info.plist
├── scripts/
│   └── bundle.sh
└── Sources/
    └── EdgeBar/
        ├── EdgeBarApp.swift          # Entry point, AppDelegate, NSApplication.ActivationPolicy.accessory
        ├── Models/
        │   └── EdgeProfile.swift     # Codable models for Local State parsing & profile metadata
        ├── Services/
        │   ├── ProfileStore.swift    # Parses & watches ~/Library/Application Support/Microsoft Edge/Local State
        │   ├── EdgeController.swift  # Spawns profiles via Mach-O binary & raises existing windows via AXUIElement
        │   └── FocusMonitor.swift    # Tracks frontmost app to auto-show/dim sidebar when Edge is active
        └── UI/
            ├── FloatingSidebarPanel.swift # Subclass of NSPanel (.nonactivatingPanel, .floating)
            └── SidebarView.swift          # SwiftUI view for vertical profile strip + drag-and-drop URL targets

```

---

## 3. Technical Implementation Specifications

### Component 1: `Models/EdgeProfile.swift` & `Services/ProfileStore.swift`

Microsoft Edge stores all profile metadata in a master JSON file at:
`~/Library/Application Support/Microsoft Edge/Local State`

1. **JSON Path:** Parse root key `"profile"` -> `"info_cache"`.
2. **Dictionary Structure:** Each key inside `"info_cache"` is the internal profile directory name (e.g., `"Default"`, `"Profile 1"`, `"Profile 2"`). The value is a JSON object containing:
* `"name"`: String (User-assigned profile name, e.g., `"Work"`, `"NYU"`, `"Ortet"`)
* `"user_name"`: String? (Signed-in email address, e.g., `"user@domain.com"`)
* `"shortcut_name"`: String?
* `"profile_highlight_color"`: Int? (ARGB signed integer for theme tint)
* `"gaia_picture_file_name"` or avatar icon inside `~/Library/Application Support/Microsoft Edge/<ProfileDir>/Edge Profile Picture.png` (or `Google Profile Picture.png`).


3. **Window Title Disambiguation Check:**
* Also check `~/Library/Application Support/Microsoft Edge/<ProfileDir>/Preferences` (JSON) under `"browser" -> "window_name"` if present, as this aids matching existing open windows.


4. **Live File Watcher:**
* Use a low-overhead timer or `DispatchSource.makeFileSystemObjectSource` on the `Local State` file descriptor so adding/renaming profiles in Edge updates the sidebar automatically.
* Sort profiles deterministically (e.g., `"Default"` first, then sorted by `name` or custom user order persisted in `UserDefaults`).



---

### Component 2: `Services/EdgeController.swift` (Switching, Focusing & Routing)

This service solves two macOS Chromium quirks:

#### Quirk A: Launching / Opening URLs in a Specific Profile While Edge is Running

* **NEVER use `/usr/bin/open -a "Microsoft Edge" --args --profile-directory=...**`. When Edge is already running, macOS `open -a` drops `--args`. Using `open -n` spawns a conflicting duplicate browser process that corrupts profile locks.
* **ALWAYS invoke the Mach-O binary directly** via `Foundation.Process`:
```swift
let edgeBinary = URL(fileURLWithPath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
let process = Process()
process.executableURL = edgeBinary
var args = ["--profile-directory=\(profile.directoryName)"]
if let urlString = targetURL {
    args.append(urlString)
}
process.arguments = args
try? process.run() // Immediately hands off IPC message to running Edge master process and exits 0

```



#### Quirk B: Focusing an Already-Open Profile Window Without Spawning a New Tab

When the user clicks a profile in the sidebar (with no URL to open), they want to bring that profile's *existing* window to the front—and only spawn a new window via the Mach-O binary if that profile currently has zero open windows.

Implement a two-tier window-matching strategy in `EdgeController`:

1. **Accessibility API (`AXUIElement`) Window Inspection:**
* Check `AXIsProcessTrustedWithOptions` on startup (prompting user once to grant Accessibility permission).
* Locate the running Microsoft Edge PID via `NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.edgemac" })`.
* Query `kAXWindowsAttribute` on `AXUIElementCreateApplication(pid)`.
* Inspect each window's `kAXTitleAttribute`.
* **Matching Heuristic:**
* By default or when configured in Edge (`edge://settings/appearance` -> *Show profile name in window title* or custom window naming), Edge appends ` - Microsoft Edge` or ` - [Profile Name] - Microsoft Edge` to window titles, OR the user can right-click a profile in `EdgeBar` to "Bind Current Active Edge Window to Profile" (which records the `CGWindowID` / `_AXUIElementGetWindow` ID in an in-memory map `[WindowID: ProfileDirectory]`).
* Additionally, whenever `EdgeBar` spawns a profile via `Process`, observe the newly created `AXUIElement` window within 800ms and automatically bind its `CGWindowID` to that `profile.directoryName`.




2. **Raising the Matched Window:**
* If a matching window is found:
1. Activate Edge: `edgeApp.activate(options: [.activateIgnoringOtherApps])`
2. Perform `AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)`
3. Set `AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, kCFBooleanTrue)`


* If **no** matching window is open for that profile (or `⇧Click` / `⌘Click` is used):
* Execute the Mach-O binary invocation with `--profile-directory=<dir>` to open a fresh window for that profile and bind its resulting `CGWindowID`.





---

### Component 3: `UI/FloatingSidebarPanel.swift` (Non-Activating `NSPanel`)

Subclass `NSPanel` so clicking the sidebar never steals focus in a jarring way or kicks full-screen apps out of their Space:

```swift
final class FloatingSidebarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating // Use .statusBar or .screenSaver if full-screen overlay is toggled
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
    }
}

```

* **Screen-Edge Snapping & Persistence:**
* Default position: Vertically centered on the left or right edge of `NSScreen.main?.visibleFrame` (width: `52pt`, dynamic height based on profile count).
* Persist position in `UserDefaults` on `NSWindow.didMoveNotification`.



---

### Component 4: `UI/SidebarView.swift` & `Services/FocusMonitor.swift`

Build a clean, dark-glass (`NSVisualEffectView` / `.ultraThinMaterial`) vertical strip in SwiftUI:

1. **Profile Pill / Avatar Button:**
* Displays the profile's image (if found in the profile directory) or a crisp 2-letter monogram circle tinted with the profile's highlight color.
* Displays a subtle active indicator dot on the profile that owns the currently focused Edge window.
* Hover tooltip showing full Profile Name + Email (`user_name`) + Shortcut (`⌃⌥1`, etc.).


2. **Interaction Modes:**
* **Left-Click:** Focus existing window for this profile (or launch if none open).
* **Middle-Click or `⇧ + Left-Click`:** Force-spawn a *new* Edge window in this profile.
* **Right-Click Context Menu:**
* *"Bind Frontmost Edge Window to [Profile Name]"* (manual override for `CGWindowID` mapping)
* *"Open Clipboard URL in [Profile Name]"*
* *"Copy `--profile-directory` CLI flag"*


* **Drag-and-Drop URL Routing (`.onDrop(of: [.url, .text])`):**
* Dragging any link or URL text onto a profile icon immediately routes that URL to `--profile-directory="<Profile>"`.




3. **Visibility Modes (Configurable via Menu Bar `NSStatusItem`):**
* **Mode A (Edge-Aware Auto-Hide - Default):** `FocusMonitor` listens to `NSWorkspace.didActivateApplicationNotification`. The sidebar stays visible when Microsoft Edge is the active app (or when the mouse cursor hits the 4px screen edge trigger zone) and fades out when switching to other apps like Cursor or Terminal.
* **Mode B (Always Visible):** Remains docked on screen across all apps.



---

### Component 5: Global Hotkeys & Menu Bar Controller (`EdgeBarApp.swift`)

1. Run as an agent app (`NSApp.setActivationPolicy(.accessory)`) so it does not clutter `⌘Tab` or the Dock.
2. Add an `NSStatusItem` in the macOS menu bar with:
* Quick list of discovered profiles (with `1`–`9` shortcuts).
* Toggle between *"Show Only When Edge is Active"* and *"Always Visible"*.
* Toggle *"Dock Left"* vs. *"Dock Right"*.
* *"Reload Profiles from Local State"*.
* *"Quit EdgeBar"*.


3. Register global keyboard shortcuts (using Carbon `RegisterEventHotKey` or `NSEvent.addGlobalMonitorForEvents`) for `Ctrl + Opt + 1...9` so the user can jump directly to Profile 1..9 from any application without touching the mouse.

---

## 4. Step-by-Step Execution Plan for Cursor

Execute these steps sequentially and verify compilation at each phase:

### Step 1: Scaffold Swift Package & Bundle Script

* Create `Package.swift` targeting `.macOS(.v14)` with executable target `EdgeBar`.
* Create `Info.plist` with `LSUIElement = true`, bundle identifier `com.local.EdgeBar`, and URL scheme registration (`http`, `https`) so `EdgeBar` can optionally act as an OS URL router.
* Create `scripts/bundle.sh` that runs `swift build -c release`, constructs `build/EdgeBar.app/Contents/{MacOS,Resources}`, copies the binary and `Info.plist`, and ad-hoc codesigns (`codesign --force --deep --sign - build/EdgeBar.app`) so macOS Accessibility permissions persist across launches.

### Step 2: Implement `ProfileStore` & Verify Local State Parsing

* Implement `EdgeProfile.swift` and `ProfileStore.swift`.
* Read `~/Library/Application Support/Microsoft Edge/Local State`.
* Extract `directoryName`, `name`, `userName`, and resolve the avatar image path.
* Add a fallback in case Edge is not installed or `Local State` is locked during read (read via `Data(contentsOf: options: .mappedIfSafe)`).

### Step 3: Implement `EdgeController` (Mach-O Launcher + `AXUIElement` Window Matcher)

* Implement direct process spawning to `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge` with `--profile-directory=<dir>`.
* Implement `AXUIElement` window enumeration for `com.microsoft.edgemac`.
* Implement `CGWindowID` tracking (`_AXUIElementGetWindow` private SPI declaration: `@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError`) so windows can be deterministically mapped to profiles both by window title substring and by cached `CGWindowID`.

### Step 4: Implement `FloatingSidebarPanel` & `SidebarView`

* Build the `NSPanel` wrapper and SwiftUI view with avatar icons, keyboard badge numbers, hover tooltips, right-click context menu, and `.onDrop` URL routing.
* Implement `FocusMonitor` so the panel smoothly fades (`animator().alphaValue`) based on whether Microsoft Edge is frontmost (with mouse hover override).

### Step 5: Build, Bundle & Smoke Test

* Run `chmod +x scripts/bundle.sh && ./scripts/bundle.sh`.
* Verify zero compiler warnings or errors.
* Launch `open build/EdgeBar.app` and verify that profiles from `~/Library/Application Support/Microsoft Edge/Local State` populate in the floating sidebar.
