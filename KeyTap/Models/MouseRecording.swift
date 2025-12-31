import Foundation
import CoreGraphics

// Event type for recording
enum MouseRecordingEventType: String, Codable {
    case mouseMove
    case mouseDown
    case mouseUp
    case mouseDrag
}

// Single recorded event
struct MouseRecordingEvent: Codable {
    let type: MouseRecordingEventType
    let position: CGPoint
    let timestamp: TimeInterval  // Relative to recording start
}

// Complete recording
struct MouseRecording: Codable {
    var name: String
    var events: [MouseRecordingEvent]
    var duration: TimeInterval
}
