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
- Activating a profile shows that profile’s workspace. Windows EdgeBar previously minimized for it are restored, the last-focused one is raised, and windows bound to every other profile are minimized. The switch reuses the latest window list and applies the change in one step. A window EdgeBar cannot attribute to a profile is left alone. A window opened while a profile is in front joins that profile, so one profile can own several windows. A new window is spawned only when the profile has none, or on Shift-click, ⌘-click, or middle-click. A window you minimize yourself stays minimized when you return, unless it is the only window of that profile. macOS may prompt once to allow EdgeBar to control Microsoft Edge.
- Global shortcuts: `⌃⌥1`–`⌃⌥9`.
- The sidebar shows each profile’s name and a picture. A profile with no picture receives a random one. Right-click a row and choose **Change Icon…** to pick another, from the same kind of grid macOS uses for account pictures.
- Menu bar item toggles Edge-aware auto-hide vs always visible, and left/right docking.
- Drag a URL onto a profile avatar to open it in that profile.

### Default browser and link clicks

macOS delivers `http` / `https` clicks only to the **default** URL handler. EdgeBar registers those schemes, but other apps will not call it until you make it the default browser once:

1. Launch EdgeBar.
2. Open the menu-bar item → **Use EdgeBar as Default Browser…** (macOS may ask you to confirm).
3. Thereafter, link clicks open a floating **profile picker** (truncated URL + avatar/name/email list). Press `1`–`9` for the matching sidebar profile, click a row, or press `Esc` to dismiss without opening.

Drag-to-avatar and “Open Clipboard URL” still open immediately in the chosen profile (no picker). The custom `edgebar:` scheme also shows the picker when EdgeBar is already running.

## Window matching tip

Edge remembers one rectangle per profile in `Preferences` (`browser.window_placement`). EdgeBar uses a unique exact match to identify an unbound window, then keeps that binding. Further windows of the same profile are remembered as a set: each new window inherits the profile of the front window, or of the EdgeBar action that spawned it. Right-click **Bind Frontmost Edge Window** to pin a window placement cannot identify; a manual bind is never overwritten by geometry. Allow **Automation** for EdgeBar → Microsoft Edge on first use.

## Architecture

See [PLAN.md](PLAN.md) for the full design specification.
