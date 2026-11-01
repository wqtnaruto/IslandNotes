import AppKit
import Foundation

@MainActor
final class KeepAwakeController {
    private var process: Process?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard process == nil else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            task.arguments = ["-dimsu"]
            do {
                try task.run()
                process = task
            } catch {
                process = nil
            }
        } else {
            process?.terminate()
            process = nil
        }
    }

    deinit { process?.terminate() }
}

@MainActor
final class BreakReminder: ObservableObject {
    @Published private(set) var nextBreakAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var remainingMinutes: Int = 0
    @Published private(set) var progress: Double = 0

    private var deadlineTimer: Timer?
    private var uiTimer: Timer?
    private var interval: TimeInterval = 0
    private var isPanelVisible = false

    func configure(enabled: Bool, intervalMinutes: Int) {
        let requestedInterval = TimeInterval(max(1, intervalMinutes) * 60)
        if enabled, nextBreakAt != nil, deadlineTimer?.isValid == true, interval == requestedInterval { return }
        invalidateTimers()
        if message != nil { message = nil }
        guard enabled else {
            if nextBreakAt != nil { nextBreakAt = nil }
            if remainingMinutes != 0 { remainingMinutes = 0 }
            if progress != 0 { progress = 0 }
            return
        }

        let now = Date()
        interval = requestedInterval
        nextBreakAt = now.addingTimeInterval(interval)
        refresh(now: now)
        scheduleDeadlineTimer(now: now)
        updateUITimer()
    }

    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        if visible, nextBreakAt != nil {
            refresh(now: Date())
        }
        updateUITimer()
    }

    func refresh(now: Date) {
        guard let nextBreakAt, interval > 0 else {
            if remainingMinutes != 0 { remainingMinutes = 0 }
            if progress != 0 { progress = 0 }
            return
        }
        let remaining = max(0, nextBreakAt.timeIntervalSince(now))
        let updatedMinutes = Int(ceil(remaining / 60))
        let updatedProgress = min(1, max(0, 1 - remaining / interval))
        if remainingMinutes != updatedMinutes {
            remainingMinutes = updatedMinutes
        }
        if abs(progress - updatedProgress) > 0.0005
            || (updatedProgress == 0 && progress != 0)
            || (updatedProgress == 1 && progress != 1) {
            progress = updatedProgress
        }
    }

    func dismiss() {
        if message != nil { message = nil }
    }

    private func scheduleDeadlineTimer(now: Date) {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let nextBreakAt else { return }
        let delay = max(0.05, nextBreakAt.timeIntervalSince(now))
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handleDeadlineReached() }
            } else {
                Task { @MainActor [weak self] in self?.handleDeadlineReached() }
            }
        }
        timer.tolerance = min(0.5, delay * 0.05)
        deadlineTimer = timer
    }

    private func handleDeadlineReached() {
        let now = Date()
        guard let deadline = nextBreakAt else { return }
        if now >= deadline {
            message = L10n.string("Time to stand up, stretch, and look away from the screen.")
            nextBreakAt = now.addingTimeInterval(interval)
            NSSound.beep()
        }
        refresh(now: now)
        scheduleDeadlineTimer(now: now)
    }

    private func updateUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
        guard isPanelVisible, nextBreakAt != nil, interval > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh(now: Date()) }
            } else {
                Task { @MainActor [weak self] in self?.refresh(now: Date()) }
            }
        }
        timer.tolerance = 1.0
        uiTimer = timer
    }

    private func invalidateTimers() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        uiTimer?.invalidate()
        uiTimer = nil
    }
}

@MainActor
final class TopEdgeActivationMonitor {
    struct ScreenMetrics: Equatable {
        let frame: NSRect
        let visibleFrame: NSRect
        let safeAreaTop: CGFloat
    }

    private var globalMonitor: Any?
    private var isStarted = false
    private var isPanelVisible = false
    private var requiresExitBeforeHover = false
    private var lastHoverActivation = Date.distantPast
    private var cooldownUntil = Date.distantPast

    var mode: ActivationMode = .click {
        didSet {
            guard oldValue != mode else { return }
            requiresExitBeforeHover = false
            reconfigureMonitors()
        }
    }

    var activate: (() -> Void)?

    func start() {
        isStarted = true
        reconfigureMonitors()
    }

    func stop() {
        isStarted = false
        removeMonitors()
    }

    func notifyPanelVisibilityChanged(_ visible: Bool, pointerLocation: NSPoint = NSEvent.mouseLocation, screens: [ScreenMetrics]? = nil, now: Date = Date()) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        if !visible {
            cooldownUntil = now.addingTimeInterval(0.45)
            let activeScreens = screens ?? Self.currentScreenMetrics()
            requiresExitBeforeHover = Self.isPointInTriggerZone(pointerLocation, screens: activeScreens)
        }
        reconfigureMonitors()
    }

    static func triggerRect(for screen: ScreenMetrics) -> NSRect {
        let menuBarOcclusion = screen.frame.maxY - screen.visibleFrame.maxY
        let height = min(40, max(24, max(screen.safeAreaTop, menuBarOcclusion)))
        return NSRect(
            x: screen.frame.midX - 110,
            y: screen.frame.maxY - height,
            width: 220,
            height: height
        )
    }

    static func isPointInTriggerZone(_ point: NSPoint, screens: [ScreenMetrics]) -> Bool {
        guard let screen = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else {
            return false
        }
        return triggerRect(for: screen).contains(point)
    }

    @discardableResult
    func evaluateEvent(type: NSEvent.EventType, at point: NSPoint, screens: [ScreenMetrics], now: Date = Date()) -> Bool {
        guard !isPanelVisible, mode != .menuBarOnly else { return false }

        let inTrigger = Self.isPointInTriggerZone(point, screens: screens)
        if !inTrigger {
            if requiresExitBeforeHover {
                requiresExitBeforeHover = false
            }
            return false
        }

        switch mode {
        case .click:
            guard type == .leftMouseDown else { return false }
            activate?()
            return true
        case .hover:
            guard type == .mouseMoved,
                  !requiresExitBeforeHover,
                  now >= cooldownUntil,
                  now.timeIntervalSince(lastHoverActivation) > 0.75 else { return false }
            lastHoverActivation = now
            activate?()
            return true
        case .menuBarOnly:
            return false
        }
    }

    private func reconfigureMonitors() {
        removeMonitors()
        guard isStarted, !isPanelVisible else { return }

        let mask: NSEvent.EventTypeMask
        switch mode {
        case .click:
            mask = [.leftMouseDown]
        case .hover:
            mask = [.mouseMoved]
        case .menuBarOnly:
            return
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let eventType = event.type
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleLiveEvent(type: eventType)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleLiveEvent(type: eventType)
                }
            }
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleLiveEvent(type: NSEvent.EventType) {
        let point = NSEvent.mouseLocation
        evaluateEvent(type: type, at: point, screens: Self.currentScreenMetrics())
    }

    private static func currentScreenMetrics() -> [ScreenMetrics] {
        NSScreen.screens.map {
            ScreenMetrics(
                frame: $0.frame,
                visibleFrame: $0.visibleFrame,
                safeAreaTop: $0.safeAreaInsets.top
            )
        }
    }
}
