import Foundation
import CoreGraphics

// MARK: - Button Type
enum KeyButtonType: String, Codable, CaseIterable {
    case click = "click"           // Single click on press
    case hold = "hold"             // Hold while key held
    case joystick = "joystick"     // Drag from center in direction

    var displayName: String {
        switch self {
        case .click: return "Click"
        case .hold: return "Hold"
        case .joystick: return "Joystick"
        }
    }

    var icon: String {
        switch self {
        case .click: return "●"
        case .hold: return "◆"
        case .joystick: return "◎"
        }
    }
}

// MARK: - Joystick Direction
enum JoystickDirection: String, Codable, CaseIterable {
    case up = "up"
    case down = "down"
    case left = "left"
    case right = "right"
    case upLeft = "upLeft"
    case upRight = "upRight"
    case downLeft = "downLeft"
    case downRight = "downRight"

    var displayName: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .upLeft: return "Up-Left"
        case .upRight: return "Up-Right"
        case .downLeft: return "Down-Left"
        case .downRight: return "Down-Right"
        }
    }

    var icon: String {
        switch self {
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .upLeft: return "↖"
        case .upRight: return "↗"
        case .downLeft: return "↙"
        case .downRight: return "↘"
        }
    }

    var delta: (dx: CGFloat, dy: CGFloat) {
        switch self {
        case .up: return (0, -1)
        case .down: return (0, 1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        case .upLeft: return (-0.707, -0.707)
        case .upRight: return (0.707, -0.707)
        case .downLeft: return (-0.707, 0.707)
        case .downRight: return (0.707, 0.707)
        }
    }
}
