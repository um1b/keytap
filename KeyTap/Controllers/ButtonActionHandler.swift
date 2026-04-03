import Cocoa

/// Handles button click, hold, joystick, and rapid-click actions
class ButtonActionHandler {
    // MARK: - Constants
    private enum Constants {
        static let animationFPS: Double = 60.0
        static let joystickDuration: Double = 0.12
        static let clickDelay: TimeInterval = 0.008
        static let joystickStartDelay: TimeInterval = 0.005
    }

    // MARK: - Properties

    // Callback for marking events as synthetic
    var markAsSynthetic: ((CGEvent) -> Void)?

    // Active state tracking
    private(set) var activeButtonClicks: Set<UInt16> = []
    private(set) var activeJoysticks: [UInt16: (timer: Timer, binding: ButtonBinding)] = [:]
    private(set) var activeRapidClicks: [UInt16: Timer] = [:]

    // MARK: - Public Methods

    /// Handle button binding events
    func handleButtonBinding(binding: ButtonBinding, keyCode: UInt16, isKeyDown: Bool, isKeyUp: Bool) {
        switch binding.buttonType {
        case .click:
            if isKeyDown && !activeButtonClicks.contains(keyCode) {
                performClickAction(at: binding.position)
                activeButtonClicks.insert(keyCode)
            }
            if isKeyUp {
                activeButtonClicks.remove(keyCode)
            }

        case .hold:
            if isKeyDown && !activeButtonClicks.contains(keyCode) {
                performClick(at: binding.position)
                activeButtonClicks.insert(keyCode)
            }
            if isKeyUp {
                releaseClick(at: binding.position)
                activeButtonClicks.remove(keyCode)
            }

        case .joystick:
            if isKeyDown && activeJoysticks[keyCode] == nil {
                startJoystick(binding: binding, keyCode: keyCode)
            }
            if isKeyUp {
                stopJoystick(keyCode: keyCode)
            }

        case .rapidClick:
            if isKeyDown && activeRapidClicks[keyCode] == nil {
                let interval = 1.0 / Double(binding.clicksPerSecond)
                performClickAction(at: binding.position)  // Immediate first click
                let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    self?.performClickAction(at: binding.position)
                }
                activeRapidClicks[keyCode] = timer
            }
            if isKeyUp {
                activeRapidClicks[keyCode]?.invalidate()
                activeRapidClicks.removeValue(forKey: keyCode)
            }
        }
    }

    /// Release all active button clicks
    func releaseAllClicks(findBinding: (UInt16) -> ButtonBinding?) {
        for keyCode in activeButtonClicks {
            if let binding = findBinding(keyCode) {
                releaseClick(at: binding.position)
            }
        }
        activeButtonClicks.removeAll()
    }

    /// Clears all active joysticks, optionally releasing mouse clicks
    func clearActiveJoysticks(releaseClicks: Bool = true) {
        for (_, joystickState) in activeJoysticks {
            joystickState.timer.invalidate()
            if releaseClicks {
                releaseClick(at: joystickState.binding.position)
            }
        }
        activeJoysticks.removeAll()
    }

    /// Clears all active rapid click timers
    func clearActiveRapidClicks() {
        for (_, timer) in activeRapidClicks {
            timer.invalidate()
        }
        activeRapidClicks.removeAll()
    }

    /// Reset all active state
    func reset(findBinding: (UInt16) -> ButtonBinding?) {
        releaseAllClicks(findBinding: findBinding)
        clearActiveJoysticks()
        clearActiveRapidClicks()
    }

    // MARK: - Click Actions

    func performClick(at position: CGPoint) {
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left) {
            markAsSynthetic?(moveEvent)
            moveEvent.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.clickDelay) { [weak self] in
            guard let self = self else { return }
            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left) {
                self.markAsSynthetic?(mouseDown)
                mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
                mouseDown.post(tap: .cghidEventTap)
            }
        }
    }

    func releaseClick(at position: CGPoint) {
        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left) {
            markAsSynthetic?(mouseUp)
            mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    /// Performs a complete click action atomically: move -> down -> up -> restore cursor
    func performClickAction(at position: CGPoint) {
        // 1. Save original cursor position for restoration
        let originalPos = CGEvent(source: nil)?.location

        // 2. Move cursor to target position (sync)
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: position, mouseButton: .left) {
            markAsSynthetic?(moveEvent)
            moveEvent.post(tap: .cghidEventTap)
        }

        // 3. After delay, post mouseDown
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.clickDelay) { [weak self] in
            guard let self = self else { return }

            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                       mouseCursorPosition: position, mouseButton: .left) {
                self.markAsSynthetic?(mouseDown)
                mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
                mouseDown.post(tap: .cghidEventTap)
            }

            // 4. After another delay, post mouseUp (ensures correct ordering)
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.clickDelay) { [weak self] in
                guard let self = self else { return }

                if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                         mouseCursorPosition: position, mouseButton: .left) {
                    self.markAsSynthetic?(mouseUp)
                    mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
                    mouseUp.post(tap: .cghidEventTap)
                }

                // 5. Restore cursor to original position
                if let originalPos = originalPos {
                    if let moveBack = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                              mouseCursorPosition: originalPos, mouseButton: .left) {
                        self.markAsSynthetic?(moveBack)
                        moveBack.post(tap: .cghidEventTap)
                    }
                }
            }
        }
    }

    // MARK: - Joystick Actions

    private func startJoystick(binding: ButtonBinding, keyCode: UInt16) {
        let position = binding.position
        let direction = binding.joystickDirection
        let distance = binding.joystickDistance

        let delta = direction.delta
        let targetX = position.x + delta.dx * distance
        let targetY = position.y + delta.dy * distance
        let targetPos = CGPoint(x: targetX, y: targetY)

        // Store placeholder immediately to prevent race condition
        activeJoysticks[keyCode] = (timer: Timer(), binding: binding)

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left) {
            markAsSynthetic?(moveEvent)
            moveEvent.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.joystickStartDelay) { [weak self] in
            guard let self = self, self.activeJoysticks[keyCode] != nil else { return }

            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left) {
                self.markAsSynthetic?(mouseDown)
                mouseDown.post(tap: .cghidEventTap)
            }

            var progress: CGFloat = 0
            let interval = 1.0 / Constants.animationFPS
            let progressPerFrame = CGFloat(interval / Constants.joystickDuration)

            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                guard self.activeJoysticks[keyCode] != nil else {
                    timer.invalidate()
                    return
                }

                progress = min(1.0, progress + progressPerFrame)
                let easedProgress = 1.0 - (1.0 - progress) * (1.0 - progress)

                let currentX = position.x + (targetPos.x - position.x) * easedProgress
                let currentY = position.y + (targetPos.y - position.y) * easedProgress
                let currentPos = CGPoint(x: currentX, y: currentY)

                if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: currentPos, mouseButton: .left) {
                    self.markAsSynthetic?(dragEvent)
                    dragEvent.post(tap: .cghidEventTap)
                }

                if progress >= 1.0 {
                    timer.invalidate()
                }
            }

            RunLoop.main.add(timer, forMode: .common)
            self.activeJoysticks[keyCode] = (timer: timer, binding: binding)
        }
    }

    private func stopJoystick(keyCode: UInt16) {
        guard let joystickState = activeJoysticks[keyCode] else { return }

        joystickState.timer.invalidate()

        let binding = joystickState.binding
        let position = binding.position

        // Get actual cursor position for release (more accurate than calculated target)
        let releasePos: CGPoint
        if let currentPos = CGEvent(source: nil)?.location {
            releasePos = currentPos
        } else {
            // Fallback to calculated target position
            let direction = binding.joystickDirection
            let distance = binding.joystickDistance
            let delta = direction.delta
            releasePos = CGPoint(
                x: position.x + delta.dx * distance,
                y: position.y + delta.dy * distance
            )
        }

        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: releasePos, mouseButton: .left) {
            markAsSynthetic?(mouseUp)
            mouseUp.post(tap: .cghidEventTap)
        }

        if let moveBack = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left) {
            markAsSynthetic?(moveBack)
            moveBack.post(tap: .cghidEventTap)
        }

        activeJoysticks.removeValue(forKey: keyCode)
    }
}
