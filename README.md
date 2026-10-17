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
- Activating a profile raises the latest existing Edge window for that profile (last-focused, else frontmost match via title / chrome label / `CGWindowID` bindings). A new window is spawned only when none are open for that profile (never `open -a … --args`).
- Global shortcuts: `⌃⌥1`–`⌃⌥9`.
- Menu bar item toggles Edge-aware auto-hide vs always visible, and left/right docking.
- Drag a URL onto a profile avatar to open it in that profile.

## Window matching tip

EdgeBar remembers which windows belong to which profile (including across EdgeBar relaunches while Edge stays open) and learns from focus changes. For windows opened before any binding exists, enable **Show profile name in the title bar** under `edge://settings/appearance`, or right-click a profile and choose **Bind Frontmost Edge Window**. Shift/⌘-click (or middle-click) still force-opens a new window.

## Architecture

See [PLAN.md](PLAN.md) for the full design specification.
