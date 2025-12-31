# KeyTap

A macOS menu bar app that maps keyboard keys to mouse actions. Perfect for games and applications that require mouse input but where you'd prefer keyboard controls.

## Features

### Keyboard to Mouse Mapping

- **WASD Movement** — Drag the mouse in any direction using W/A/S/D keys (including diagonals)
- **Q/E Scroll** — Scroll up/down with Q and E keys (auto-repeats while held)
- **Custom Button Bindings** — Bind any key to click at specific screen positions

### Button Types

| Type | Behavior |
|------|----------|
| **Click** | Single click on key press, cursor returns to original position |
| **Hold** | Hold mouse button while key is held |
| **Joystick** | Drag from button center in one of 8 directions |

### Target App Selection

- **Per-App Targeting** — Only activate in a specific application
- **All Apps Mode** — Works globally across all applications
- **Running Apps Menu** — Quick select from currently running apps
- **Custom App Picker** — Browse to select any installed application

### Visual Overlay

- **Button Indicators** — See exactly where your keys will click
- **Edit Mode** — Drag to position buttons, resize, and configure
- **Per-App Profiles** — Button layouts are saved separately for each target app
- **Auto-Tracking** — Overlay follows the target app's window

### Configurable Settings

- **Drag Distance** — Small (25px), Medium (50px), Large (100px), Very Large (150px)
- **Smooth Animations** — 60fps eased mouse movements for natural feel

## Requirements

- macOS 12.0 or later
- **Accessibility Permission** — Required to intercept keyboard events and control the mouse

## Installation

1. Download the latest release
2. Move `KeyTap.app` to `/Applications`
3. Launch KeyTap
4. Grant Accessibility permission when prompted:
   - System Settings → Privacy & Security → Accessibility → Enable KeyTap

## Usage

### Basic Setup

1. Click the menu bar icon (🖱️ when disabled, 🎮 when enabled)
2. Select **Target** → Choose your target application
3. Click **Enable WASD Mode**
4. Use WASD to drag, Q/E to scroll

### Configuring Buttons

1. Select your target app
2. Go to **Buttons** → **Edit Buttons...**
3. In edit mode:
   - **Click** a button to select it
   - **Drag** to reposition
   - **Right-click** for options (change type, bind key, delete)
   - **Add buttons** from the context menu
4. Click **Done Editing** or press Escape to save

### Button Binding

When binding a key to a button:
1. Right-click the button → **Bind Key**
2. Press the desired key
3. The button will now trigger when that key is pressed

### Joystick Buttons

Joystick buttons simulate a drag gesture:
1. Set button type to **Joystick**
2. Choose a direction (↑↓←→↖↗↙↘)
3. Set the drag distance
4. When the bound key is pressed, it drags from the button center in that direction

## Default Key Bindings

| Key | Action |
|-----|--------|
| W | Drag up |
| A | Drag left |
| S | Drag down |
| D | Drag right |
| Q | Scroll up |
| E | Scroll down |

Diagonal movement is supported by pressing two WASD keys simultaneously (e.g., W+D for up-right).

## How It Works

KeyTap uses macOS CGEvent APIs to:
1. Intercept keyboard events via an event tap
2. Convert them to synthetic mouse events
3. Post those events to the target application

The app runs as a menu bar utility (`LSUIElement`) with no dock icon.

## Building from Source

1. Clone the repository
2. Open `KeyTap.xcodeproj` in Xcode
3. Build and run (⌘R)

## Privacy & Security

KeyTap requires Accessibility permission to function. This permission allows the app to:
- Monitor keyboard input (only WASD, Q, E, and bound keys)
- Generate mouse click and drag events
- Track window positions for overlay alignment

**KeyTap does not:**
- Log or transmit any keystrokes
- Access any data outside its operation
- Connect to the internet

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.
