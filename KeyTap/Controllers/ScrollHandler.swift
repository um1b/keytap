import Cocoa

/// Handles Q/E scroll gestures with animated cursor dragging
class ScrollHandler {
    // MARK: - Constants
    private enum Constants {
        static let animationFPS: Double = 60.0
        static let scrollDistance: CGFloat = 190.0
        static let scrollDuration: Double = 0.20
        static let scrollRepeatDelay: TimeInterval = 0.02
    }

    // MARK: - Properties

    // Callback for marking events as synthetic
    var markAsSynthetic: ((CGEvent) -> Void)?

    // Scroll state
    private(set) var isScrolling = false
    private var scrollTimer: Timer?
    private var scrollStartPoint: CGPoint = .zero
    private var scrollTargetPoint: CGPoint = .zero
    private var scrollProgress: Double = 0.0
    private var originalScrollPosition: CGPoint?
    private(set) var heldScrollDirection: CGFloat?

    // MARK: - Public Methods

    /// Handle scroll key down event
    func handleKeyDown(direction: CGFloat) {
        heldScrollDirection = direction
        if !isScrolling {
            startScroll(direction: direction)
        }
    }

    /// Handle scroll key up event
    func handleKeyUp() {
        heldScrollDirection = nil
    }

    /// Reset all scroll state
    func reset() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        isScrolling = false
        originalScrollPosition = nil
        heldScrollDirection = nil
    }

    // MARK: - Private Methods

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
            markAsSynthetic?(mouseDown)
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
            markAsSynthetic?(dragEvent)
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
            markAsSynthetic?(mouseUp)
            mouseUp.post(tap: .cghidEventTap)
        }

        // Restore cursor to original position using mouse move event
        if let originalPos = originalScrollPosition {
            if let moveBack = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: originalPos, mouseButton: .left) {
                markAsSynthetic?(moveBack)
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
