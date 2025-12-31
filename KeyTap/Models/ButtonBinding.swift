import Foundation
import CoreGraphics

// MARK: - Button Binding (runtime, used by controller)
struct ButtonBinding {
    let keyCode: UInt16
    let keyLabel: String  // Added to detect unbound buttons (keyCode=0, keyLabel="?")
    let position: CGPoint
    let buttonType: KeyButtonType
    let joystickDirection: JoystickDirection
    let joystickDistance: CGFloat
}

// MARK: - Button Binding Info (exported from overlay)
struct ButtonBindingInfo {
    let keyCode: UInt16
    let keyLabel: String
    let position: CGPoint
    let buttonType: KeyButtonType
    let joystickDirection: JoystickDirection
    let joystickDistance: CGFloat
}

