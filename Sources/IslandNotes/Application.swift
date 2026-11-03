import AppKit
import Carbon.HIToolbox
import QuartzCore
import SwiftUI

struct PanelSafeLayout: Equatable, Sendable {
    let notchHeight: CGFloat
    let notchWidth: CGFloat
    let availableLeftWidth: CGFloat
    let availableRightWidth: CGFloat

    init(
        safeAreaTop: CGFloat,
        notchWidth: CGFloat? = nil,
        availableLeftWidth: CGFloat = 600,
        availableRightWidth: CGFloat = 600
    ) {
        let height = round(max(0, safeAreaTop))
        self.notchHeight = height
        if let notchWidth {
            self.notchWidth = height > 0 ? round(max(0, notchWidth)) : 0
        } else {
            self.notchWidth = height > 0 ? 210 : 0
        }
        self.availableLeftWidth = max(56, round(availableLeftWidth))
        self.availableRightWidth = max(76, round(availableRightWidth))
    }

    @MainActor
    init(screen: NSScreen?) {
        guard let screen else {
            self.init(safeAreaTop: 0, notchWidth: 0)
            return
        }
        let measuredWidth: CGFloat?
        let leftSpace: CGFloat
        let rightSpace: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            measuredWidth = max(0, right.minX - left.maxX)
            leftSpace = max(56, left.width - 140)
            rightSpace = max(76, right.width - 140)
        } else {
            measuredWidth = nil
            leftSpace = max(56, screen.frame.width / 2 - 220)
            rightSpace = max(76, screen.frame.width / 2 - 220)
        }
        self.init(
            safeAreaTop: screen.safeAreaInsets.top,
            notchWidth: measuredWidth,
            availableLeftWidth: leftSpace,
            availableRightWidth: rightSpace
        )
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
    @Published var isPinned: Bool

    init(safeLayout: PanelSafeLayout? = nil, isPinned: Bool = false) {
        self.safeLayout = safeLayout ?? PanelSafeLayout(screen: NSScreen.main)
        self.isPinned = isPinned
    }

    func update(for screen: NSScreen?) {
        let updated = PanelSafeLayout(screen: screen)
        if safeLayout != updated {
            safeLayout = updated
        }
    }

    func togglePin() {
        isPinned.toggle()
    }
}

enum MainMenuBuilder {
    @MainActor
    static func install() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: L10n.string("Quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())

        let findItem = NSMenuItem(
            title: "Find",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        findItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        editMenu.addItem(findItem)

        let findNextItem = NSMenuItem(
            title: "Find Next",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        )
        findNextItem.tag = Int(NSFindPanelAction.next.rawValue)
        editMenu.addItem(findNextItem)

        let findPrevItem = NSMenuItem(
            title: "Find Previous",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        )
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.tag = Int(NSFindPanelAction.previous.rawValue)
        editMenu.addItem(findPrevItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
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
        if event.type == .leftMouseDown, !NSApp.isActive {
            NSApp.activate()
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) {
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command] {
            switch key {
            case "n":
                NotificationCenter.default.post(name: .islandNotesCreatePage, object: nil)
                return true
            case "w":
                requestHide?()
                return true
            case "a":
                if firstResponder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: self) == true {
                    return true
                }
            case "c":
                if firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: self) == true {
                    return true
                }
            case "v":
                if firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: self) == true {
                    return true
                }
            case "x":
                if firstResponder?.tryToPerform(#selector(NSText.cut(_:)), with: self) == true {
                    return true
                }
            case "z":
                if firstResponder?.tryToPerform(Selector(("undo:")), with: self) == true {
                    return true
                }
            case "f":
                if dispatchFindPanelAction(.showFindPanel) {
                    return true
                }
            case "g":
                if dispatchFindPanelAction(.next) {
                    return true
                }
            default:
                break
            }
        } else if flags == [.command, .shift] {
            switch key {
            case "z":
                if firstResponder?.tryToPerform(Selector(("redo:")), with: self) == true {
                    return true
                }
            case "g":
                if dispatchFindPanelAction(.previous) {
                    return true
                }
            default:
                break
            }
        }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return false
    }

    private func dispatchFindPanelAction(_ action: NSFindPanelAction) -> Bool {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        return firstResponder?.tryToPerform(#selector(NSTextView.performFindPanelAction(_:)), with: item) == true
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
    static let islandNotesScreenshotCaptured = Notification.Name("IslandNotes.screenshotCaptured")
}

final class GlobalHotKeyController {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<GlobalHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                controller.action()
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: 0x494E5353, id: 1) // INSS
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            self.eventHandler = nil
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

@MainActor
final class PanelCoordinator {
    private let panel: KeyablePanel
    private let clipView: PanelClipView
    private let hostingView: NSView
    private let layoutState: PanelLayoutState
    private var screenObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var fileDropWatchTimer: Timer?
    private var animationGeneration: UInt64 = 0
    private var isAwaitingFileDrop = false
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
        // Observe key resignation across ALL app windows (including SwiftUI popovers)
        // so switching apps via Cmd+Tab while a popover is open also hides an unpinned panel.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await Task.yield()
                guard self.isPresented,
                      !self.layoutState.isPinned,
                      !self.isAwaitingFileDrop,
                      !self.hasActiveMarkedText else { return }
                if NSApp.keyWindow != nil {
                    return
                }
                self.hide()
            }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await Task.yield()
                guard self.isPresented,
                      !self.layoutState.isPinned,
                      !self.isAwaitingFileDrop,
                      !self.hasActiveMarkedText,
                      NSApp.keyWindow == nil else { return }
                self.hide()
            }
        }
    }

    deinit {
        fileDropWatchTimer?.invalidate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
    }

    var isVisible: Bool { isPresented }
    var currentScreen: NSScreen? { panel.screen }

    private var hasActiveMarkedText: Bool {
        (panel.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    func focusPanel() {
        guard isPresented else { return }
        isAwaitingFileDrop = false
        fileDropWatchTimer?.invalidate()
        fileDropWatchTimer = nil
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissIfClickedOutside(at screenPoint: NSPoint) {
        guard !isAwaitingFileDrop else { return }
        let insideRelatedWindow = NSApp.windows.contains { window in
            window !== panel && window.isVisible && window.frame.contains(screenPoint)
        }
        guard !insideRelatedWindow else { return }
        guard Self.shouldDismissForExternalClick(
            at: screenPoint,
            panelFrame: panel.frame,
            isPresented: isPresented,
            isPinned: layoutState.isPinned,
            hasMarkedText: hasActiveMarkedText
        ) else { return }
        hide()
    }

    nonisolated static func shouldDismissForExternalClick(
        at screenPoint: NSPoint,
        panelFrame: NSRect,
        isPresented: Bool,
        isPinned: Bool = false,
        hasMarkedText: Bool = false
    ) -> Bool {
        isPresented && !isPinned && !hasMarkedText && !panelFrame.contains(screenPoint)
    }

    func toggle() {
        isPresented ? hide() : show()
    }

    func show(initiatedByFileDrag: Bool = false, activateApp: Bool = true) {
        guard !isPresented else { return }
        guard let screen = screenAtPointer() ?? NSScreen.main else { return }

        isPresented = true
        isAwaitingFileDrop = initiatedByFileDrag
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
        if initiatedByFileDrag {
            panel.orderFrontRegardless()
            watchActiveFileDragCompletion()
        } else if activateApp {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        notifyVisibility(true)
    }

    func hide() {
        guard isPresented else { return }
        isPresented = false
        isAwaitingFileDrop = false
        fileDropWatchTimer?.invalidate()
        fileDropWatchTimer = nil
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

    private func watchActiveFileDragCompletion() {
        fileDropWatchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.isPresented, self.isAwaitingFileDrop else {
                    self.fileDropWatchTimer?.invalidate()
                    self.fileDropWatchTimer = nil
                    return
                }
                guard (NSEvent.pressedMouseButtons & 1) == 0 else { return }
                self.isAwaitingFileDrop = false
                self.fileDropWatchTimer?.invalidate()
                self.fileDropWatchTimer = nil

                let releasePoint = NSEvent.mouseLocation
                if self.panel.frame.contains(releasePoint) || self.layoutState.isPinned {
                    NSApp.activate()
                    self.panel.makeKeyAndOrderFront(nil)
                } else {
                    self.hide()
                }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        fileDropWatchTimer = timer
    }

    private func expandedFrame(for screen: NSScreen, safeLayout: PanelSafeLayout) -> NSRect {
        let width = round(min(380, max(310, screen.visibleFrame.width * 0.31)))
        let baseHeight = min(410, max(310, screen.visibleFrame.height * 0.435))
        let maxAllowedHeight = max(320, screen.frame.height - 24)
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
    private let screenshotCaptureService: any ScreenshotCapturing = SystemScreenshotCaptureService()
    private let keepAwake = KeepAwakeController()
    private let reminder = BreakReminder()
    private let activationMonitor = TopEdgeActivationMonitor()
    private let layoutState = PanelLayoutState()
    private var panel: PanelCoordinator!
    private var notchIsland: NotchIslandCoordinator!
    private var statusItem: NSStatusItem!
    private var outsideClickMonitor: Any?
    private var screenshotTask: Task<Void, Never>?
    private var captureHotKey: GlobalHotKeyController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        MainMenuBuilder.install()

        panel = PanelCoordinator(
            layoutState: layoutState,
            rootView: ContentView(
                store: store,
                reminder: reminder,
                layoutState: layoutState,
                onClose: { [weak self] in self?.panel.hide() },
                preferencesChanged: { [weak self] in self?.applyPreferences() },
                captureScreenshot: { [weak self] in self?.beginScreenshotCapture() },
                onShelfFilesDropped: { [weak self] in self?.panel.focusPanel() }
            )
        )
        panel.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.activationMonitor.notifyPanelVisibilityChanged(visible)
            self.reminder.setPanelVisible(visible)
            self.notchIsland.setMainPanelVisible(visible, activeScreen: self.panel.currentScreen)
        }
        notchIsland = NotchIslandCoordinator(
            store: store,
            reminder: reminder,
            layoutState: layoutState,
            onExpandPanel: { [weak self] in
                self?.panel.show()
            },
            onFilesDropped: { [weak self] urls in
                guard let self else { return false }
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                _ = self.store.addShelfURLs(files)
                self.panel.show()
                return true
            }
        )
        notchIsland.onVisibilityChanged = { [weak self] visible in
            self?.reminder.setIslandVisible(visible)
        }
        reminder.onBreakTriggered = { [weak self] in
            self?.panel.show(activateApp: false)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "IslandNotes")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        activationMonitor.activate = { [weak self] in
            self?.panel.show()
        }
        activationMonitor.activateForFileDrag = { [weak self] in
            self?.panel.show(initiatedByFileDrag: true)
        }
        captureHotKey = GlobalHotKeyController(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.beginScreenshotCapture() }
        }
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
        screenshotTask?.cancel()
        screenshotTask = nil
        captureHotKey = nil
        activationMonitor.stop()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        store.save()
        keepAwake.setEnabled(false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    @objc private func togglePanel() { panel.toggle() }

    private func beginScreenshotCapture() {
        guard screenshotTask == nil else { return }
        let wasVisible = panel.isVisible
        store.reportExternalError(nil)
        notchIsland.setSuppressed(true)
        if wasVisible { panel.hide() }

        screenshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.notchIsland.setSuppressed(false)
                self.screenshotTask = nil
            }

            if wasVisible {
                try? await Task.sleep(nanoseconds: 240_000_000)
                guard !Task.isCancelled else { return }
            }

            var temporaryURL: URL?
            do {
                let destination = try self.store.makeTemporaryScreenshotURL()
                temporaryURL = destination
                let result = try await self.screenshotCaptureService.capture(to: destination)
                guard !Task.isCancelled else {
                    self.store.discardTemporaryScreenshot(at: destination)
                    return
                }

                switch result {
                case let .captured(capture):
                    _ = try self.store.commitScreenshot(
                        at: capture.url,
                        pixelWidth: capture.pixelWidth,
                        pixelHeight: capture.pixelHeight
                    )
                    self.panel.show()
                    NotificationCenter.default.post(name: .islandNotesScreenshotCaptured, object: nil)
                case .cancelled:
                    self.store.discardTemporaryScreenshot(at: destination)
                    if wasVisible { self.panel.show() }
                }
            } catch {
                if let temporaryURL { self.store.discardTemporaryScreenshot(at: temporaryURL) }
                self.store.reportExternalError(error.localizedDescription)
                self.panel.show()
            }
        }
    }

    private func applyPreferences() {
        let preferences = store.preferences
        activationMonitor.mode = preferences.activationMode
        keepAwake.setEnabled(preferences.keepAwake)
        reminder.configure(
            enabled: preferences.breakReminderEnabled,
            intervalMinutes: preferences.breakIntervalMinutes
        )
        notchIsland?.refreshForPreferencesChange()
    }
}
