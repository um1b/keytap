import Foundation
import CoreGraphics

// MARK: - Button Configuration (for persistence)
struct ButtonConfig: Codable {
    var keyCode: UInt16
    var keyLabel: String
    var relativeX: CGFloat
    var relativeY: CGFloat
    var buttonType: KeyButtonType
    var joystickDirection: JoystickDirection?
    var joystickDistance: CGFloat

    init(keyCode: UInt16 = 0, keyLabel: String = "?", relativeX: CGFloat = 0.5, relativeY: CGFloat = 0.5,
         buttonType: KeyButtonType = .click, joystickDirection: JoystickDirection? = nil, joystickDistance: CGFloat = 50) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.relativeX = relativeX
        self.relativeY = relativeY
        self.buttonType = buttonType
        self.joystickDirection = joystickDirection
        self.joystickDistance = joystickDistance
    }
}

// MARK: - Profile Configuration
struct ProfileConfig: Codable {
    // Issue 27: Schema versioning for future migration support
    static let currentVersion: Int = 1

    var version: Int
    var bundleId: String
    var buttons: [ButtonConfig]

    init(bundleId: String, buttons: [ButtonConfig]) {
        self.version = Self.currentVersion
        self.bundleId = bundleId
        self.buttons = buttons
    }

    // Custom decoding to handle older profiles without version field
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.bundleId = try container.decode(String.self, forKey: .bundleId)
        self.buttons = try container.decode([ButtonConfig].self, forKey: .buttons)
    }
}
