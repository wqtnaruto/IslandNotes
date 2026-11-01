import AppKit
import QuartzCore
import SwiftUI

struct PanelSafeLayout: Equatable, Sendable {
    let notchHeight: CGFloat
    let notchWidth: CGFloat

    init(safeAreaTop: CGFloat, notchWidth: CGFloat? = nil) {
        let height = round(max(0, safeAreaTop))
        self.notchHeight = height
        if let notchWidth {
            self.notchWidth = height > 0 ? round(max(0, notchWidth)) : 0
        } else {
            self.notchWidth = height > 0 ? 210 : 0
        }
    }

    @MainActor
    init(screen: NSScreen?) {
        guard let screen else {
            self.init(safeAreaTop: 0, notchWidth: 0)
            return
        }
        let measuredWidth: CGFloat?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            measuredWidth = max(0, right.minX - left.maxX)
        } else {
            measuredWidth = nil
        }
        self.init(safeAreaTop: screen.safeAreaInsets.top, notchWidth: measuredWidth)
    }

    /// Distance from screen top edge to the collapse chevron button (`42pt` on a 38pt notch, `2pt` on non-notch displays).
    var chevronTopOffset: CGFloat {
        notchHeight > 0 ? notchHeight + 4 : 2
    }

    /// Height of the top strip above the tab rail (`64pt` on a 38pt notch, `28pt` on non-notch displays).
    var topStripHeight: CGFloat {
        notchHeight > 0 ? notchHeight + 26 : 28
    }

    /// Distance from screen top edge to the top of the 37pt tab rail.
    var tabRailTopOffset: CGFloat {
        topStripHeight
    }

    /// Total header height including the 37pt tab rail and 1pt bottom divider (`102pt` on a 38pt notch, `66pt` on non-notch displays).
    var headerHeight: CGFloat {
        topStripHeight + 38
    }

    /// Extra window height added on notched displays so editor space is preserved.
    var extraPanelHeight: CGFloat {
        headerHeight - 66
    }

    /// Collapsed tuck height during show/hide slide animation.
    var collapsedRevealHeight: CGFloat {
        max(24, notchHeight)
    }
}

@MainActor
final class PanelLayoutState: ObservableObject {
    @Published private(set) var safeLayout: PanelSafeLayout

    init(safeLayout: PanelSafeLayout? = nil) {
        self.safeLayout = safeLayout ?? PanelSafeLayout(screen: NSScreen.main)
    }

    func update(for screen: NSScreen?) {
        let updated = PanelSafeLayout(screen: screen)
        if safeLayout != updated {
            safeLayout = updated
        }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var requestHide: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, shouldDismissOnEscape() {
            requestHide?()
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            if key == "n" {
                NotificationCenter.default.post(name: .islandNotesCreatePage, object: nil)
                return true
            }
            if key == "w" {
                requestHide?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard shouldDismissOnEscape() else { return }
        requestHide?()
    }

    private func shouldDismissOnEscape() -> Bool {
        if let inputClient = firstResponder as? NSTextInputClient, inputClient.hasMarkedText() {
            return false
        }
        // Allow SwiftUI TextField (e.g. tab title rename field editor) to handle Escape first.
        if let textView = firstResponder as? NSTextView, !(textView is TaskTextView) {
            return false
        }
        return true
    }
}

final class PanelClipView: NSView {
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension Notification.Name {
    static let islandNotesCreatePage = Notification.Name("IslandNotes.createPage")
    static let islandNotesPanelVisibility = Notification.Name("IslandNotes.panelVisibility")
}

@MainActor
final class PanelCoordinator {
    private let panel: KeyablePanel
    private let clipView: PanelClipView
    private let hostingView: NSView
    private let layoutState: PanelLayoutState
    private var screenObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var animationGeneration: UInt64 = 0
    private(set) var isPresented = false
    var onVisibilityChanged: ((Bool) -> Void)?

    init(layoutState: PanelLayoutState, rootView: some View) {
        self.layoutState = layoutState
        let initialRect = NSRect(x: 0, y: 0, width: 360, height: 380)
        panel = KeyablePanel(
            contentRect: initialRect,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        // The panel must cover the center of the menu bar to meet the notch at the screen edge.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        clipView = PanelClipView(frame: initialRect)
        let hosted = NSHostingView(rootView: rootView)
        hosted.frame = clipView.bounds
        hosted.autoresizingMask = [.width, .height]
        hosted.wantsLayer = true
        clipView.addSubview(hosted)
        hostingView = hosted

        panel.contentView = clipView
        panel.requestHide = { [weak self] in self?.hide() }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshGeometryForActiveScreen()
            }
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    var isVisible: Bool { isPresented }

    func dismissIfClickedOutside(at screenPoint: NSPoint) {
        guard Self.shouldDismissForExternalClick(
            at: screenPoint,
            panelFrame: panel.frame,
            isPresented: isPresented
        ) else { return }
        hide()
    }

    nonisolated static func shouldDismissForExternalClick(
        at screenPoint: NSPoint,
        panelFrame: NSRect,
        isPresented: Bool
    ) -> Bool {
        isPresented && !panelFrame.contains(screenPoint)
    }

    func toggle() {
        isPresented ? hide() : show()
    }

    func show() {
        guard !isPresented else { return }
        guard let screen = screenAtPointer() ?? NSScreen.main else { return }

        isPresented = true
        animationGeneration &+= 1
        let generation = animationGeneration

        layoutState.update(for: screen)
        let safeLayout = layoutState.safeLayout
        let expanded = expandedFrame(for: screen, safeLayout: safeLayout)

        let wasWindowOnScreen = panel.isVisible
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let collapsedOffset = max(0, expanded.height - safeLayout.collapsedRevealHeight)

        let clipLayer = clipView.layer
        let liveLayer = wasWindowOnScreen ? clipLayer?.presentation() : nil
        let startOffsetY: CGFloat = reduced ? 0 : (liveLayer?.sublayerTransform.m42 ?? collapsedOffset)
        let startOpacity: Float = liveLayer?.opacity ?? (reduced ? 0 : 0.25)

        if panel.frame != expanded {
            panel.setFrame(expanded, display: false)
            clipView.frame = NSRect(origin: .zero, size: expanded.size)
            hostingView.frame = clipView.bounds
        }
        clipView.layoutSubtreeIfNeeded()

        if let clipLayer {
            clipLayer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clipLayer.sublayerTransform = CATransform3DIdentity
            clipLayer.opacity = 1
            CATransaction.commit()

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.animationGeneration == generation, self.isPresented else { return }
                    self.clipView.layer?.sublayerTransform = CATransform3DIdentity
                    self.clipView.layer?.opacity = 1
                }
            }

            let duration: CFTimeInterval = reduced ? 0.12 : 0.20
            let timing = CAMediaTimingFunction(controlPoints: 0.18, 0.88, 0.25, 1.0)

            if !reduced, abs(startOffsetY) > 0.5 {
                let slide = CABasicAnimation(keyPath: "sublayerTransform")
                slide.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, startOffsetY, 0))
                slide.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                slide.duration = duration
                slide.timingFunction = timing
                clipLayer.add(slide, forKey: "panelSlide")
            }

            if abs(1 - startOpacity) > 0.01 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = startOpacity
                fade.toValue = Float(1)
                fade.duration = reduced ? duration : duration * 0.7
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clipLayer.add(fade, forKey: "panelFade")
            }
            CATransaction.commit()
        }

        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        notifyVisibility(true)
    }

    func hide() {
        guard isPresented else { return }
        isPresented = false
        animationGeneration &+= 1
        let generation = animationGeneration
        notifyVisibility(false)

        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let collapsedOffset = max(0, panel.frame.height - layoutState.safeLayout.collapsedRevealHeight)
        guard let clipLayer = clipView.layer else {
            panel.orderOut(nil)
            return
        }

        let liveLayer = clipLayer.presentation()
        let startOffsetY: CGFloat = reduced ? 0 : (liveLayer?.sublayerTransform.m42 ?? 0)
        let startOpacity: Float = liveLayer?.opacity ?? 1
        let targetTransform = reduced ? CATransform3DIdentity : CATransform3DMakeTranslation(0, collapsedOffset, 0)
        let targetOpacity: Float = 0

        clipLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.sublayerTransform = targetTransform
        clipLayer.opacity = targetOpacity
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.animationGeneration == generation, !self.isPresented else { return }
                self.panel.orderOut(nil)
            }
        }

        let duration: CFTimeInterval = reduced ? 0.11 : 0.16
        let timing = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.67, 1.0)

        if !reduced {
            let slide = CABasicAnimation(keyPath: "sublayerTransform")
            slide.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, startOffsetY, 0))
            slide.toValue = NSValue(caTransform3D: targetTransform)
            slide.duration = duration
            slide.timingFunction = timing
            clipLayer.add(slide, forKey: "panelSlide")
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = startOpacity
        fade.toValue = targetOpacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        clipLayer.add(fade, forKey: "panelFade")
        CATransaction.commit()
    }

    private func expandedFrame(for screen: NSScreen, safeLayout: PanelSafeLayout) -> NSRect {
        let rawWidth = min(760, max(620, screen.visibleFrame.width * 0.62)) / 2
        let baseHeight = min(820, max(620, screen.visibleFrame.height * 0.87)) / 2
        let maxAllowedHeight = max(320, screen.frame.height - 24)
        let width = round(rawWidth)
        let height = min(round(maxAllowedHeight), round(baseHeight + safeLayout.extraPanelHeight))
        return NSRect(
            x: round(screen.frame.midX - width / 2),
            y: round(screen.frame.maxY - height),
            width: width,
            height: height
        )
    }

    private func refreshGeometryForActiveScreen() {
        guard isPresented, let screen = panel.screen ?? screenAtPointer() ?? NSScreen.main else { return }
        layoutState.update(for: screen)
        let expanded = expandedFrame(for: screen, safeLayout: layoutState.safeLayout)
        if panel.frame != expanded {
            panel.setFrame(expanded, display: true)
            clipView.frame = NSRect(origin: .zero, size: expanded.size)
            hostingView.frame = clipView.bounds
        }
    }

    private func notifyVisibility(_ visible: Bool) {
        onVisibilityChanged?(visible)
        NotificationCenter.default.post(name: .islandNotesPanelVisibility, object: visible)
    }

    private func screenAtPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = WorkspaceStore()
    private let keepAwake = KeepAwakeController()
    private let reminder = BreakReminder()
    private let activationMonitor = TopEdgeActivationMonitor()
    private let layoutState = PanelLayoutState()
    private var panel: PanelCoordinator!
    private var statusItem: NSStatusItem!
    private var outsideClickMonitor: Any?
    private var outsideClickPollTimer: Timer?
    private var previousPressedMouseButtons = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        panel = PanelCoordinator(
            layoutState: layoutState,
            rootView: ContentView(
                store: store,
                reminder: reminder,
                layoutState: layoutState,
                onClose: { [weak self] in self?.panel.hide() },
                preferencesChanged: { [weak self] in self?.applyPreferences() }
            )
        )
        panel.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.activationMonitor.notifyPanelVisibilityChanged(visible)
            self.reminder.setPanelVisible(visible)
            self.setOutsideClickPollingEnabled(visible)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "IslandNotes")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        activationMonitor.activate = { [weak self] in self?.panel.show() }
        applyPreferences()
        activationMonitor.start()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.panel.dismissIfClickedOutside(at: point)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activationMonitor.stop()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        setOutsideClickPollingEnabled(false)
        store.save()
        keepAwake.setEnabled(false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    @objc private func togglePanel() { panel.toggle() }

    private func setOutsideClickPollingEnabled(_ enabled: Bool) {
        outsideClickPollTimer?.invalidate()
        outsideClickPollTimer = nil
        previousPressedMouseButtons = enabled ? NSEvent.pressedMouseButtons : 0
        guard enabled else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pressed = NSEvent.pressedMouseButtons
                let newlyPressed = pressed & ~self.previousPressedMouseButtons
                self.previousPressedMouseButtons = pressed
                guard newlyPressed != 0 else { return }
                self.panel.dismissIfClickedOutside(at: NSEvent.mouseLocation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        outsideClickPollTimer = timer
    }

    private func applyPreferences() {
        let preferences = store.preferences
        activationMonitor.mode = preferences.activationMode
        keepAwake.setEnabled(preferences.keepAwake)
        reminder.configure(
            enabled: preferences.breakReminderEnabled,
            intervalMinutes: preferences.breakIntervalMinutes
        )
    }
}
