import Cocoa

protocol OverlayWindowDelegate: AnyObject {
    func overlayWindowDidExitEditMode(_ window: OverlayWindow)
}

class OverlayWindow: NSWindow {
    // MARK: - Public Properties
    var buttons: [ClickButton] = []
    var targetBundleId: String? {
        didSet {
            if targetBundleId != oldValue {
                // Save profile for the previous target before loading new one
                if let previousBundleId = oldValue {
                    saveProfileForBundleId(previousBundleId)
                }
                loadProfile()
            }
        }
    }
    var isEditMode: Bool = false {
        didSet {
            updateEditMode()
        }
    }

    // MARK: - Private Properties
    private var trackingTimer: Timer?
    private var editToolbar: NSView?
    private var selectedButton: ClickButton?
    private var autoSaveTimer: Timer?
    private var needsAutoSave = false

    // Constants
    private let trackingTimerInterval: TimeInterval = 0.05

    // Delegate for edit mode changes
    weak var editDelegate: OverlayWindowDelegate?

    private var configFileURL: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("KeyTap-profiles.json")
        }
        let keyTapDir = appSupport.appendingPathComponent("KeyTap", isDirectory: true)
        try? FileManager.default.createDirectory(at: keyTapDir, withIntermediateDirectories: true)
        return keyTapDir.appendingPathComponent("profiles.json")
    }

    // MARK: - Initialization
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        setupWindow()
    }

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    deinit {
        stopTracking()
        stopAutoSave()
        buttons.forEach { $0.cancelKeyBinding() }
    }

    private func setupWindow() {
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        hasShadow = false

        let contentView = NSView(frame: frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = .clear
        self.contentView = contentView
    }

    // MARK: - Window Tracking
    func startTracking() {
        trackingTimer?.invalidate()
        let timer = Timer(timeInterval: trackingTimerInterval, repeats: true) { [weak self] _ in
            self?.updatePositionToTargetApp()
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    @discardableResult
    func updatePositionToTargetApp() -> Bool {
        guard let targetId = targetBundleId else { return false }

        // Check if target app is hidden or minimized
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased() == targetId.lowercased()
        }) {
            if app.isHidden {
                return false  // App is hidden, don't show overlay
            }
        }

        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for windowInfo in windowInfoList {
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }

            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: ownerPID),
                  let appBundleId = app.bundleIdentifier,
                  appBundleId.lowercased() == targetId.lowercased(),
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            let width = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0

            // Skip windows that are too small (likely minimized or accessory windows)
            if width < 100 || height < 100 { continue }

            // Skip windows positioned off-screen (likely minimized to dock)
            let maxScreenX = NSScreen.screens.map { $0.frame.maxX }.max() ?? 0
            let maxScreenY = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
            if x > maxScreenX || y > maxScreenY || x + width < 0 || y + height < 0 {
                continue
            }

            let windowRect = NSRect(x: x, y: y, width: width, height: height)
            let screen = NSScreen.screens.first { NSIntersectsRect($0.frame, windowRect) } ?? NSScreen.main
            let screenHeight = screen?.frame.height ?? 0
            let cocoaY = screenHeight - y - height
            let newFrame = NSRect(x: x, y: cocoaY, width: width, height: height)

            if self.frame != newFrame {
                let oldSize = self.frame.size
                self.setFrame(newFrame, display: false)

                if oldSize != newFrame.size && oldSize.width > 0 && oldSize.height > 0 {
                    repositionButtonsForNewSize(oldSize: oldSize, newSize: newFrame.size)
                }
            }
            return true
        }

        return false
    }

    private func repositionButtonsForNewSize(oldSize: CGSize, newSize: CGSize) {
        guard oldSize.width > 0 && oldSize.height > 0 else { return }
        for button in buttons {
            let relX = (button.frame.midX) / oldSize.width
            let relY = (button.frame.midY) / oldSize.height
            let newX = relX * newSize.width - button.frame.width / 2
            let newY = relY * newSize.height - button.frame.height / 2
            button.frame.origin = CGPoint(x: newX, y: newY)
        }
    }

    // MARK: - Edit Mode
    private func updateEditMode() {
        if isEditMode {
            ignoresMouseEvents = false
            backgroundColor = NSColor.black.withAlphaComponent(0.15)
            contentView?.layer?.borderColor = NSColor.systemBlue.cgColor
            contentView?.layer?.borderWidth = 2
            setupEditToolbar()
            makeKeyAndOrderFront(nil)
            startAutoSave()
        } else {
            ignoresMouseEvents = true
            backgroundColor = .clear
            contentView?.layer?.borderColor = nil
            contentView?.layer?.borderWidth = 0
            removeEditToolbar()
            deselectAllButtons()
            // Cancel any pending key binding operations on all buttons
            buttons.forEach { $0.cancelKeyBinding() }
            stopAutoSave()
            // Final save on exit
            if needsAutoSave {
                saveProfile()
                needsAutoSave = false
            }
        }

        buttons.forEach { $0.setEditMode(isEditMode) }
    }

    // MARK: - Auto-Save
    private func startAutoSave() {
        stopAutoSave()
        // Auto-save every 2 seconds if there are unsaved changes (Issue 38: reduced from 5s)
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard self.needsAutoSave else { return }
            self.saveProfile()
            self.needsAutoSave = false
        }
    }

    private func stopAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
    }

    /// Call this when buttons are modified to trigger auto-save
    func markNeedsSave() {
        needsAutoSave = true
    }

    private func setupEditToolbar() {
        removeEditToolbar()

        let toolbarHeight: CGFloat = 36
        let toolbar = NSView(frame: NSRect(x: 0, y: frame.height - toolbarHeight, width: frame.width, height: toolbarHeight))
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        toolbar.autoresizingMask = [.width, .minYMargin]

        // Add button
        let addButton = NSButton(frame: NSRect(x: 10, y: 6, width: 60, height: 24))
        addButton.title = "+ Add"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addButtonAtCenter)
        toolbar.addSubview(addButton)

        // Add Joystick button (single button now)
        let joystickButton = NSButton(frame: NSRect(x: 75, y: 6, width: 90, height: 24))
        joystickButton.title = "+ Joystick"
        joystickButton.bezelStyle = .rounded
        joystickButton.target = self
        joystickButton.action = #selector(addJoystickButton)
        toolbar.addSubview(joystickButton)

        // Done button
        let doneButton = NSButton(frame: NSRect(x: frame.width - 80, y: 6, width: 70, height: 24))
        doneButton.title = "Done"
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(exitEditMode)
        doneButton.autoresizingMask = [.minXMargin]
        toolbar.addSubview(doneButton)

        // Help label with keyboard shortcuts
        let helpLabel = NSTextField(labelWithString: "Dbl-click: bind  |  Right-click: menu  |  N: add  |  J: joystick  |  Del: delete  |  Esc: done")
        helpLabel.font = NSFont.systemFont(ofSize: 9)
        helpLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        helpLabel.frame = NSRect(x: 170, y: 10, width: frame.width - 260, height: 16)
        helpLabel.autoresizingMask = [.width]
        toolbar.addSubview(helpLabel)

        contentView?.addSubview(toolbar)
        self.editToolbar = toolbar
    }

    private func removeEditToolbar() {
        editToolbar?.removeFromSuperview()
        editToolbar = nil
    }

    @objc private func addButtonAtCenter() {
        let toolbarHeight: CGFloat = isEditMode ? 36 : 0
        // Toolbar is at top, so center is in the remaining area below it
        let center = CGPoint(x: frame.width / 2, y: (frame.height - toolbarHeight) / 2)
        let button = addButton(at: center)
        selectButton(button)
    }

    @objc private func addJoystickButton() {
        // Check if joystick already exists
        if buttons.contains(where: { $0.buttonType == .joystick }) {
            let alert = NSAlert()
            alert.messageText = "Only One Joystick Allowed"
            alert.informativeText = "There is already a joystick button. Only one joystick can be active per profile."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let toolbarHeight: CGFloat = isEditMode ? 36 : 0
        // Toolbar is at top, so center is in the remaining area below it
        let center = CGPoint(x: frame.width / 2, y: (frame.height - toolbarHeight) / 2)

        // Joystick uses larger size for two circles
        let size: CGFloat = 64
        let button = ClickButton(frame: NSRect(x: center.x - size/2, y: center.y - size/2, width: size, height: size))
        button.overlayWindow = self
        contentView?.addSubview(button)
        buttons.append(button)
        button.setEditMode(isEditMode)
        button.buttonType = .joystick
        button.joystickDirection = .up  // Default direction
        button.joystickDistance = 50.0
        selectButton(button)
    }

    @objc func exitEditMode() {
        saveProfile()
        isEditMode = false
        editDelegate?.overlayWindowDidExitEditMode(self)
    }

    // MARK: - Button Selection
    func selectButton(_ button: ClickButton?) {
        selectedButton?.isSelected = false
        selectedButton = button
        selectedButton?.isSelected = true
    }

    func deselectAllButtons() {
        selectedButton?.isSelected = false
        selectedButton = nil
    }

    private func deleteSelectedButton() {
        guard let button = selectedButton else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Button?"
        alert.informativeText = "This will remove the \(button.keyLabel) button. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            removeButton(button)
            selectedButton = nil
        }
    }

    private func setSelectedButtonType(_ typeIndex: Int) {
        guard let button = selectedButton else { return }
        let types = KeyButtonType.allCases
        guard typeIndex >= 0 && typeIndex < types.count else { return }

        let newType = types[typeIndex]
        // Check joystick limit
        if newType == .joystick && buttons.contains(where: { $0.buttonType == .joystick && $0 !== button }) {
            return
        }
        button.buttonType = newType
    }

    // MARK: - Keyboard Handling
    override var canBecomeKey: Bool { isEditMode }

    override func keyDown(with event: NSEvent) {
        guard isEditMode else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 53: // Escape
            exitEditMode()
        case 51, 117: // Delete, Forward Delete
            deleteSelectedButton()
        case 45: // N
            addButtonAtCenter()
        case 38: // J - Add Joystick
            addJoystickButton()
        case 18: // 1 - Click
            setSelectedButtonType(0)
        case 19: // 2 - Hold
            setSelectedButtonType(1)
        case 20: // 3 - Joystick
            setSelectedButtonType(2)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Button Management
    func addButton(at point: CGPoint) -> ClickButton {
        let size: CGFloat = 44
        let button = ClickButton(frame: NSRect(x: point.x - size/2, y: point.y - size/2, width: size, height: size))
        button.overlayWindow = self
        contentView?.addSubview(button)
        buttons.append(button)
        button.setEditMode(isEditMode)
        markNeedsSave()
        return button
    }

    func removeButton(_ button: ClickButton) {
        button.cancelKeyBinding()
        button.removeFromSuperview()
        buttons.removeAll { $0 === button }
        markNeedsSave()
    }

    // MARK: - Profile Persistence
    func saveProfile() {
        guard let bundleId = targetBundleId else { return }
        saveProfileForBundleId(bundleId)
    }

    private func saveProfileForBundleId(_ bundleId: String) {
        let windowSize = frame.size
        guard windowSize.width > 0 && windowSize.height > 0 else { return }

        let buttonConfigs: [ButtonConfig] = buttons.map { button in
            let centerX = button.frame.midX
            let centerY = button.frame.midY
            return ButtonConfig(
                keyCode: button.keyCode,
                keyLabel: button.keyLabel,
                relativeX: centerX / windowSize.width,
                relativeY: centerY / windowSize.height,
                buttonType: button.buttonType,
                joystickDirection: button.joystickDirection,
                joystickDistance: button.joystickDistance
            )
        }

        let profile = ProfileConfig(bundleId: bundleId, buttons: buttonConfigs)

        var profiles = loadAllProfiles()
        profiles.removeAll { $0.bundleId == bundleId }
        profiles.append(profile)

        do {
            // Issue 39: Check file permissions before writing
            let fileManager = FileManager.default
            let directory = configFileURL.deletingLastPathComponent()

            // Ensure directory exists
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            // Check if we can write to directory
            guard fileManager.isWritableFile(atPath: directory.path) else {
                NSLog("KeyTap: Cannot write to profile directory: \(directory.path)")
                return
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(profiles)
            try data.write(to: configFileURL, options: .atomic)
        } catch {
            NSLog("KeyTap: Failed to save profile: \(error.localizedDescription)")
        }
    }

    func loadProfile() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        guard let bundleId = targetBundleId else { return }

        let profiles = loadAllProfiles()
        guard let profile = profiles.first(where: { $0.bundleId == bundleId }) else {
            return
        }

        updatePositionToTargetApp()
        let windowSize = frame.size
        // Issue 21: Require minimum window size to load buttons properly
        guard windowSize.width > 50 && windowSize.height > 50 else { return }

        for config in profile.buttons {
            // Clamp relative values to [0, 1] to handle corrupted data
            let clampedRelX = max(0, min(1, config.relativeX))
            let clampedRelY = max(0, min(1, config.relativeY))
            let x = clampedRelX * windowSize.width
            let y = clampedRelY * windowSize.height

            // Use larger size for joystick buttons
            let size: CGFloat = config.buttonType == .joystick ? 64 : 44
            let button = ClickButton(frame: NSRect(x: x - size/2, y: y - size/2, width: size, height: size))
            button.overlayWindow = self
            contentView?.addSubview(button)
            buttons.append(button)
            button.setEditMode(isEditMode)

            button.keyCode = config.keyCode
            button.keyLabel = config.keyLabel
            button.buttonType = config.buttonType
            button.joystickDirection = config.joystickDirection ?? .up
            button.joystickDistance = config.joystickDistance
        }
    }

    private func loadAllProfiles() -> [ProfileConfig] {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: configFileURL)
            let profiles = try JSONDecoder().decode([ProfileConfig].self, from: data)

            // Validate loaded profiles
            return profiles.map { profile in
                let validatedButtons = profile.buttons.compactMap { config -> ButtonConfig? in
                    // Validate key code is in reasonable range (0-127 for standard keys)
                    guard config.keyCode <= 127 else {
                        NSLog("KeyTap: Invalid keyCode \(config.keyCode) in profile, skipping button")
                        return nil
                    }

                    // Validate distance is positive
                    let validatedDistance = max(10.0, min(500.0, config.joystickDistance))

                    return ButtonConfig(
                        keyCode: config.keyCode,
                        keyLabel: config.keyLabel,
                        relativeX: max(0, min(1, config.relativeX)),
                        relativeY: max(0, min(1, config.relativeY)),
                        buttonType: config.buttonType,
                        joystickDirection: config.joystickDirection,
                        joystickDistance: validatedDistance
                    )
                }
                return ProfileConfig(bundleId: profile.bundleId, buttons: validatedButtons)
            }
        } catch {
            NSLog("KeyTap: Failed to load profiles: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Button Bindings Export
    func getButtonBindings() -> [ButtonBindingInfo] {
        let windowFrame = frame
        let screen = NSScreen.screens.first { NSIntersectsRect($0.frame, windowFrame) } ?? NSScreen.main
        let screenHeight = screen?.frame.height ?? 0

        return buttons.map { button in
            let centerInWindow = CGPoint(x: button.frame.midX, y: button.frame.midY)
            let screenX = windowFrame.origin.x + centerInWindow.x
            let screenY = screenHeight - (windowFrame.origin.y + centerInWindow.y)

            return ButtonBindingInfo(
                keyCode: button.keyCode,
                keyLabel: button.keyLabel,
                position: CGPoint(x: screenX, y: screenY),
                buttonType: button.buttonType,
                joystickDirection: button.joystickDirection,
                joystickDistance: button.joystickDistance
            )
        }
    }
}
