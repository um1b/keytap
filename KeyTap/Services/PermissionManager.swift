import Cocoa
import ApplicationServices

/// Manages accessibility permissions for KeyTap
final class PermissionManager {
    // MARK: - Singleton
    static let shared = PermissionManager()

    // MARK: - Constants
    private static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    // MARK: - Properties
    private(set) var isAccessibilityGranted: Bool = false

    // MARK: - Initialization
    private init() {
        updatePermissionStatus()
    }

    // MARK: - Permission Checking

    /// Updates the cached permission status
    @discardableResult
    func updatePermissionStatus() -> Bool {
        isAccessibilityGranted = AXIsProcessTrusted()
        return isAccessibilityGranted
    }

    /// Checks if accessibility is granted, optionally prompting the user
    func checkAccessibility(prompt: Bool = false) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            isAccessibilityGranted = AXIsProcessTrustedWithOptions(options)
        } else {
            isAccessibilityGranted = AXIsProcessTrusted()
        }
        return isAccessibilityGranted
    }

    // MARK: - System Settings

    /// Opens System Settings to the Accessibility privacy pane
    func openAccessibilitySettings() {
        if let url = Self.accessibilitySettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Alerts

    /// Shows an alert explaining that accessibility permission is required
    func showPermissionRequiredAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            KeyTap needs Accessibility permission to capture keyboard input.

            1. Click 'Open System Settings'
            2. Enable KeyTap in the list
            3. Restart KeyTap
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    /// Shows an alert displaying the current permission status
    func showPermissionStatusAlert() {
        NSApp.activate(ignoringOtherApps: true)
        updatePermissionStatus()

        let alert = NSAlert()
        if isAccessibilityGranted {
            alert.messageText = "Permission Granted"
            alert.informativeText = "Accessibility permission is enabled. KeyTap is ready to use."
            alert.alertStyle = .informational
            alert.runModal()
        } else {
            alert.messageText = "Permission Required"
            alert.informativeText = """
                KeyTap needs Accessibility permission.

                1. Open System Settings
                2. Go to Privacy & Security > Accessibility
                3. Enable KeyTap
                4. Restart KeyTap if needed
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            if alert.runModal() == .alertFirstButtonReturn {
                openAccessibilitySettings()
            }
        }
    }
}
