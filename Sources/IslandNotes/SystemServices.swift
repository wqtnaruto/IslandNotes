import AppKit
import Foundation

@MainActor
final class KeepAwakeController {
    private var process: Process?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if let process, process.isRunning {
                return
            }
            process = nil
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            task.arguments = ["-dimsu", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
            task.terminationHandler = { [weak self] finished in
                Task { @MainActor [weak self] in
                    if self?.process === finished {
                        self?.process = nil
                    }
                }
            }
            do {
                try task.run()
                process = task
            } catch {
                process = nil
            }
        } else {
            if let process, process.isRunning {
                process.terminate()
            }
            process = nil
        }
    }

    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

@MainActor
final class BreakReminder: ObservableObject {
    @Published private(set) var nextBreakAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var remainingMinutes: Int = 0
    @Published private(set) var progress: Double = 0

    var onBreakTriggered: (() -> Void)?

    private var deadlineTimer: Timer?
    private var uiTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var interval: TimeInterval = 0
    private var isPanelVisible = false
    private var isIslandVisible = false

    var isUIRefreshTimerActive: Bool { uiTimer?.isValid == true }

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemWake(now: Date())
            }
        }
    }

    deinit {
        deadlineTimer?.invalidate()
        uiTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

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

    func setIslandVisible(_ visible: Bool) {
        guard isIslandVisible != visible else { return }
        isIslandVisible = visible
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

    /// Re-synchronizes monotonic `Timer` scheduling with wall-clock `nextBreakAt` after macOS sleep.
    func handleSystemWake(now: Date = Date()) {
        guard let deadline = nextBreakAt, interval > 0 else { return }
        if now >= deadline {
            nextBreakAt = now.addingTimeInterval(interval)
        }
        refresh(now: now)
        scheduleDeadlineTimer(now: now)
    }

    func triggerIfDue(now: Date = Date(), playSound: Bool = true) {
        guard let deadline = nextBreakAt else { return }
        if now >= deadline {
            message = L10n.string("Time to stand up, stretch, and look away from the screen.")
            nextBreakAt = now.addingTimeInterval(interval)
            if playSound {
                NSSound.beep()
            }
            onBreakTriggered?()
        }
        refresh(now: now)
        scheduleDeadlineTimer(now: now)
    }

    private func scheduleDeadlineTimer(now: Date) {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let nextBreakAt else { return }
        let delay = max(0.05, nextBreakAt.timeIntervalSince(now))
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.triggerIfDue(now: Date()) }
            } else {
                Task { @MainActor [weak self] in self?.triggerIfDue(now: Date()) }
            }
        }
        timer.tolerance = min(0.5, delay * 0.05)
        deadlineTimer = timer
    }

    private func updateUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
        guard (isPanelVisible || isIslandVisible), nextBreakAt != nil, interval > 0 else { return }
        let refreshInterval: TimeInterval = isPanelVisible ? 5 : 10
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh(now: Date()) }
            } else {
                Task { @MainActor [weak self] in self?.refresh(now: Date()) }
            }
        }
        timer.tolerance = isPanelVisible ? 1.0 : 2.5
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
    private var activeDragTimer: Timer?
    private var isStarted = false
    private var isPanelVisible = false
    private var cooldownUntil = Date.distantPast
    private var baselineDragChangeCount = 0
    private var inspectedDragChangeCount: Int?
    private var inspectedDragHasFiles = false

    var mode: ActivationMode = .click {
        didSet {
            guard oldValue != mode else { return }
            reconfigureMonitors()
        }
    }

    var activate: (() -> Void)?
    var activateForFileDrag: (() -> Void)?

    func start() {
        isStarted = true
        syncDragPasteboardBaselineIfIdle()
        reconfigureMonitors()
    }

    func stop() {
        isStarted = false
        removeMonitors()
    }

    func notifyPanelVisibilityChanged(
        _ visible: Bool,
        pointerLocation: NSPoint = NSEvent.mouseLocation,
        screens: [ScreenMetrics]? = nil,
        now: Date = Date()
    ) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        if !visible {
            cooldownUntil = now.addingTimeInterval(0.45)
            syncDragPasteboardBaselineIfIdle()
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

    static func fileDragTriggerRect(for screen: ScreenMetrics) -> NSRect {
        let menuBarOcclusion = screen.frame.maxY - screen.visibleFrame.maxY
        let height = min(64, max(38, max(screen.safeAreaTop, menuBarOcclusion) + 14))
        return NSRect(
            x: screen.frame.midX - 140,
            y: screen.frame.maxY - height,
            width: 280,
            height: height
        )
    }

    static func isPointInTriggerZone(_ point: NSPoint, screens: [ScreenMetrics]) -> Bool {
        guard let screen = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else {
            return false
        }
        return triggerRect(for: screen).contains(point)
    }

    static func isPointInFileDragTriggerZone(_ point: NSPoint, screens: [ScreenMetrics]) -> Bool {
        guard let screen = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else {
            return false
        }
        return fileDragTriggerRect(for: screen).contains(point)
    }

    @discardableResult
    func evaluateEvent(type: NSEvent.EventType, at point: NSPoint, screens: [ScreenMetrics], now: Date = Date()) -> Bool {
        guard !isPanelVisible, mode != .menuBarOnly else { return false }
        guard Self.isPointInTriggerZone(point, screens: screens) else { return false }

        switch mode {
        case .click:
            guard type == .leftMouseDown else { return false }
            activate?()
            return true
        case .menuBarOnly:
            return false
        }
    }

    @discardableResult
    func evaluateFileDrag(
        at point: NSPoint,
        screens: [ScreenMetrics],
        hasDraggedFiles: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !isPanelVisible,
              hasDraggedFiles,
              now >= cooldownUntil,
              Self.isPointInFileDragTriggerZone(point, screens: screens) else {
            return false
        }
        if let activateForFileDrag {
            activateForFileDrag()
        } else {
            activate?()
        }
        return true
    }

    private func reconfigureMonitors() {
        removeMonitors()
        guard isStarted, !isPanelVisible else { return }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

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
        activeDragTimer?.invalidate()
        activeDragTimer = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleLiveEvent(type: NSEvent.EventType) {
        let point = NSEvent.mouseLocation
        let screens = Self.currentScreenMetrics()

        switch type {
        case .leftMouseDown:
            if !evaluateEvent(type: .leftMouseDown, at: point, screens: screens) {
                startDragWatchTimer()
            }
        case .leftMouseDragged:
            checkActiveFileDrag(at: point, screens: screens)
        case .leftMouseUp:
            activeDragTimer?.invalidate()
            activeDragTimer = nil
            syncDragPasteboardBaseline()
        default:
            break
        }
    }

    /// CoreDrag (e.g. Finder file drag loop) does not always emit global `.leftMouseDragged`
    /// NSEvents after `.leftMouseDown`, so a low-frequency timer runs strictly while the left
    /// mouse button remains pressed and stops immediately upon release.
    private func startDragWatchTimer() {
        guard activeDragTimer == nil, !isPanelVisible else { return }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.isPanelVisible, (NSEvent.pressedMouseButtons & 1) != 0 else {
                    self.activeDragTimer?.invalidate()
                    self.activeDragTimer = nil
                    if (NSEvent.pressedMouseButtons & 1) == 0 {
                        self.syncDragPasteboardBaseline()
                    }
                    return
                }
                self.checkActiveFileDrag(at: NSEvent.mouseLocation, screens: Self.currentScreenMetrics())
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        activeDragTimer = timer
    }

    private func checkActiveFileDrag(at point: NSPoint, screens: [ScreenMetrics]) {
        guard !isPanelVisible, (NSEvent.pressedMouseButtons & 1) != 0 else { return }
        let hasFiles = currentSessionHasDraggedFiles()
        _ = evaluateFileDrag(at: point, screens: screens, hasDraggedFiles: hasFiles)
    }

    private func currentSessionHasDraggedFiles() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        let currentCount = pasteboard.changeCount
        guard currentCount != baselineDragChangeCount else { return false }
        if inspectedDragChangeCount == currentCount {
            return inspectedDragHasFiles
        }
        inspectedDragChangeCount = currentCount
        inspectedDragHasFiles = pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return inspectedDragHasFiles
    }

    private func syncDragPasteboardBaselineIfIdle() {
        if (NSEvent.pressedMouseButtons & 1) == 0 {
            syncDragPasteboardBaseline()
        }
    }

    private func syncDragPasteboardBaseline() {
        baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
        inspectedDragChangeCount = nil
        inspectedDragHasFiles = false
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
