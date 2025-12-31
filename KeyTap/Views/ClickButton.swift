import Cocoa

class ClickButton: NSView {
    // MARK: - Properties
    var keyCode: UInt16 = 0
    var keyLabel: String = "?" {
        didSet { needsDisplay = true }
    }
    var buttonType: KeyButtonType = .click {
        didSet {
            updateAppearance()
            needsDisplay = true
        }
    }
    var joystickDirection: JoystickDirection = .up {
        didSet { needsDisplay = true }
    }
    var joystickDistance: CGFloat = 50.0

    weak var overlayWindow: OverlayWindow?

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    private var isEditing = false
    private var isDragging = false
    private var dragOffset: CGPoint = .zero
    private var isWaitingForKey = false
    private var keyMonitor: Any?

    // MARK: - Initialization
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancelKeyBinding()
    }

    func cancelKeyBinding() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        isWaitingForKey = false
    }

    // MARK: - Edit Mode
    func setEditMode(_ editing: Bool) {
        isEditing = editing
        updateAppearance()
    }

    private var isUnbound: Bool {
        return keyCode == 0 && keyLabel == "?"
    }

    private func updateAppearance() {
        if buttonType == .joystick {
            // Joystick uses custom circle drawing, no background
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            alphaValue = isEditing ? 1.0 : (isUnbound ? 0.5 : 0.8)
        } else {
            let baseColor: NSColor
            switch buttonType {
            case .click:
                baseColor = .systemOrange
            case .hold:
                baseColor = .systemGreen
            case .joystick:
                baseColor = .systemBlue
            }

            if isEditing {
                layer?.backgroundColor = baseColor.withAlphaComponent(0.85).cgColor
                if isSelected {
                    layer?.borderColor = NSColor.systemYellow.cgColor
                    layer?.borderWidth = 3
                } else if isUnbound {
                    // Dashed border for unbound buttons
                    layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
                    layer?.borderWidth = 2
                } else {
                    layer?.borderColor = NSColor.white.cgColor
                    layer?.borderWidth = 2
                }
                alphaValue = 1.0
            } else {
                layer?.backgroundColor = baseColor.withAlphaComponent(isUnbound ? 0.3 : 0.6).cgColor
                layer?.borderColor = NSColor.white.withAlphaComponent(isUnbound ? 0.3 : 0.5).cgColor
                layer?.borderWidth = 1
                alphaValue = isUnbound ? 0.5 : 0.8
            }
        }
        needsDisplay = true
    }

    // MARK: - Drawing
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if buttonType == .joystick {
            drawJoystickCircles()
        } else {
            drawStandardButton()
        }
    }

    private func drawJoystickCircles() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let outerRadius = min(bounds.width, bounds.height) / 2 - 2
        let innerRadius = outerRadius * 0.5

        // Outer circle (ring)
        let outerCircle = NSBezierPath(ovalIn: NSRect(
            x: center.x - outerRadius,
            y: center.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))

        if isEditing {
            NSColor.systemBlue.withAlphaComponent(0.3).setFill()
            outerCircle.fill()
            if isSelected {
                NSColor.systemYellow.setStroke()
                outerCircle.lineWidth = 3
            } else {
                NSColor.white.setStroke()
                outerCircle.lineWidth = 2
            }
        } else {
            NSColor.systemBlue.withAlphaComponent(0.2).setFill()
            outerCircle.fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            outerCircle.lineWidth = 1.5
        }
        outerCircle.stroke()

        // Inner circle (joystick knob) - always offset by direction to show current setting
        let delta = joystickDirection.delta
        let offsetAmount: CGFloat = (outerRadius - innerRadius) * 0.4
        let innerCenter = CGPoint(
            x: center.x + delta.dx * offsetAmount,
            y: center.y - delta.dy * offsetAmount  // Flip Y for screen coordinates
        )

        let innerCircle = NSBezierPath(ovalIn: NSRect(
            x: innerCenter.x - innerRadius,
            y: innerCenter.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))

        NSColor.systemBlue.withAlphaComponent(isEditing ? 0.85 : 0.7).setFill()
        innerCircle.fill()
        NSColor.white.setStroke()
        innerCircle.lineWidth = 1.5
        innerCircle.stroke()

        // Draw direction arrow on inner circle
        let arrowText = joystickDirection.icon
        let arrowAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: innerRadius * 0.8),
            .foregroundColor: NSColor.white
        ]
        let arrowSize = arrowText.size(withAttributes: arrowAttributes)
        let arrowRect = NSRect(
            x: innerCenter.x - arrowSize.width / 2,
            y: innerCenter.y - arrowSize.height / 2,
            width: arrowSize.width,
            height: arrowSize.height
        )
        arrowText.draw(in: arrowRect, withAttributes: arrowAttributes)

        // Draw key label below outer circle
        let labelText = isWaitingForKey ? "..." : keyLabel
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 9),
            .foregroundColor: NSColor.white
        ]
        let labelSize = labelText.size(withAttributes: labelAttributes)
        let labelRect = NSRect(
            x: center.x - labelSize.width / 2,
            y: center.y - outerRadius - labelSize.height - 2,
            width: labelSize.width,
            height: labelSize.height
        )
        labelText.draw(in: labelRect, withAttributes: labelAttributes)
    }

    private func drawStandardButton() {
        // Main label (key or waiting indicator)
        let mainText = isWaitingForKey ? "..." : keyLabel

        let mainFontSize: CGFloat = keyLabel.count > 2 ? 10 : 13
        let mainAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: mainFontSize),
            .foregroundColor: NSColor.white
        ]

        let mainSize = mainText.size(withAttributes: mainAttributes)
        let mainRect = NSRect(
            x: (bounds.width - mainSize.width) / 2,
            y: (bounds.height - mainSize.height) / 2,
            width: mainSize.width,
            height: mainSize.height
        )
        mainText.draw(in: mainRect, withAttributes: mainAttributes)

        // Secondary label (type icon)
        let secondaryText = buttonType.icon
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]

        let secondarySize = secondaryText.size(withAttributes: secondaryAttributes)
        let secondaryRect = NSRect(
            x: (bounds.width - secondarySize.width) / 2,
            y: 4,
            width: secondarySize.width,
            height: secondarySize.height
        )
        secondaryText.draw(in: secondaryRect, withAttributes: secondaryAttributes)
    }

    // MARK: - Mouse Events
    override func mouseDown(with event: NSEvent) {
        guard isEditing else { return }

        // Notify overlay to select this button
        overlayWindow?.selectButton(self)

        if event.clickCount == 2 {
            startKeyBinding()
        } else {
            isDragging = true
            let location = convert(event.locationInWindow, from: nil)
            dragOffset = location
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditing, isDragging else { return }

        let location = event.locationInWindow
        let newOrigin = CGPoint(
            x: location.x - dragOffset.x,
            y: location.y - dragOffset.y
        )

        if let superview = self.superview {
            let maxX = superview.bounds.width - frame.width
            let maxY = superview.bounds.height - frame.height
            frame.origin = CGPoint(
                x: max(0, min(newOrigin.x, maxX)),
                y: max(0, min(newOrigin.y, maxY))
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            // Button was moved, mark as needing save
            overlayWindow?.markNeedsSave()
        }
        isDragging = false
        dragOffset = .zero  // Issue 40: Reset dragOffset on mouseUp
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEditing else { return }

        let menu = NSMenu()

        // Bind key
        let bindItem = NSMenuItem(title: "Bind Key (Double-click)", action: #selector(bindKeyAction), keyEquivalent: "")
        bindItem.target = self
        menu.addItem(bindItem)

        menu.addItem(NSMenuItem.separator())

        // Button type submenu
        let typeMenu = NSMenu()
        for type in KeyButtonType.allCases {
            let item = NSMenuItem(title: "\(type.icon) \(type.displayName)", action: #selector(setButtonType(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type
            item.state = (buttonType == type) ? .on : .off
            typeMenu.addItem(item)
        }
        let typeItem = NSMenuItem(title: "Button Type", action: nil, keyEquivalent: "")
        typeItem.submenu = typeMenu
        menu.addItem(typeItem)

        // Direction submenu (only for joystick)
        if buttonType == .joystick {
            let dirMenu = NSMenu()
            for dir in JoystickDirection.allCases {
                let item = NSMenuItem(title: "\(dir.icon) \(dir.displayName)", action: #selector(setDirection(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = dir
                item.state = (joystickDirection == dir) ? .on : .off
                dirMenu.addItem(item)
            }
            let dirItem = NSMenuItem(title: "Direction", action: nil, keyEquivalent: "")
            dirItem.submenu = dirMenu
            menu.addItem(dirItem)

            // Distance submenu
            let distMenu = NSMenu()
            for dist in [25, 50, 75, 100, 150] {
                let item = NSMenuItem(title: "\(dist)px", action: #selector(setDistance(_:)), keyEquivalent: "")
                item.target = self
                item.tag = dist
                item.state = (Int(joystickDistance) == dist) ? .on : .off
                distMenu.addItem(item)
            }
            let distItem = NSMenuItem(title: "Distance", action: nil, keyEquivalent: "")
            distItem.submenu = distMenu
            menu.addItem(distItem)
        }

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteAction), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func setButtonType(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? KeyButtonType else { return }

        // Warn if trying to add a second joystick
        if type == .joystick, let overlay = overlayWindow,
           overlay.buttons.contains(where: { $0.buttonType == .joystick && $0 !== self }) {
            let alert = NSAlert()
            alert.messageText = "Only One Joystick Allowed"
            alert.informativeText = "There is already a joystick button. Only one joystick can be active per profile."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // Issue 36: Cancel any pending key binding when type changes
        cancelKeyBinding()

        buttonType = type
        overlayWindow?.markNeedsSave()
    }

    @objc private func setDirection(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? JoystickDirection else { return }
        joystickDirection = dir
        overlayWindow?.markNeedsSave()
    }

    @objc private func setDistance(_ sender: NSMenuItem) {
        joystickDistance = CGFloat(sender.tag)
        overlayWindow?.markNeedsSave()
    }

    // MARK: - Actions
    @objc private func bindKeyAction() {
        startKeyBinding()
    }

    @objc private func deleteAction() {
        let alert = NSAlert()
        alert.messageText = "Delete Button?"
        alert.informativeText = "This will remove the \(keyLabel) button. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            overlayWindow?.removeButton(self)
        }
    }

    // MARK: - Key Binding
    private func startKeyBinding() {
        isWaitingForKey = true
        needsDisplay = true

        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isWaitingForKey else { return event }

            self.keyCode = event.keyCode
            self.keyLabel = Self.keyCodeToString(event.keyCode)
            self.isWaitingForKey = false
            self.needsDisplay = true
            self.overlayWindow?.markNeedsSave()

            if let monitor = self.keyMonitor {
                NSEvent.removeMonitor(monitor)
                self.keyMonitor = nil
            }

            return nil
        }
    }

    static func keyCodeToString(_ keyCode: UInt16) -> String {
        // Issue 43: Extended key code mapping including modifiers and keypad
        let keyMap: [UInt16: String] = [
            // Letters
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            // Numbers
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            // Symbols
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";",
            42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
            // Special keys
            48: "Tab", 49: "Space", 51: "Del", 53: "Esc", 36: "Enter",
            117: "FwdDel", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
            // Arrow keys
            123: "Left", 124: "Right", 125: "Down", 126: "Up",
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15",
            // Modifiers
            54: "RCmd", 55: "Cmd", 56: "Shift", 57: "Caps", 58: "Opt",
            59: "Ctrl", 60: "RShift", 61: "ROpt", 62: "RCtrl", 63: "Fn",
            // Keypad
            65: "KP.", 67: "KP*", 69: "KP+", 71: "Clear", 75: "KP/",
            76: "KPEnt", 78: "KP-", 81: "KP=",
            82: "KP0", 83: "KP1", 84: "KP2", 85: "KP3", 86: "KP4",
            87: "KP5", 88: "KP6", 89: "KP7", 91: "KP8", 92: "KP9"
        ]
        return keyMap[keyCode] ?? "[\(keyCode)]"
    }
}
