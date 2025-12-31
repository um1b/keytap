import Cocoa

class KeyTapController {
    // MARK: - Constants
    private enum Constants {
        static let animationFPS: Double = 60.0
        static let dragDurationDefault: Double = 0.15
        static let joystickDuration: Double = 0.12
        static let windowCacheInterval: TimeInterval = 0.2
        static let minWindowSize: CGFloat = 50.0
        static let diagonalFactor: CGFloat = 0.7071067811865476  // 1/sqrt(2)
        // Issue 44, 50: Reduced click delay from 16ms to 8ms for faster response
        static let clickDelay: TimeInterval = 0.008
        static let joystickStartDelay: TimeInterval = 0.005
        // Scroll settings (based on recorded gesture analysis)
        static let scrollDistance: CGFloat = 190.0
        static let scrollDuration: Double = 0.20
        static let scrollRepeatDelay: TimeInterval = 0.02
    }

    // MARK: - Public Properties
    var speed: Double = 50.0
    var targetBundleId: String?
    var dragDuration: Double = Constants.dragDurationDefault
    weak var overlayWindow: OverlayWindow?

    // MARK: - Target App State (set by AppDelegate via notifications)
    private var cachedTargetIsActive: Bool = false

    /// Called by AppDelegate when target app activation state changes
    func setTargetAppActive(_ isActive: Bool) {
        cachedTargetIsActive = isActive
        print("KeyTap: Target app active state set to \(isActive)")
    }

    // MARK: - Private Properties
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dragTimer: Timer?

    // WASD state
    private var wPressed = false
    private var aPressed = false
    private var sPressed = false
    private var dPressed = false

    // Drag state
    private var isDragging = false
    private var dragStartPoint: CGPoint = .zero
    private var currentDragPoint: CGPoint = .zero
    private var targetDragPoint: CGPoint = .zero
    private var dragProgress: Double = 0.0
    private var originalCursorPosition: CGPoint?  // Save cursor position before drag

    // Joystick drag anchor (for invisible drag zone)
    private var joystickDragAnchor: CGPoint?

    // Synthetic event identifier - used to mark events we generate
    private let syntheticUserData: Int64 = 0x4B4D5359  // "KMSY" in hex

    private func isSyntheticEvent(_ event: CGEvent) -> Bool {
        return event.getIntegerValueField(.eventSourceUserData) == syntheticUserData
    }

    private func markAsSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
    }

    // Button bindings
    private var buttonBindings: [ButtonBinding] = []
    private var activeButtonClicks: Set<UInt16> = []
    private var activeJoysticks: [UInt16: (timer: Timer, binding: ButtonBinding)] = [:]

    // Key codes
    private let keyW: CGKeyCode = 13
    private let keyA: CGKeyCode = 0
    private let keyS: CGKeyCode = 1
    private let keyD: CGKeyCode = 2
    private let keyQ: CGKeyCode = 12  // Scroll up
    private let keyE: CGKeyCode = 14  // Scroll down

    // Scroll state
    private var isScrolling = false
    private var scrollTimer: Timer?
    private var scrollStartPoint: CGPoint = .zero
    private var scrollTargetPoint: CGPoint = .zero
    private var scrollProgress: Double = 0.0
    private var originalScrollPosition: CGPoint?
    private var heldScrollDirection: CGFloat?  // Track held scroll key for repeat

    /// Find a valid (bound) button binding for the given keyCode
    /// Skips unbound buttons (keyCode=0 with label "?") to avoid conflict with 'A' key
    private func findBinding(for keyCode: UInt16) -> ButtonBinding? {
        return buttonBindings.first { (binding: ButtonBinding) -> Bool in
            let matchesKeyCode = binding.keyCode == keyCode
            let isUnbound = binding.keyCode == 0 && binding.keyLabel == "?"
            return matchesKeyCode && !isUnbound
        }
    }

    // Window cache for performance
    private var cachedWindowList: [[String: Any]]?
    private var windowCacheTime: Date = .distantPast

    // Event mask for keyboard and mouse events (no scroll, no flagsChanged since we don't handle it)
    private let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved
        ]
        return types.reduce(0) { $0 | (1 << $1.rawValue) }
    }()

    // MARK: - Lifecycle
    deinit {
        stop()
        scrollTimer = nil
    }

    // MARK: - Public Methods
    func start() -> Bool {
        updateButtonBindings()

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let controller = Unmanaged<KeyTapController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleEvent(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        return true
    }

    func stop() {
        resetAllState()

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
    }

    func reEnableEventTap() {
        guard let tap = eventTap else { return }
        eventTapRetryCount = 0  // Reset retry count on manual re-enable
        // Reduced delay from 50ms to 5ms - notification caching handles timing now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
            guard let tap = self?.eventTap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
            print("KeyTap: Event tap re-enabled after app activation")
        }
    }

    private func retryEnableEventTap() {
        guard eventTapRetryCount < maxEventTapRetries else {
            print("KeyTap: Event tap failed after \(maxEventTapRetries) retries")
            return
        }

        eventTapRetryCount += 1
        let delay = 0.02 * Double(eventTapRetryCount)  // Exponential backoff

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, let tap = self.eventTap else { return }

            CGEvent.tapEnable(tap: tap, enable: true)

            // Verify it's actually enabled
            if CFMachPortIsValid(tap) {
                self.eventTapRetryCount = 0  // Reset on success
                print("KeyTap: Event tap re-enabled (attempt \(self.eventTapRetryCount + 1))")
            } else {
                // Try again
                self.retryEnableEventTap()
            }
        }
    }

    func updateButtonBindings() {
        guard let overlay = overlayWindow else { return }

        // Clear active joysticks when bindings change to prevent stale state (Issue 33)
        clearActiveJoysticks(releaseClicks: false)

        buttonBindings = overlay.getButtonBindings().map { binding in
            ButtonBinding(
                keyCode: binding.keyCode,
                keyLabel: binding.keyLabel,
                position: binding.position,
                buttonType: binding.buttonType,
                joystickDirection: binding.joystickDirection,
                joystickDistance: binding.joystickDistance
            )
        }

        // Find joystick button and store its position as drag anchor
        if let joystickBinding = buttonBindings.first(where: { $0.buttonType == .joystick }) {
            joystickDragAnchor = joystickBinding.position
        } else {
            joystickDragAnchor = nil
        }
    }

    private func resetAllState() {
        // Stop drag timer first
        dragTimer?.invalidate()
        dragTimer = nil

        // Stop scroll timer
        scrollTimer?.invalidate()
        scrollTimer = nil
        isScrolling = false
        originalScrollPosition = nil
        heldScrollDirection = nil

        if isDragging {
            endDrag()
        }
        for keyCode in activeButtonClicks {
            if let binding = findBinding(for: keyCode) {
                releaseClick(at: binding.position)
            }
        }
        activeButtonClicks.removeAll()
        clearActiveJoysticks()
        wPressed = false
        aPressed = false
        sPressed = false
        dPressed = false
    }

    /// Clears all active joysticks, optionally releasing mouse clicks
    private func clearActiveJoysticks(releaseClicks: Bool = true) {
        for (_, joystickState) in activeJoysticks {
            joystickState.timer.invalidate()
            if releaseClicks {
                releaseClick(at: joystickState.binding.position)
            }
        }
        activeJoysticks.removeAll()
    }

    /// Called when target app loses focus - immediately releases all active inputs
    func resetStateOnFocusLoss() {
        // Don't clear cachedTargetIsActive here - let isTargetAppActive() handle it
        // (clearing too early causes first keypress to fail on switch back)
        resetAllState()
        // Invalidate window cache to force fresh lookup on next activation
        cachedWindowList = nil
        windowCacheTime = .distantPast
        print("KeyTap: State reset due to focus loss")
    }

    // MARK: - Target Detection
    private func refreshWindowCacheIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(windowCacheTime) > Constants.windowCacheInterval {
            cachedWindowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
            windowCacheTime = now
        }
    }

    private func isCursorInTargetApp() -> Bool {
        guard let currentPos = CGEvent(source: nil)?.location else {
            return false
        }

        guard let targetId = targetBundleId else {
            return true
        }

        refreshWindowCacheIfNeeded()

        guard let windowInfoList = cachedWindowList else {
            return false
        }

        let lowercasedTargetId = targetId.lowercased()

        for windowInfo in windowInfoList {
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }

            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: ownerPID),
                  let appBundleId = app.bundleIdentifier else {
                continue
            }

            guard appBundleId.lowercased() == lowercasedTargetId else {
                continue
            }

            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            let width = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0

            if width < Constants.minWindowSize || height < Constants.minWindowSize {
                continue
            }

            let windowFrame = CGRect(x: x, y: y, width: width, height: height)

            if windowFrame.contains(currentPos) {
                return true
            }
        }

        return false
    }

    /// Check if target app is the frontmost application (for keyboard events)
    /// Uses cached notification state for reliability, with NSWorkspace fallback
    private func isTargetAppActive() -> Bool {
        guard let targetId = targetBundleId else { return true }  // All Apps mode

        // Query NSWorkspace for current frontmost app
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
        let isMatch = frontmost == targetId.lowercased()

        // If cached says active, trust it (notification-based, reliable)
        if cachedTargetIsActive {
            // But if we see a DIFFERENT app is definitely frontmost, update cache
            if let front = frontmost, !isMatch {
                print("KeyTap: Cache invalidated - different app frontmost: \(front)")
                cachedTargetIsActive = false
                return false
            }
            return true
        }

        // If cached says inactive, check NSWorkspace
        // If target IS frontmost, update cache (fixes first keypress issue)
        if isMatch {
            print("KeyTap: Cache updated - target app is frontmost")
            cachedTargetIsActive = true
            return true
        }

        return false
    }

    // MARK: - Event Handling
    private var eventTapRetryCount = 0
    private let maxEventTapRetries = 5

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetAllState()
            retryEnableEventTap()
            return Unmanaged.passRetained(event)
        }

        // Pass through mouse events immediately (don't need active check for passthrough)
        if type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged || type == .mouseMoved {
            return Unmanaged.passRetained(event)
        }

        // For keyboard events, use frontmost app check (fixes first keypress on app switch)
        let isActive = isTargetAppActive()

        if !isActive {
            resetAllState()
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isKeyDown = (type == .keyDown)
        let isKeyUp = (type == .keyUp)

        // Ignore key repeat events to prevent multiple triggers
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat && isKeyDown {
            return Unmanaged.passRetained(event)
        }

        if let binding = findBinding(for: keyCode) {
            // Only clear WASD state on keyUp, not keyDown
            if isKeyUp {
                if keyCode == keyW { wPressed = false }
                else if keyCode == keyA { aPressed = false }
                else if keyCode == keyS { sPressed = false }
                else if keyCode == keyD { dPressed = false }

                // End drag if no WASD keys are pressed anymore
                if isDragging && !wPressed && !aPressed && !sPressed && !dPressed {
                    endDrag()
                }
            }

            handleButtonBinding(binding: binding, keyCode: keyCode, isKeyDown: isKeyDown, isKeyUp: isKeyUp)
            return nil
        }

        var isWASD = false

        if keyCode == keyW {
            if isKeyDown && !wPressed { wPressed = true; isWASD = true }
            if isKeyUp { wPressed = false; isWASD = true }
        } else if keyCode == keyA {
            if isKeyDown && !aPressed { aPressed = true; isWASD = true }
            if isKeyUp { aPressed = false; isWASD = true }
        } else if keyCode == keyS {
            if isKeyDown && !sPressed { sPressed = true; isWASD = true }
            if isKeyUp { sPressed = false; isWASD = true }
        } else if keyCode == keyD {
            if isKeyDown && !dPressed { dPressed = true; isWASD = true }
            if isKeyUp { dPressed = false; isWASD = true }
        }

        if isWASD {
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

            return nil
        }

        // Handle Q/E scroll keys
        if keyCode == keyQ {
            if isKeyDown {
                heldScrollDirection = -1  // Track that Q is held (scroll up)
                if !isScrolling {
                    startScroll(direction: -1)
                }
            }
            if isKeyUp {
                heldScrollDirection = nil  // Clear held state
            }
            return nil
        }
        if keyCode == keyE {
            if isKeyDown {
                heldScrollDirection = 1  // Track that E is held (scroll down)
                if !isScrolling {
                    startScroll(direction: 1)
                }
            }
            if isKeyUp {
                heldScrollDirection = nil  // Clear held state
            }
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Button Binding Handling
    private func handleButtonBinding(binding: ButtonBinding, keyCode: UInt16, isKeyDown: Bool, isKeyUp: Bool) {
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
        }
    }

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
            markAsSynthetic(moveEvent)
            moveEvent.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.joystickStartDelay) { [weak self] in
            guard let self = self, self.activeJoysticks[keyCode] != nil else { return }

            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left) {
                self.markAsSynthetic(mouseDown)
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
                    self.markAsSynthetic(dragEvent)
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
            markAsSynthetic(mouseUp)
            mouseUp.post(tap: .cghidEventTap)
        }

        if let moveBack = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left) {
            markAsSynthetic(moveBack)
            moveBack.post(tap: .cghidEventTap)
        }

        activeJoysticks.removeValue(forKey: keyCode)
    }

    // MARK: - Click Actions
    private func performClick(at position: CGPoint) {
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left) {
            markAsSynthetic(moveEvent)
            moveEvent.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.clickDelay) { [weak self] in
            guard let self = self else { return }
            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left) {
                self.markAsSynthetic(mouseDown)
                mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
                mouseDown.post(tap: .cghidEventTap)
            }
        }
    }

    private func releaseClick(at position: CGPoint) {
        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left) {
            markAsSynthetic(mouseUp)
            mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    /// Performs a complete click action atomically: move → down → up → restore cursor
    /// This ensures correct event ordering (mouseDown before mouseUp) and cursor restoration.
    private func performClickAction(at position: CGPoint) {
        // 1. Save original cursor position for restoration
        let originalPos = CGEvent(source: nil)?.location

        // 2. Move cursor to target position (sync)
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: position, mouseButton: .left) {
            markAsSynthetic(moveEvent)
            moveEvent.post(tap: .cghidEventTap)
        }

        // 3. After delay, post mouseDown
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.clickDelay) { [weak self] in
            guard let self = self else { return }

            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                       mouseCursorPosition: position, mouseButton: .left) {
                self.markAsSynthetic(mouseDown)
                mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
                mouseDown.post(tap: .cghidEventTap)
            }

            // 4. After another delay, post mouseUp (ensures correct ordering)
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.clickDelay) { [weak self] in
                guard let self = self else { return }

                if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                         mouseCursorPosition: position, mouseButton: .left) {
                    self.markAsSynthetic(mouseUp)
                    mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
                    mouseUp.post(tap: .cghidEventTap)
                }

                // 5. Restore cursor to original position
                if let originalPos = originalPos {
                    if let moveBack = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                              mouseCursorPosition: originalPos, mouseButton: .left) {
                        self.markAsSynthetic(moveBack)
                        moveBack.post(tap: .cghidEventTap)
                    }
                }
            }
        }
    }

    // MARK: - Drag Actions
    private func startDrag() {
        // Guard against starting drag while already dragging (Issue 28: drag timer state corruption)
        guard !isDragging else { return }

        // Save original cursor position before drag starts
        originalCursorPosition = CGEvent(source: nil)?.location

        // Cancel any active joysticks before starting WASD drag (Issue 30)
        clearActiveJoysticks()

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

        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: dragAnchor, mouseButton: .left) {
            markAsSynthetic(mouseDown)
            mouseDown.post(tap: .cghidEventTap)
        }

        isDragging = true
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
            markAsSynthetic(dragEvent)
            dragEvent.post(tap: .cghidEventTap)
        }
    }

    private func easeOutQuad(_ t: Double) -> CGFloat {
        return CGFloat(1.0 - (1.0 - t) * (1.0 - t))
    }

    private func endDrag() {
        guard isDragging else { return }

        dragTimer?.invalidate()
        dragTimer = nil

        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentDragPoint, mouseButton: .left) {
            markAsSynthetic(mouseUp)
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

    // MARK: - Scroll Actions
    private func startScroll(direction: CGFloat) {
        guard !isScrolling else { return }

        // Get current cursor position and save it for restoration
        guard let currentPos = CGEvent(source: nil)?.location else { return }
        originalScrollPosition = currentPos

        scrollStartPoint = currentPos
        scrollTargetPoint = CGPoint(x: currentPos.x, y: currentPos.y + direction * Constants.scrollDistance)
        scrollProgress = 0.0
        isScrolling = true

        // Mouse down at current position
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: scrollStartPoint, mouseButton: .left) {
            markAsSynthetic(mouseDown)
            mouseDown.post(tap: .cghidEventTap)
        }

        let interval = 1.0 / Constants.animationFPS
        let progressPerFrame = interval / Constants.scrollDuration

        scrollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.animateScroll(progressPerFrame: progressPerFrame)
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func animateScroll(progressPerFrame: Double) {
        guard isScrolling else {
            endScroll()
            return
        }

        scrollProgress = min(1.0, scrollProgress + progressPerFrame)

        // Ease-in curve (acceleration): progress^2
        let easedProgress = scrollProgress * scrollProgress

        let currentX = scrollStartPoint.x
        let currentY = scrollStartPoint.y + (scrollTargetPoint.y - scrollStartPoint.y) * CGFloat(easedProgress)
        let currentPos = CGPoint(x: currentX, y: currentY)

        if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: currentPos, mouseButton: .left) {
            markAsSynthetic(dragEvent)
            dragEvent.post(tap: .cghidEventTap)
        }

        if scrollProgress >= 1.0 {
            endScroll()
        }
    }

    private func endScroll() {
        scrollTimer?.invalidate()
        scrollTimer = nil

        // Mouse up at final position
        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: scrollTargetPoint, mouseButton: .left) {
            markAsSynthetic(mouseUp)
            mouseUp.post(tap: .cghidEventTap)
        }

        // Restore cursor to original position using mouse move event
        if let originalPos = originalScrollPosition {
            if let moveBack = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: originalPos, mouseButton: .left) {
                markAsSynthetic(moveBack)
                moveBack.post(tap: .cghidEventTap)
            }
        }
        originalScrollPosition = nil

        isScrolling = false
        scrollProgress = 0.0

        // If scroll key is still held, start another scroll after brief delay
        if let direction = heldScrollDirection {
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.scrollRepeatDelay) { [weak self] in
                guard let self = self, self.heldScrollDirection != nil else { return }
                self.startScroll(direction: direction)
            }
        }
    }
}
