import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Constants
    private let overlayTrackingInterval: TimeInterval = 0.1

    // MARK: - UserDefaults Keys
    private enum DefaultsKey {
        static let isEnabled = "KeyTap.isEnabled"
        static let targetBundleId = "KeyTap.targetBundleId"
        static let isOverlayEnabled = "KeyTap.isOverlayEnabled"
        static let speed = "KeyTap.speed"
    }

    // MARK: - Properties
    private var statusItem: NSStatusItem!
    private var keyTapController: KeyTapController!
    private var overlayWindow: OverlayWindow!
    private var overlayTrackingTimer: Timer?
    private var isOverlayEnabled = false

    // Menu items that need state updates
    private var enableMenuItem: NSMenuItem!
    private var targetAppMenuItem: NSMenuItem!
    private var runningAppsMenuItem: NSMenuItem!
    private var overlayMenuItem: NSMenuItem!
    private var editModeMenuItem: NSMenuItem!
    private var showOverlayMenuItem: NSMenuItem!

    // MARK: - App Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayWindow = OverlayWindow()
        overlayWindow.editDelegate = self
        keyTapController = KeyTapController()
        keyTapController.speed = 50.0
        keyTapController.overlayWindow = overlayWindow

        setupStatusItem()
        setupMenu()

        // Restore saved state
        restoreState()

        // Watch for target app termination
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Watch for app activation to re-enable event tap (fixes first keypress issue)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Watch for app deactivation to immediately update overlay and reset state
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidDeactivate(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save state before quitting
        saveState()

        // Remove observer to prevent memory leaks
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        // Save profile if in edit mode to prevent data loss
        if overlayWindow.isEditMode {
            overlayWindow.saveProfile()
        }
        keyTapController.stop()
        overlayWindow.stopTracking()
        stopOverlayTracking()
    }

    deinit {
        // Observer removal already done in applicationWillTerminate
        // Keep only stopOverlayTracking as safety cleanup
        stopOverlayTracking()
    }

    // MARK: - State Persistence
    private func saveState() {
        let defaults = UserDefaults.standard
        defaults.set(enableMenuItem.state == .on, forKey: DefaultsKey.isEnabled)
        defaults.set(keyTapController.targetBundleId, forKey: DefaultsKey.targetBundleId)
        defaults.set(isOverlayEnabled, forKey: DefaultsKey.isOverlayEnabled)
        defaults.set(keyTapController.speed, forKey: DefaultsKey.speed)
    }

    private func restoreState() {
        let defaults = UserDefaults.standard

        // Restore speed (with default)
        let speed = defaults.double(forKey: DefaultsKey.speed)
        if speed > 0 {
            keyTapController.speed = speed
            updateSpeedMenuState(speed: speed)
        }

        // Restore target app
        if let bundleId = defaults.string(forKey: DefaultsKey.targetBundleId) {
            keyTapController.targetBundleId = bundleId
            overlayWindow.targetBundleId = bundleId
            updateTargetAppDisplay(bundleId: bundleId)
            updateTargetMenuStates(selectedBundleId: bundleId)
        }

        // Restore overlay visibility
        if defaults.bool(forKey: DefaultsKey.isOverlayEnabled) {
            isOverlayEnabled = true
            showOverlayMenuItem.title = "Hide Buttons"
            startOverlayTracking()
            updateOverlayVisibility()
        }

        // Restore enabled state (do this last so bindings are ready)
        if defaults.bool(forKey: DefaultsKey.isEnabled) {
            if keyTapController.start() {
                enableMenuItem.state = .on
                enableMenuItem.title = "Disable WASD Mode"
                updateStatusIcon(enabled: true)
            }
        }
    }

    private func updateSpeedMenuState(speed: Double) {
        guard let overlayMenu = overlayMenuItem.submenu,
              let speedItem = overlayMenu.items.first(where: { $0.title == "WASD Drag Distance" }),
              let speedMenu = speedItem.submenu else { return }

        for item in speedMenu.items {
            item.state = (Double(item.tag) == speed) ? .on : .off
        }
    }

    // MARK: - Overlay Tracking (continuous, outside edit mode)
    private func startOverlayTracking() {
        stopOverlayTracking()
        let timer = Timer(timeInterval: overlayTrackingInterval, repeats: true) { [weak self] _ in
            self?.updateOverlayVisibility()
        }
        RunLoop.main.add(timer, forMode: .common)
        overlayTrackingTimer = timer
    }

    private func stopOverlayTracking() {
        overlayTrackingTimer?.invalidate()
        overlayTrackingTimer = nil
    }

    private func updateOverlayVisibility() {
        guard isOverlayEnabled, !overlayWindow.isEditMode else { return }
        guard let targetId = keyTapController.targetBundleId else {
            // All Apps mode - hide overlay (no specific window to track)
            if overlayWindow.isVisible {
                overlayWindow.orderOut(nil)
            }
            return
        }

        // Check if target app is frontmost
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() == targetId.lowercased()

        if isFrontmost {
            let found = overlayWindow.updatePositionToTargetApp()
            if found {
                if !overlayWindow.isVisible {
                    overlayWindow.orderFront(nil)
                }
            } else {
                // Target app frontmost but window not found
                if overlayWindow.isVisible {
                    overlayWindow.orderOut(nil)
                }
            }
        } else {
            // Target app not frontmost - hide overlay
            if overlayWindow.isVisible {
                overlayWindow.orderOut(nil)
            }
        }
    }

    // MARK: - Status Item Setup
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(enabled: false)
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Enable/Disable
        enableMenuItem = NSMenuItem(title: "Enable WASD Mode", action: #selector(toggleEnabled(_:)), keyEquivalent: "e")
        enableMenuItem.state = .off
        menu.addItem(enableMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Target App submenu
        let targetMenu = NSMenu()

        let allAppsItem = NSMenuItem(title: "All Apps (buttons hidden)", action: #selector(setTargetApp(_:)), keyEquivalent: "")
        allAppsItem.state = .on
        allAppsItem.representedObject = nil
        targetMenu.addItem(allAppsItem)

        targetMenu.addItem(NSMenuItem.separator())

        runningAppsMenuItem = NSMenuItem(title: "Running Apps", action: nil, keyEquivalent: "")
        runningAppsMenuItem.submenu = NSMenu()
        targetMenu.addItem(runningAppsMenuItem)

        targetMenu.addItem(NSMenuItem.separator())

        let customItem = NSMenuItem(title: "Choose App...", action: #selector(chooseCustomApp), keyEquivalent: "")
        targetMenu.addItem(customItem)

        targetAppMenuItem = NSMenuItem(title: "Target: All Apps", action: nil, keyEquivalent: "")
        targetAppMenuItem.submenu = targetMenu
        menu.addItem(targetAppMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Buttons submenu
        let overlayMenu = NSMenu()

        showOverlayMenuItem = NSMenuItem(title: "Show Buttons", action: #selector(toggleOverlay(_:)), keyEquivalent: "")
        overlayMenu.addItem(showOverlayMenuItem)

        editModeMenuItem = NSMenuItem(title: "Edit Buttons...", action: #selector(toggleEditMode(_:)), keyEquivalent: "")
        overlayMenu.addItem(editModeMenuItem)

        overlayMenu.addItem(NSMenuItem.separator())

        // WASD Drag Distance submenu
        let speedMenu = NSMenu()
        let distances: [(String, Double)] = [
            ("Small (25px)", 25.0),
            ("Medium (50px)", 50.0),
            ("Large (100px)", 100.0),
            ("Very Large (150px)", 150.0)
        ]
        for (title, value) in distances {
            let item = NSMenuItem(title: title, action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.tag = Int(value)
            item.state = value == 50.0 ? .on : .off
            speedMenu.addItem(item)
        }
        let speedMenuItem = NSMenuItem(title: "WASD Drag Distance", action: nil, keyEquivalent: "")
        speedMenuItem.submenu = speedMenu
        overlayMenu.addItem(speedMenuItem)

        overlayMenuItem = NSMenuItem(title: "Buttons", action: nil, keyEquivalent: "")
        overlayMenuItem.submenu = overlayMenu
        menu.addItem(overlayMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit KeyTap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        menu.delegate = self
    }

    // MARK: - Enable/Disable
    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        if sender.state == .off {
            if keyTapController.start() {
                sender.state = .on
                sender.title = "Disable WASD Mode"
                updateStatusIcon(enabled: true)
            } else {
                // Show error if failed to start
                let alert = NSAlert()
                alert.messageText = "Cannot Enable WASD Mode"
                alert.informativeText = "Accessibility permission is required. Go to System Settings > Privacy & Security > Accessibility and enable KeyTap."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        } else {
            keyTapController.stop()
            sender.state = .off
            sender.title = "Enable WASD Mode"
            updateStatusIcon(enabled: false)
        }
    }

    private func updateStatusIcon(enabled: Bool) {
        if let button = statusItem.button {
            if enabled {
                button.title = "🎮"  // Enabled - game controller
            } else {
                button.title = "🖱️"  // Disabled - mouse
            }
        }
    }

    // MARK: - Edit Mode
    @objc private func toggleEditMode(_ sender: NSMenuItem) {
        if overlayWindow.isEditMode {
            // Exit edit mode
            overlayWindow.exitEditMode()
        } else {
            // Enter edit mode
            stopOverlayTracking()
            overlayWindow.targetBundleId = keyTapController.targetBundleId
            overlayWindow.updatePositionToTargetApp()
            overlayWindow.startTracking()
            overlayWindow.isEditMode = true
            editModeMenuItem.title = "Done Editing"
        }
    }

    private func handleEditModeExit() {
        overlayWindow.stopTracking()
        overlayWindow.deselectAllButtons()
        editModeMenuItem.title = "Edit Buttons..."
        keyTapController.updateButtonBindings()
        overlayWindow.orderOut(nil)
        if isOverlayEnabled {
            startOverlayTracking()
            updateOverlayVisibility()
        }
    }

    @objc private func toggleOverlay(_ sender: NSMenuItem) {
        isOverlayEnabled.toggle()

        if isOverlayEnabled {
            sender.title = "Hide Buttons"
            startOverlayTracking()
            // Immediately check visibility
            updateOverlayVisibility()
        } else {
            sender.title = "Show Buttons"
            stopOverlayTracking()
            overlayWindow.orderOut(nil)
        }
    }

    // MARK: - Target App Selection
    @objc private func setTargetApp(_ sender: NSMenuItem) {
        let bundleId = sender.representedObject as? String
        keyTapController.targetBundleId = bundleId
        overlayWindow.targetBundleId = bundleId
        overlayWindow.updatePositionToTargetApp()
        keyTapController.updateButtonBindings()

        updateTargetAppDisplay(bundleId: bundleId)
        updateTargetMenuStates(selectedBundleId: bundleId)
    }

    @objc private func chooseCustomApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Select an application to target"

        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier {
                keyTapController.targetBundleId = bundleId
                overlayWindow.targetBundleId = bundleId
                overlayWindow.updatePositionToTargetApp()
                keyTapController.updateButtonBindings()

                let appName = bundle.infoDictionary?["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                targetAppMenuItem.title = "Target: \(appName)"

                updateTargetMenuStates(selectedBundleId: bundleId)
            }
        }
    }

    private func updateTargetAppDisplay(bundleId: String?) {
        if let bundleId = bundleId {
            let appName = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == bundleId }?.localizedName ?? bundleId
            targetAppMenuItem.title = "Target: \(appName)"
        } else {
            targetAppMenuItem.title = "Target: All Apps (buttons hidden)"
        }
    }

    private func updateTargetMenuStates(selectedBundleId: String?) {
        if let targetMenu = targetAppMenuItem.submenu {
            for item in targetMenu.items where item.action == #selector(setTargetApp(_:)) {
                item.state = (item.representedObject as? String) == selectedBundleId ? .on : .off
            }
        }

        if let runningMenu = runningAppsMenuItem.submenu {
            for item in runningMenu.items {
                item.state = (item.representedObject as? String) == selectedBundleId ? .on : .off
            }
        }
    }

    private func updateRunningApps() {
        guard let submenu = runningAppsMenuItem.submenu else { return }
        submenu.removeAllItems()

        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.localizedName != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        for app in runningApps {
            guard let name = app.localizedName, let bundleId = app.bundleIdentifier else { continue }
            let item = NSMenuItem(title: name, action: #selector(setTargetApp(_:)), keyEquivalent: "")
            item.representedObject = bundleId
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            item.state = (keyTapController.targetBundleId == bundleId) ? .on : .off
            submenu.addItem(item)
        }
    }

    // MARK: - Speed
    @objc private func setSpeed(_ sender: NSMenuItem) {
        let speed = Double(sender.tag)
        keyTapController.speed = speed

        // Update checkmarks in parent menu
        if let menu = sender.menu {
            for item in menu.items {
                item.state = (item.tag == sender.tag) ? .on : .off
            }
        }
    }

    // MARK: - App Observers
    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else {
            return
        }

        // Check if this is the target app
        if let targetId = keyTapController.targetBundleId,
           bundleId.lowercased() == targetId.lowercased() {
            // Target app activated - update overlay
            if isOverlayEnabled && !overlayWindow.isEditMode {
                overlayWindow.updatePositionToTargetApp()
                overlayWindow.orderFront(nil)
            }
            keyTapController.setTargetFrontmost(true)
            keyTapController.updateButtonBindings()
        }
    }

    @objc private func appDidDeactivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else {
            return
        }

        // If target app just lost focus, reset controller state
        if let targetId = keyTapController.targetBundleId,
           bundleId.lowercased() == targetId.lowercased() {
            // Target app deactivated - immediately hide overlay
            if !overlayWindow.isEditMode {
                overlayWindow.orderOut(nil)
            }
            keyTapController.setTargetFrontmost(false)
            keyTapController.resetAllState()
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier,
              bundleId == keyTapController.targetBundleId else {
            return
        }

        // Target app was closed, switch to All Apps
        keyTapController.targetBundleId = nil
        overlayWindow.targetBundleId = nil
        updateTargetAppDisplay(bundleId: nil)
        updateTargetMenuStates(selectedBundleId: nil)

        if overlayWindow.isEditMode {
            overlayWindow.exitEditMode()
        }

        // Hide overlay since no target app
        overlayWindow.orderOut(nil)
    }
}

// MARK: - NSMenuDelegate
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateRunningApps()

        // Update button menu item state
        showOverlayMenuItem.title = isOverlayEnabled ? "Hide Buttons" : "Show Buttons"
        editModeMenuItem.title = overlayWindow.isEditMode ? "Done Editing" : "Edit Buttons..."
    }
}

// MARK: - OverlayWindowDelegate
extension AppDelegate: OverlayWindowDelegate {
    func overlayWindowDidExitEditMode(_ window: OverlayWindow) {
        handleEditModeExit()
    }
}
