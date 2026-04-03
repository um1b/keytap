import Cocoa

/// Handles WASD drag movement with animated cursor dragging
class DragHandler {
    // MARK: - Constants
    private enum Constants {
        static let animationFPS: Double = 60.0
        static let diagonalFactor: CGFloat = 0.7071067811865476  // 1/sqrt(2)
    }

    // MARK: - Properties
    var speed: Double = 50.0
    var dragDuration: Double = 0.15

    // Callback for marking events as synthetic
    var markAsSynthetic: ((CGEvent) -> Void)?

    // WASD state
    private(set) var wPressed = false
    private(set) var aPressed = false
    private(set) var sPressed = false
    private(set) var dPressed = false

    // Drag state
    private(set) var isDragging = false
    private var dragTimer: Timer?
    private var dragStartPoint: CGPoint = .zero
    private var currentDragPoint: CGPoint = .zero
    private var targetDragPoint: CGPoint = .zero
    private var dragProgress: Double = 0.0
    private var originalCursorPosition: CGPoint?

    // Joystick drag anchor (for invisible drag zone)
    var joystickDragAnchor: CGPoint?

    // Key codes
    private let keyW: CGKeyCode = 13
    private let keyA: CGKeyCode = 0
    private let keyS: CGKeyCode = 1
    private let keyD: CGKeyCode = 2

    // Callback to clear active joysticks before drag
    var onDragStart: (() -> Void)?

    // MARK: - Public Methods

    /// Handle WASD key events for drag movement
    func handleWASDBinding(keyCode: UInt16, isKeyDown: Bool, isKeyUp: Bool) {
        // Update WASD pressed state
        switch keyCode {
        case keyW:
            if isKeyDown && !wPressed { wPressed = true }
            if isKeyUp { wPressed = false }
        case keyA:
            if isKeyDown && !aPressed { aPressed = true }
            if isKeyUp { aPressed = false }
        case keyS:
            if isKeyDown && !sPressed { sPressed = true }
            if isKeyUp { sPressed = false }
        case keyD:
            if isKeyDown && !dPressed { dPressed = true }
            if isKeyUp { dPressed = false }
        default:
            break
        }

        let isAnyPressed = wPressed || aPressed || sPressed || dPressed

        if isAnyPressed && !isDragging {
            startDrag()
        }

        if isAnyPressed && isDragging {
            updateTargetPosition()
        }

        if !isAnyPressed && isDragging {
            endDrag()
        }
    }

    /// Reset all drag state
    func reset() {
        dragTimer?.invalidate()
        dragTimer = nil

        if isDragging {
            endDrag()
        }

        wPressed = false
        aPressed = false
        sPressed = false
        dPressed = false
    }

    // MARK: - Private Methods

    private func startDrag() {
        guard !isDragging else { return }

        // Save original cursor position before drag starts
        originalCursorPosition = CGEvent(source: nil)?.location

        // Cancel any active joysticks before starting WASD drag
        onDragStart?()

        // Use joystick anchor if available, otherwise cursor position
        let dragAnchor: CGPoint
        if let anchor = joystickDragAnchor {
            dragAnchor = anchor
        } else {
            guard let currentPos = originalCursorPosition else { return }
            dragAnchor = currentPos
        }

        dragStartPoint = dragAnchor
        currentDragPoint = dragAnchor
        dragProgress = 0.0

        isDragging = true

        // Post leftMouseDown synchronously — event tap runs on main thread,
        // no need to defer. Matches ButtonActionHandler's synchronous first-event pattern.
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                   mouseCursorPosition: dragAnchor, mouseButton: .left) {
            markAsSynthetic?(mouseDown)
            mouseDown.post(tap: .cghidEventTap)
        }

        updateTargetPosition()

        let interval = 1.0 / Constants.animationFPS
        let progressPerFrame = interval / dragDuration

        dragTimer?.invalidate()
        dragTimer = nil
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.animateDrag(progressPerFrame: progressPerFrame)
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func updateTargetPosition() {
        var dx: CGFloat = 0
        var dy: CGFloat = 0

        if wPressed { dy -= CGFloat(speed) }
        if sPressed { dy += CGFloat(speed) }
        if aPressed { dx -= CGFloat(speed) }
        if dPressed { dx += CGFloat(speed) }

        if dx != 0 && dy != 0 {
            dx *= Constants.diagonalFactor
            dy *= Constants.diagonalFactor
        }

        targetDragPoint = CGPoint(x: dragStartPoint.x + dx, y: dragStartPoint.y + dy)
    }

    private func animateDrag(progressPerFrame: Double) {
        guard isDragging else {
            dragTimer?.invalidate()
            dragTimer = nil
            return
        }

        dragProgress = min(1.0, dragProgress + progressPerFrame)
        let easedProgress = easeOutQuad(dragProgress)

        let newX = dragStartPoint.x + (targetDragPoint.x - dragStartPoint.x) * easedProgress
        let newY = dragStartPoint.y + (targetDragPoint.y - dragStartPoint.y) * easedProgress

        currentDragPoint = CGPoint(x: newX, y: newY)

        if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: currentDragPoint, mouseButton: .left) {
            markAsSynthetic?(dragEvent)
            dragEvent.post(tap: .cghidEventTap)
        }
    }

    private func easeOutQuad(_ t: Double) -> CGFloat {
        return CGFloat(1.0 - (1.0 - t) * (1.0 - t))
    }

    func endDrag() {
        guard isDragging else { return }

        dragTimer?.invalidate()
        dragTimer = nil

        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentDragPoint, mouseButton: .left) {
            markAsSynthetic?(mouseUp)
            mouseUp.post(tap: .cghidEventTap)
        }

        // Restore cursor to original position (without generating events)
        if let originalPos = originalCursorPosition {
            CGWarpMouseCursorPosition(originalPos)
        }
        originalCursorPosition = nil

        isDragging = false
        dragProgress = 0.0
    }
}
