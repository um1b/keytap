# KeyTap

Play iOS games on your Mac with keyboard controls.

KeyTap maps keyboard keys to screen taps and gestures, making touch-based iOS apps fully playable with WASD + custom key bindings.

## Why KeyTap?

iOS apps on Apple Silicon Macs don't support keyboard input — you're stuck clicking and dragging with a mouse. KeyTap fixes this by letting you:

- Use **WASD** for virtual joysticks and drag gestures
- Bind **any key** to tap specific buttons on screen
- Create **per-app profiles** so each game has its own layout

## Features

- **WASD Movement** — Drag in any direction (including diagonals)
- **Q/E Scroll** — Scroll up/down (auto-repeats while held)
- **Custom Buttons** — Place tap targets anywhere, bind to any key
- **Button Types** — Click, Hold, or Joystick (8-direction drag)
- **Visual Overlay** — See your button layout over the app
- **Per-App Profiles** — Layouts save automatically for each app

## Requirements

- macOS 12.0+ on Apple Silicon
- Accessibility permission (for keyboard capture)

## Installation

1. Download from [Releases](https://github.com/um1b/keytap/releases/latest)
2. Move `KeyTap.app` to `/Applications`
3. Launch and grant Accessibility permission:
   **System Settings → Privacy & Security → Accessibility → Enable KeyTap**

> **Gatekeeper warning?** macOS may block the app since it's not notarized. To open:
> 1. Try to open the app (you'll see a warning)
> 2. Go to **System Settings → Privacy & Security**
> 3. Scroll down and click **Open Anyway**
>
> Or run in Terminal: `xattr -cr /Applications/KeyTap.app`

### Build from Source

```
git clone https://github.com/um1b/keytap.git
cd keytap
open KeyTap.xcodeproj
# Build with ⌘R
```

## Quick Start

1. Click the menu bar icon
2. **Target** → Select your iOS app
3. **Enable WASD Mode**
4. Use WASD to drag, Q/E to scroll

## Adding Buttons

1. **Buttons** → **Edit Buttons...**
2. Right-click to add buttons over UI elements
3. Drag to position, right-click to bind keys
4. Press Escape when done

## Default Keys

| Key | Action |
|-----|--------|
| W/A/S/D | Drag up/left/down/right |
| Q/E | Scroll up/down |

Hold two WASD keys for diagonal movement.

## Privacy

KeyTap only captures configured keys and generates mouse events locally. No data is logged or transmitted.

## License

MIT — See [LICENSE](LICENSE)
