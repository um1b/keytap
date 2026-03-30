import Cocoa

class KeyTapController {
    // MARK: - Public Properties
    var speed: Double = 50.0 {
        didSet { dragHandler.speed = speed }
    }
    var targetBundleId: String? {
        didSet {
            // Initial sync when target changes
            if let targetId = targetBundleId {
                isTargetFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() == targetId.lowercased()
            } else {
                isTargetFrontmost = false
            }
        }
    }
    var dragDuration: Double = 0.15 {
        didSet { dragHandler.dragDuration = dragDuration }
    }
    weak var overlayWindow: OverlayWindow?

    /// Check if target app is currently frontmost (cached value)
    private var isTargetFrontmost: Bool = false

    var isTargetAppActive: Bool {
        guard let _ = targetBundleId else { return true }  // "All Apps" mode
        return isTargetFrontmost
    }

    // MARK: - Private Properties
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Handlers
    private let dragHandler = DragHandler()
    private let scrollHandler = ScrollHandler()
    private let buttonActionHandler = ButtonActionHandler()

    // Joystick drag anchor (for invisible drag zone)
    private var joystickDragAnchor: CGPoint?

    // Synthetic event identifier - used to mark events we generate or pass through
    private let syntheticUserData: Int64 = 0x4B4D5359  // "KMSY" in hex

    private func isSyntheticEvent(_ event: CGEvent) -> Bool {
        return event.getIntegerValueField(.eventSourceUserData) == syntheticUserData
    }

    private func markAsSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
    }

    // Button bindings
    private var buttonBindings: [ButtonBinding] = []

    // WASD bindings - maps key codes to joystick directions for drag movement
    private let wasdBindings: [UInt16: JoystickDirection] = [
        13: .up,    // W
        0: .left,   // A
        1: .down,   // S
        2: .right   // D
    ]

    // Key codes
    private let keyQ: CGKeyCode = 12  // Scroll up
    private let keyE: CGKeyCode = 14  // Scroll down

    /// Find a valid (bound) button binding for the given keyCode
    /// Skips unbound buttons (keyCode=0 with label "?") to avoid conflict with 'A' key
    private func findBinding(for keyCode: UInt16) -> ButtonBinding? {
        return buttonBindings.first { (binding: ButtonBinding) -> Bool in
            let matchesKeyCode = binding.keyCode == keyCode
            let isUnbound = binding.keyCode == 0 && binding.keyLabel == "?"
            return matchesKeyCode && !isUnbound
        }
    }

    // Event mask for keyboard and mouse events
    private let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved
        ]
        return types.reduce(0) { $0 | (1 << $1.rawValue) }
    }()

    // MARK: - Lifecycle
    init() {
        setupHandlers()
    }

    deinit {
        stop()
    }

    private func setupHandlers() {
        // Configure handlers with synthetic event marking
        let markSynthetic: (CGEvent) -> Void = { [weak self] event in
            self?.markAsSynthetic(event)
        }

        dragHandler.markAsSynthetic = markSynthetic
        dragHandler.onDragStart = { [weak self] in
            self?.buttonActionHandler.clearActiveJoysticks()
        }

        scrollHandler.markAsSynthetic = markSynthetic
        buttonActionHandler.markAsSynthetic = markSynthetic
    }

    // MARK: - Public Methods
    func setTargetFrontmost(_ active: Bool) {
        isTargetFrontmost = active
    }

    func start() -> Bool {
        updateButtonBindings()

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<KeyTapController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleEvent(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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

    private var eventTapRetryCount = 0
    private let maxEventTapRetries = 5

    private func retryEnableEventTap() {
        guard eventTapRetryCount < maxEventTapRetries else { return }

        eventTapRetryCount += 1
        let delay = 0.02 * Double(eventTapRetryCount)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, let tap = self.eventTap else { return }

            CGEvent.tapEnable(tap: tap, enable: true)

            if CFMachPortIsValid(tap) {
                self.eventTapRetryCount = 0
            } else {
                self.retryEnableEventTap()
            }
        }
    }

    func updateButtonBindings() {
        guard let overlay = overlayWindow else { return }

        // Clear active joysticks when bindings change to prevent stale state
        buttonActionHandler.clearActiveJoysticks(releaseClicks: false)

        buttonBindings = overlay.getButtonBindings()

        // Find joystick button and store its position as drag anchor
        if let joystickBinding = buttonBindings.first(where: { $0.buttonType == .joystick }) {
            joystickDragAnchor = joystickBinding.position
            dragHandler.joystickDragAnchor = joystickBinding.position
        } else {
            joystickDragAnchor = nil
            dragHandler.joystickDragAnchor = nil
        }
    }

    func resetAllState() {
        dragHandler.reset()
        scrollHandler.reset()
        buttonActionHandler.reset(findBinding: findBinding)
    }

    // MARK: - Event Handling
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetAllState()
            retryEnableEventTap()
            return Unmanaged.passUnretained(event)
        }

        // Pass through events we've already processed (prevents loop)
        if isSyntheticEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        // Speculatively activate if event arrives before appDidActivate notification fires.
        // At .cgSessionEventTap level, events arrive after WindowServer completes activation,
        // so frontmostApplication is already accurate here.
        if (type == .keyDown || type == .leftMouseDown) && !isTargetFrontmost, let targetId = targetBundleId {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() == targetId.lowercased() {
                isTargetFrontmost = true
            }
        }

        // Pass through mouse events immediately
        if type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged || type == .mouseMoved {
            return Unmanaged.passUnretained(event)
        }

        // Pass through ALL keyboard events when target app is not active
        if !isTargetAppActive {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isKeyDown = (type == .keyDown)
        let isKeyUp = (type == .keyUp)

        // Ignore key repeat events to prevent multiple triggers
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat && isKeyDown {
            return Unmanaged.passUnretained(event)
        }

        // Handle button bindings
        if let binding = findBinding(for: keyCode) {
            buttonActionHandler.handleButtonBinding(binding: binding, keyCode: keyCode, isKeyDown: isKeyDown, isKeyUp: isKeyUp)
            return nil
        }

        // Handle WASD keys for drag movement
        if wasdBindings[keyCode] != nil {
            guard isTargetAppActive else {
                return Unmanaged.passUnretained(event)
            }
            dragHandler.handleWASDBinding(keyCode: keyCode, isKeyDown: isKeyDown, isKeyUp: isKeyUp)
            return nil
        }

        // Handle Q/E scroll keys
        if keyCode == keyQ {
            guard isTargetAppActive else {
                return Unmanaged.passUnretained(event)
            }
            if isKeyDown {
                scrollHandler.handleKeyDown(direction: -1)
            }
            if isKeyUp {
                scrollHandler.handleKeyUp()
            }
            return nil
        }
        if keyCode == keyE {
            guard isTargetAppActive else {
                return Unmanaged.passUnretained(event)
            }
            if isKeyDown {
                scrollHandler.handleKeyDown(direction: 1)
            }
            if isKeyUp {
                scrollHandler.handleKeyUp()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
