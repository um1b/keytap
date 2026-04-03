import Foundation
import CoreGraphics

// MARK: - Button Binding (runtime, used by controller and overlay)
struct ButtonBinding {
    let keyCode: UInt16
    let keyLabel: String
    let position: CGPoint
    let buttonType: KeyButtonType
    let joystickDirection: JoystickDirection
    let joystickDistance: CGFloat
    let clicksPerSecond: Int
}
