# EdgeBar

A zero-dependency macOS utility that presents a non-activating floating sidebar of Microsoft Edge profiles, with deterministic window focusing and URL routing into a chosen profile.

## Requirements

- macOS 14+
- Swift 5.9+ (`xcode-select` / Command Line Tools)
- Microsoft Edge installed at `/Applications/Microsoft Edge.app`
- Accessibility permission for window focusing

## Build

```bash
chmod +x scripts/bundle.sh
./scripts/bundle.sh
open build/EdgeBar.app
```

The bundle script runs `swift build -c release`, assembles `build/EdgeBar.app`, and ad-hoc codesigns the bundle so Accessibility grants persist across launches.

## Behaviour

- Profiles are read from `~/Library/Application Support/Microsoft Edge/Local State` and refreshed when that directory changes.
- Activating a profile raises that profile’s existing Edge window by matching live window bounds to each profile’s saved `browser.window_placement` (then raising via AppleScript). A new window is spawned only when none match. macOS may prompt once to allow EdgeBar to control Microsoft Edge.
- Global shortcuts: `⌃⌥1`–`⌃⌥9`.
- Menu bar item toggles Edge-aware auto-hide vs always visible, and left/right docking.
- Drag a URL onto a profile avatar to open it in that profile.

### Default browser and link clicks

macOS delivers `http` / `https` clicks only to the **default** URL handler. EdgeBar registers those schemes, but other apps will not call it until you make it the default browser once:

1. Launch EdgeBar.
2. Open the menu-bar item → **Use EdgeBar as Default Browser…** (macOS may ask you to confirm).
3. Thereafter, link clicks open a floating **profile picker** (truncated URL + avatar/name/email list). Press `1`–`9` for the matching sidebar profile, click a row, or press `Esc` to dismiss without opening.

Drag-to-avatar and “Open Clipboard URL” still open immediately in the chosen profile (no picker). The custom `edgebar:` scheme also shows the picker when EdgeBar is already running.

## Window matching tip

Edge remembers each profile’s window position in `Preferences` (`browser.window_placement`). EdgeBar matches those rectangles to open windows (unique exact geometry only), so focusing does not depend on title-bar profile names. Right-click **Bind Frontmost Edge Window** to pin a window that placement cannot identify (e.g. a second window for the same profile); manual binds survive rematching. Shift/⌘-click (or middle-click) still force-opens a new window. Allow **Automation** for EdgeBar → Microsoft Edge on first use.

## Architecture

See [PLAN.md](PLAN.md) for the full design specification.
