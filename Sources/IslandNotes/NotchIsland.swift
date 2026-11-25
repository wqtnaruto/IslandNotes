import AppKit
import Combine
import SwiftUI

struct NotchIslandSnapshot: Equatable, Sendable {
    let noteID: UUID
    let noteTitle: String
    let pinnedTask: MarkdownPresentation.PinnedTaskItem?
    let completedPreviewText: String?
    let uncheckedCount: Int
    let completedCount: Int
    let focusActive: Bool
    let remainingMinutes: Int
    let focusProgress: Double
    let keepAwake: Bool
    let themeMode: ThemeMode
    let islandEnabled: Bool
    let preview: IslandPreview
    let codexActivity: CodexActivity
    let isPeeking: Bool
    let isMainPanelVisible: Bool
    let isSuppressed: Bool

    var totalTaskCount: Int { uncheckedCount + completedCount }

    var effectiveTaskText: String? {
        completedPreviewText ?? pinnedTask?.displayText
    }

    var isShowingCompletedFeedback: Bool {
        completedPreviewText != nil
    }

    var hasProgressOrBreathingBar: Bool {
        focusActive || keepAwake
    }

    var hasNotesActivity: Bool {
        focusActive || keepAwake || effectiveTaskText != nil
    }

    var hasCodexContent: Bool {
        preview == .codex || !codexActivity.tasks.isEmpty
    }

    var showsCodexBadge: Bool {
        !codexActivity.tasks.isEmpty || (preview == .codex && !hasNotesActivity)
    }

    var shouldPresent: Bool {
        islandEnabled && !isMainPanelVisible && !isSuppressed && (hasNotesActivity || hasCodexContent || isPeeking)
    }
}

struct NotchIslandLayout: Equatable, Sendable {
    static let canvasWidth: CGFloat = 700
    static let topEarRadius: CGFloat = 8
    static let previewPickerHeight: CGFloat = 36
    static let noteHeaderHeight: CGFloat = 24
    static let noteRowHeight: CGFloat = 38
    static let codexRowHeight: CGFloat = 42
    static let visibleCodexRows = 3
    static let previewBottomPadding: CGFloat = 8

    let isNotched: Bool
    let isPeeking: Bool
    let isRetracted: Bool
    let centerNotchWidth: CGFloat

    /// Invariant compact wing dimensions (used by the compact layer so its internal layout never shifts during morph).
    let compactLeftWingWidth: CGFloat
    let compactRightWingWidth: CGFloat
    let compactBodyHeight: CGFloat

    /// Expanded wing widths stay stable across preview modes.
    let peekLeftWingWidth: CGFloat
    let peekRightWingWidth: CGFloat
    let peekBodyHeight: CGFloat

    /// Active silhouette dimensions for the current state (retracted / compact / peek).
    let leftWingWidth: CGFloat
    let rightWingWidth: CGFloat
    let bodyHeight: CGFloat
    let bottomCornerRadius: CGFloat
    let windowHeight: CGFloat

    var leftSpan: CGFloat {
        centerNotchWidth / 2 + leftWingWidth
    }

    var rightSpan: CGFloat {
        centerNotchWidth / 2 + rightWingWidth
    }

    var totalBodyWidth: CGFloat {
        leftWingWidth + centerNotchWidth + rightWingWidth
    }

    var compactTotalBodyWidth: CGFloat {
        compactLeftWingWidth + centerNotchWidth + compactRightWingWidth
    }

    var peekTotalBodyWidth: CGFloat {
        peekLeftWingWidth + centerNotchWidth + peekRightWingWidth
    }

    var interactiveRect: CGRect {
        guard !isRetracted else { return .zero }
        let midX = Self.canvasWidth / 2
        let minX = midX - leftSpan - Self.topEarRadius
        let width = totalBodyWidth + Self.topEarRadius * 2
        return CGRect(x: minX, y: 0, width: width, height: bodyHeight)
    }

    /// The host window fits the largest preview so hovering never resizes it.
    static func fixedWindowHeight(for safeLayout: PanelSafeLayout) -> CGFloat {
        previewTopInset(for: safeLayout) + previewPickerHeight
            + codexRowHeight * CGFloat(visibleCodexRows) + previewBottomPadding
    }

    static func previewTopInset(for safeLayout: PanelSafeLayout) -> CGFloat {
        safeLayout.notchHeight > 0 ? max(30, safeLayout.notchHeight) : 0
    }

    static func codexListHeight(count: Int) -> CGFloat {
        codexRowHeight * CGFloat(max(1, min(count, visibleCodexRows)))
    }

    static func compute(
        safeLayout: PanelSafeLayout,
        snapshot: NotchIslandSnapshot,
        isPeeking: Bool,
        isRetracted: Bool = false
    ) -> NotchIslandLayout {
        let hasNotch = safeLayout.notchHeight > 0
        let fixedWinHeight = fixedWindowHeight(for: safeLayout)
        let detailHeight = snapshot.preview == .codex
            ? codexListHeight(count: snapshot.codexActivity.tasks.count)
            : noteRowHeight + (hasNotch ? 0 : noteHeaderHeight)
        let peekHeight = previewTopInset(for: safeLayout) + previewPickerHeight + detailHeight + previewBottomPadding

        if hasNotch {
            let compactHeight = safeLayout.notchHeight + (snapshot.hasProgressOrBreathingBar ? 3 : 1)

            let maxCompactLeft = max(58, min(102, safeLayout.availableLeftWidth))
            let maxCompactRight = max(84, min(114, safeLayout.availableRightWidth))

            let notesLeft: CGFloat
            let compactRight: CGFloat
            if let taskText = snapshot.effectiveTaskText {
                let rawLeft: CGFloat
                if snapshot.focusActive {
                    rawLeft = 72
                } else if snapshot.keepAwake {
                    rawLeft = 60
                } else {
                    rawLeft = 56
                }
                notesLeft = min(maxCompactLeft, rawLeft)
                let estimatedTask = ceil(estimateTextWidth(taskText, asciiAdvance: 6.4, cjkAdvance: 11.3)) + 36
                compactRight = min(maxCompactRight, max(84, estimatedTask))
            } else {
                let wing = min(min(maxCompactLeft, maxCompactRight), snapshot.focusActive ? 62 : 56)
                notesLeft = wing
                compactRight = wing
            }
            let showsNotesStatus = snapshot.focusActive || snapshot.keepAwake
            let compactLeft = snapshot.showsCodexBadge && showsNotesStatus
                ? min(maxCompactLeft, notesLeft + 36)
                : notesLeft

            // Symmetric, content-stable below-notch card width that strictly expands outward beyond compact wings
            // so hovering never shrinks either wing away from the pointer and sequential task completions don't shift `☐`.
            let symmetricCap = max(92, min(144, min(safeLayout.availableLeftWidth, safeLayout.availableRightWidth)))
            let targetCardWing = min(symmetricCap, snapshot.effectiveTaskText != nil ? 118 : 96)
            let peekLeft = max(compactLeft + 6, targetCardWing)
            let peekRight = max(compactRight + 6, targetCardWing)

            let activeLeft: CGFloat
            let activeRight: CGFloat
            let activeHeight: CGFloat
            let cornerRadius: CGFloat

            if isRetracted {
                activeLeft = 0
                activeRight = 0
                activeHeight = max(24, safeLayout.notchHeight)
                cornerRadius = 10
            } else if isPeeking {
                activeLeft = peekLeft
                activeRight = peekRight
                activeHeight = peekHeight
                cornerRadius = 15
            } else {
                activeLeft = compactLeft
                activeRight = compactRight
                activeHeight = compactHeight
                cornerRadius = 10
            }

            return NotchIslandLayout(
                isNotched: true,
                isPeeking: isPeeking,
                isRetracted: isRetracted,
                centerNotchWidth: safeLayout.notchWidth,
                compactLeftWingWidth: compactLeft,
                compactRightWingWidth: compactRight,
                compactBodyHeight: compactHeight,
                peekLeftWingWidth: peekLeft,
                peekRightWingWidth: peekRight,
                peekBodyHeight: peekHeight,
                leftWingWidth: activeLeft,
                rightWingWidth: activeRight,
                bodyHeight: activeHeight,
                bottomCornerRadius: cornerRadius,
                windowHeight: fixedWinHeight
            )
        } else {
            let compactHeight: CGFloat = snapshot.hasProgressOrBreathingBar ? 26 : 24

            let notesWidth: CGFloat
            if let taskText = snapshot.effectiveTaskText {
                let statusWidth: CGFloat = (snapshot.focusActive || snapshot.keepAwake) ? 72 : 0
                let taskWidth = min(158, max(76, ceil(estimateTextWidth(taskText, asciiAdvance: 6.4, cjkAdvance: 11.3)) + 34))
                notesWidth = min(264, max(128, statusWidth + taskWidth + 16))
            } else {
                notesWidth = snapshot.focusActive ? 124 : 106
            }
            let compactTotal = notesWidth + (snapshot.showsCodexBadge && snapshot.hasNotesActivity ? 46 : 0)
            let compactHalf = round(compactTotal / 2)
            let peekHalf = max(compactHalf + 18, snapshot.effectiveTaskText != nil ? 166 : 148)

            let activeHalf: CGFloat
            let activeHeight: CGFloat
            let cornerRadius: CGFloat
            if isRetracted {
                activeHalf = 36
                activeHeight = 18
                cornerRadius = 9
            } else if isPeeking {
                activeHalf = peekHalf
                activeHeight = peekHeight
                cornerRadius = 14
            } else {
                activeHalf = compactHalf
                activeHeight = compactHeight
                cornerRadius = 10
            }

            return NotchIslandLayout(
                isNotched: false,
                isPeeking: isPeeking,
                isRetracted: isRetracted,
                centerNotchWidth: 0,
                compactLeftWingWidth: compactHalf,
                compactRightWingWidth: compactHalf,
                compactBodyHeight: compactHeight,
                peekLeftWingWidth: peekHalf,
                peekRightWingWidth: peekHalf,
                peekBodyHeight: peekHeight,
                leftWingWidth: activeHalf,
                rightWingWidth: activeHalf,
                bodyHeight: activeHeight,
                bottomCornerRadius: cornerRadius,
                windowHeight: fixedWinHeight
            )
        }
    }

    static func estimateTextWidth(_ text: String, asciiAdvance: CGFloat, cjkAdvance: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for ch in text {
            total += ch.isASCII ? asciiAdvance : cjkAdvance
        }
        return total
    }
}

/// Continuously animatable island silhouette anchored around `rect.midX` so the hardware notch
/// cutout never shifts or quantizes while morphing between compact wings and the two-line card.
struct CanvasIslandSilhouetteShape: Shape {
    var leftSpan: CGFloat
    var rightSpan: CGFloat
    var bodyHeight: CGFloat
    var bottomCornerRadius: CGFloat
    var topEarRadius: CGFloat = NotchIslandLayout.topEarRadius

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(leftSpan, rightSpan),
                AnimatablePair(bodyHeight, bottomCornerRadius)
            )
        }
        set {
            leftSpan = newValue.first.first
            rightSpan = newValue.first.second
            bodyHeight = newValue.second.first
            bottomCornerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        let leftX = midX - leftSpan
        let rightX = midX + rightSpan
        let bodyWidth = max(0, rightX - leftX)
        let maxY = min(rect.maxY, max(8, bodyHeight))
        let ear = min(topEarRadius, bodyWidth / 4, maxY / 2)
        let corner = min(bottomCornerRadius, bodyWidth / 2, max(0, maxY - ear))

        var path = Path()
        path.move(to: CGPoint(x: leftX - ear, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: leftX, y: ear),
            control: CGPoint(x: leftX, y: 0)
        )
        path.addLine(to: CGPoint(x: leftX, y: maxY - corner))
        path.addQuadCurve(
            to: CGPoint(x: leftX + corner, y: maxY),
            control: CGPoint(x: leftX, y: maxY)
        )
        path.addLine(to: CGPoint(x: rightX - corner, y: maxY))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: maxY - corner),
            control: CGPoint(x: rightX, y: maxY)
        )
        path.addLine(to: CGPoint(x: rightX, y: ear))
        path.addQuadCurve(
            to: CGPoint(x: rightX + ear, y: 0),
            control: CGPoint(x: rightX, y: 0)
        )
        path.closeSubpath()
        return path
    }
}

struct CanvasIslandRimShape: Shape {
    var leftSpan: CGFloat
    var rightSpan: CGFloat
    var bodyHeight: CGFloat
    var bottomCornerRadius: CGFloat
    var topEarRadius: CGFloat = NotchIslandLayout.topEarRadius

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(leftSpan, rightSpan),
                AnimatablePair(bodyHeight, bottomCornerRadius)
            )
        }
        set {
            leftSpan = newValue.first.first
            rightSpan = newValue.first.second
            bodyHeight = newValue.second.first
            bottomCornerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        let leftX = midX - leftSpan
        let rightX = midX + rightSpan
        let bodyWidth = max(0, rightX - leftX)
        let maxY = min(rect.maxY, max(8, bodyHeight))
        let ear = min(topEarRadius, bodyWidth / 4, maxY / 2)
        let corner = min(bottomCornerRadius, bodyWidth / 2, max(0, maxY - ear))

        var path = Path()
        path.move(to: CGPoint(x: leftX, y: ear))
        path.addLine(to: CGPoint(x: leftX, y: maxY - corner))
        path.addQuadCurve(
            to: CGPoint(x: leftX + corner, y: maxY),
            control: CGPoint(x: leftX, y: maxY)
        )
        path.addLine(to: CGPoint(x: rightX - corner, y: maxY))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: maxY - corner),
            control: CGPoint(x: rightX, y: maxY)
        )
        path.addLine(to: CGPoint(x: rightX, y: ear))
        return path
    }
}

@MainActor
final class NotchIslandModel: ObservableObject {
    @Published private(set) var snapshot: NotchIslandSnapshot
    @Published var isPeeking = false {
        didSet {
            if oldValue != isPeeking { refreshSnapshot() }
        }
    }
    @Published var isRetracted = false

    private let store: WorkspaceStore
    private let reminder: BreakReminder
    private var cancellables: Set<AnyCancellable> = []
    private var completionFeedbackTask: Task<Void, Never>?
    private var completedPreviewText: String?
    private var codexActivity: CodexActivity = .loading
    private var isMainPanelVisible = false
    private var isSuppressed = false

    init(store: WorkspaceStore, reminder: BreakReminder) {
        self.store = store
        self.reminder = reminder
        self.snapshot = Self.makeSnapshot(
            store: store,
            reminder: reminder,
            completedPreviewText: nil,
            codexActivity: .loading,
            isPeeking: false,
            isMainPanelVisible: false,
            isSuppressed: false
        )

        store.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshSnapshot()
                }
            }
            .store(in: &cancellables)

        reminder.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshSnapshot()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        completionFeedbackTask?.cancel()
    }

    func setMainPanelVisible(_ visible: Bool) {
        guard isMainPanelVisible != visible else { return }
        isMainPanelVisible = visible
        if visible {
            isPeeking = false
            completionFeedbackTask?.cancel()
            completionFeedbackTask = nil
            completedPreviewText = nil
        }
        refreshSnapshot()
    }

    func setSuppressed(_ suppressed: Bool) {
        guard isSuppressed != suppressed else { return }
        isSuppressed = suppressed
        if suppressed {
            isPeeking = false
            isRetracted = false
        }
        refreshSnapshot()
    }

    func selectPreview(_ preview: IslandPreview) {
        store.updatePreferences { $0.islandPreview = preview }
        refreshSnapshot()
    }

    func setCodexActivity(_ activity: CodexActivity) {
        guard !Task.isCancelled, codexActivity != activity else { return }
        codexActivity = activity
        refreshSnapshot()
    }

    func completeCurrentPinnedTask() {
        guard completedPreviewText == nil,
              let task = snapshot.pinnedTask else { return }
        let completedTitle = task.displayText
        let noteID = snapshot.noteID
        guard store.completeTask(atStateLocation: task.stateLocation, in: noteID) else {
            refreshSnapshot()
            return
        }

        completedPreviewText = completedTitle
        refreshSnapshot()

        completionFeedbackTask?.cancel()
        completionFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard let self, !Task.isCancelled else { return }

            let nextOverview = MarkdownPresentation.taskOverview(in: self.store.activeNote.markdown)
            let willHideAfterFeedback = nextOverview.firstUnchecked == nil
                && self.reminder.nextBreakAt == nil
                && !self.store.preferences.keepAwake
                && !self.snapshot.hasCodexContent

            if willHideAfterFeedback {
                self.isPeeking = false
                self.isRetracted = true
                try? await Task.sleep(nanoseconds: 210_000_000)
                guard !Task.isCancelled else { return }
            }

            self.completedPreviewText = nil
            self.isRetracted = false
            self.refreshSnapshot()
        }
    }

    func refreshSnapshot() {
        let updated = Self.makeSnapshot(
            store: store,
            reminder: reminder,
            completedPreviewText: completedPreviewText,
            codexActivity: codexActivity,
            isPeeking: isPeeking,
            isMainPanelVisible: isMainPanelVisible,
            isSuppressed: isSuppressed
        )
        if snapshot != updated {
            snapshot = updated
        }
        if !updated.shouldPresent, isPeeking {
            isPeeking = false
        }
    }

    private static func makeSnapshot(
        store: WorkspaceStore,
        reminder: BreakReminder,
        completedPreviewText: String?,
        codexActivity: CodexActivity,
        isPeeking: Bool,
        isMainPanelVisible: Bool,
        isSuppressed: Bool
    ) -> NotchIslandSnapshot {
        let activeNote = store.activeNote
        let overview = MarkdownPresentation.taskOverview(in: activeNote.markdown)
        return NotchIslandSnapshot(
            noteID: activeNote.id,
            noteTitle: activeNote.title,
            pinnedTask: overview.firstUnchecked,
            completedPreviewText: completedPreviewText,
            uncheckedCount: overview.uncheckedCount,
            completedCount: overview.completedCount,
            focusActive: reminder.nextBreakAt != nil,
            remainingMinutes: reminder.remainingMinutes,
            focusProgress: reminder.progress,
            keepAwake: store.preferences.keepAwake,
            themeMode: store.preferences.themeMode,
            islandEnabled: store.preferences.notchIslandEnabled,
            preview: store.preferences.islandPreview,
            codexActivity: codexActivity,
            isPeeking: isPeeking,
            isMainPanelVisible: isMainPanelVisible,
            isSuppressed: isSuppressed
        )
    }
}

struct NotchIslandView: View {
    @ObservedObject var model: NotchIslandModel
    @ObservedObject var layoutState: PanelLayoutState
    let onExpandPanel: () -> Void
    let onFilesDropped: ([URL]) -> Bool

    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringCheckbox = false
    @State private var failedCodexTaskID: UUID?

    private static let islandBackground = Color(red: 5/255, green: 5/255, blue: 7/255)
    private static let islandSecondary = Color.white.opacity(0.66)

    private var accentColor: Color {
        let mode = model.snapshot.themeMode
        let useDarkPalette = mode == .dark || (mode == .system && systemScheme == .dark)
        return VisualTheme(isDark: useDarkPalette).accent
    }

    private var focusColor: Color {
        Color(red: 1, green: 184/255, blue: 41/255)
    }

    private var currentLayout: NotchIslandLayout {
        NotchIslandLayout.compute(
            safeLayout: layoutState.safeLayout,
            snapshot: model.snapshot,
            isPeeking: model.isPeeking,
            isRetracted: model.isRetracted
        )
    }

    private var morphSpring: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.14)
        }
        return .spring(response: 0.32, dampingFraction: 0.90, blendDuration: 0.08)
    }

    private var retractSpring: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.10)
        }
        return .spring(response: 0.24, dampingFraction: 0.94, blendDuration: 0.06)
    }

    private var compactOpacityAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.10)
        }
        return model.isPeeking
            ? .easeOut(duration: 0.10)
            : .easeOut(duration: 0.16).delay(0.07)
    }

    private var cardOpacityAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.10)
        }
        return model.isPeeking
            ? .easeOut(duration: 0.18).delay(0.05)
            : .easeOut(duration: 0.09)
    }

    var body: some View {
        let layout = currentLayout
        let silhouette = CanvasIslandSilhouetteShape(
            leftSpan: layout.leftSpan,
            rightSpan: layout.rightSpan,
            bodyHeight: layout.bodyHeight,
            bottomCornerRadius: layout.bottomCornerRadius
        )
        let rim = CanvasIslandRimShape(
            leftSpan: layout.leftSpan,
            rightSpan: layout.rightSpan,
            bodyHeight: layout.bodyHeight,
            bottomCornerRadius: layout.bottomCornerRadius
        )

        ZStack(alignment: .top) {
            Color.clear
                .allowsHitTesting(false)

            if model.snapshot.shouldPresent {
                ZStack(alignment: .top) {
                    // 1. Liquid-morphing black island silhouette
                    silhouette
                        .fill(Self.islandBackground)
                        .animation(morphSpring, value: model.isPeeking)
                        .animation(retractSpring, value: model.isRetracted)
                        .animation(morphSpring, value: model.snapshot.effectiveTaskText)
                        .animation(morphSpring, value: model.snapshot.focusActive)
                        .animation(morphSpring, value: model.snapshot.keepAwake)
                        .allowsHitTesting(false)

                    // Keep the compact and expanded layers mounted at stable widths during the morph.
                    ZStack(alignment: .top) {
                        compactForeground(layout: layout)
                            .opacity((layout.isPeeking || layout.isRetracted) ? 0 : 1)
                            .animation(compactOpacityAnimation, value: model.isPeeking)
                            .offset(y: layout.isPeeking ? -2 : 0)
                            .animation(morphSpring, value: model.isPeeking)
                            .animation(retractSpring, value: model.isRetracted)
                            .allowsHitTesting(!layout.isPeeking && !layout.isRetracted)

                        expandedBelowNotchCard(layout: layout)
                            .opacity((layout.isPeeking && !layout.isRetracted) ? 1 : 0)
                            .animation(cardOpacityAnimation, value: model.isPeeking)
                            .scaleEffect(layout.isPeeking ? 1.0 : 0.96, anchor: .top)
                            .offset(y: layout.isPeeking ? 0 : -8)
                            .animation(morphSpring, value: model.isPeeking)
                            .animation(retractSpring, value: model.isRetracted)
                            .allowsHitTesting(layout.isPeeking && !layout.isRetracted)
                    }
                    .frame(width: NotchIslandLayout.canvasWidth, height: layout.windowHeight, alignment: .top)
                    .clipShape(silhouette)
                    .animation(morphSpring, value: model.isPeeking)
                    .animation(retractSpring, value: model.isRetracted)
                    .animation(morphSpring, value: model.snapshot.effectiveTaskText)

                    // 3. Single shared 2pt bottom progress / breathing rim riding smoothly from compact bottom to card bottom
                    if model.snapshot.hasProgressOrBreathingBar {
                        progressOrBreathingOverlay(layout: layout)
                            .opacity(layout.isRetracted ? 0 : 1)
                            .clipShape(silhouette)
                            .animation(morphSpring, value: model.isPeeking)
                            .animation(retractSpring, value: model.isRetracted)
                            .animation(morphSpring, value: model.snapshot.effectiveTaskText)
                            .allowsHitTesting(false)
                    }

                    // 4. Subtle glass rim highlight
                    rim
                        .stroke(
                            Color.white.opacity(layout.isRetracted ? 0 : (layout.isPeeking ? 0.20 : 0.13)),
                            lineWidth: 0.85
                        )
                        .animation(morphSpring, value: model.isPeeking)
                        .animation(retractSpring, value: model.isRetracted)
                        .animation(morphSpring, value: model.snapshot.effectiveTaskText)
                        .allowsHitTesting(false)
                }
                .animation(morphSpring, value: layout.peekBodyHeight)
                .animation(morphSpring, value: layout.compactTotalBodyWidth)
                .frame(width: NotchIslandLayout.canvasWidth, height: layout.windowHeight, alignment: .top)
                .dropDestination(for: URL.self) { urls, _ in
                    onFilesDropped(urls)
                }
            }
        }
        .frame(width: NotchIslandLayout.canvasWidth, height: layout.windowHeight, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, L10n.locale)
        .animation(.easeOut(duration: 0.12), value: isHoveringCheckbox)
    }

    // MARK: - Layer 1: Compact Single-Line Notch Wings

    @ViewBuilder
    private func compactForeground(layout: NotchIslandLayout) -> some View {
        let snapshot = model.snapshot
        let midX = NotchIslandLayout.canvasWidth / 2

        if layout.isNotched {
            let wingHeight = max(24, layoutState.safeLayout.notchHeight)
            let notchHalf = layout.centerNotchWidth / 2

            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: NotchIslandLayout.canvasWidth, height: wingHeight)
                    .allowsHitTesting(false)

                Button(action: onExpandPanel) {
                    Group {
                        if snapshot.showsCodexBadge {
                            ViewThatFits(in: .horizontal) {
                                if snapshot.focusActive || snapshot.keepAwake {
                                    HStack(spacing: 0) {
                                        notchedCompactLeftWing(snapshot: snapshot)
                                        codexBadge(count: snapshot.codexActivity.tasks.count)
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                }
                                codexBadge(count: snapshot.codexActivity.tasks.count)
                            }
                            .padding(.trailing, 8)
                        } else {
                            notchedCompactLeftWing(snapshot: snapshot)
                        }
                    }
                    .frame(width: layout.compactLeftWingWidth, height: wingHeight, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("Open notes"))
                .frame(width: midX - notchHalf, height: wingHeight, alignment: .trailing)

                Color.clear
                    .frame(width: layout.centerNotchWidth, height: wingHeight)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onExpandPanel)
                    .offset(x: midX - notchHalf, y: 0)

                notchedCompactRightWing(
                    snapshot: snapshot,
                    width: layout.compactRightWingWidth,
                    height: wingHeight
                )
                .frame(width: layout.compactRightWingWidth, height: wingHeight, alignment: .leading)
                .offset(x: midX + notchHalf, y: 0)
            }
            .frame(width: NotchIslandLayout.canvasWidth, height: wingHeight, alignment: .topLeading)
        } else {
            let barHeight: CGFloat = 24
            HStack(spacing: 6) {
                if snapshot.showsCodexBadge {
                    Button(action: onExpandPanel) {
                        codexBadge(count: snapshot.codexActivity.tasks.count)
                            .frame(height: barHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if snapshot.focusActive || snapshot.keepAwake {
                    Button(action: onExpandPanel) {
                        compactStatusBadge(snapshot: snapshot)
                            .frame(height: barHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if (snapshot.focusActive || snapshot.keepAwake), snapshot.effectiveTaskText != nil {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: 10)
                }

                if let taskText = snapshot.effectiveTaskText {
                    compactTaskRow(
                        text: taskText,
                        completed: snapshot.isShowingCompletedFeedback,
                        checkboxSize: 12.5,
                        height: barHeight
                    )
                } else {
                    Button(action: onExpandPanel) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Self.islandSecondary)
                            .frame(height: barHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: layout.compactTotalBodyWidth, height: barHeight)
        }
    }

    // MARK: - Layer 2: Expanded Preview

    @ViewBuilder
    private func expandedBelowNotchCard(layout: NotchIslandLayout) -> some View {
        let snapshot = model.snapshot
        let cardWidth = layout.peekTotalBodyWidth
        let topInset = NotchIslandLayout.previewTopInset(for: layoutState.safeLayout)

        VStack(spacing: 0) {
            if layout.isNotched {
                if snapshot.preview == .notes {
                    notePreviewHeader(layout: layout, height: topInset)
                } else {
                    Color.clear
                        .frame(height: topInset)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onExpandPanel)
                }
            }

            previewPicker
                .frame(height: NotchIslandLayout.previewPickerHeight)

            if snapshot.preview == .codex {
                codexTaskList(snapshot.codexActivity)
                    .padding(.horizontal, 12)
            } else {
                if !layout.isNotched {
                    notePreviewHeader(layout: layout, height: NotchIslandLayout.noteHeaderHeight)
                }
                expandedCardDetailRow(snapshot: snapshot, height: NotchIslandLayout.noteRowHeight)
                    .padding(.horizontal, 13)
            }
        }
        .padding(.bottom, NotchIslandLayout.previewBottomPadding)
        .frame(width: cardWidth, alignment: .top)
    }

    private var previewPicker: some View {
        HStack(spacing: 2) {
            ForEach(IslandPreview.allCases, id: \.self) { preview in
                let selected = preview == model.snapshot.preview
                Button {
                    model.selectPreview(preview)
                } label: {
                    HStack(spacing: 5) {
                        if preview == .codex && !model.snapshot.codexActivity.tasks.isEmpty {
                            Circle()
                                .fill(accentColor)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        Text(preview.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.white : Self.islandSecondary)
                    }
                    .frame(width: 84, height: 24)
                    .background(selected ? Color.white.opacity(0.15) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private func codexTaskList(_ activity: CodexActivity) -> some View {
        let tasks = activity.tasks
        let height = NotchIslandLayout.codexListHeight(count: tasks.count)
        if tasks.isEmpty {
            Text(L10n.string(codexEmptyMessage(for: activity)))
                .font(.system(size: 12))
                .foregroundStyle(Self.islandSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tasks) { task in
                        CodexTaskRow(task: task, failedToOpen: failedCodexTaskID == task.id) {
                            if NSWorkspace.shared.open(task.conversationURL) {
                                failedCodexTaskID = nil
                                model.isPeeking = false
                            } else {
                                failedCodexTaskID = task.id
                            }
                        }
                        .overlay(alignment: .top) {
                            if task.id != tasks.first?.id {
                                Rectangle()
                                    .fill(Color.white.opacity(0.09))
                                    .frame(height: 1)
                                    .padding(.horizontal, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(tasks.count <= NotchIslandLayout.visibleCodexRows)
            .frame(height: height)
        }
    }

    private func codexEmptyMessage(for activity: CodexActivity) -> String {
        switch activity {
        case .loading: "Checking Codex activity"
        case .available: "No running Codex tasks"
        case .unavailable: "Could not read Codex activity"
        }
    }

    private func codexBadge(count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(count > 0 ? accentColor : Self.islandSecondary)
            if count > 0 {
                Text(count, format: .number)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            count > 0
                ? String(format: L10n.string("%lld running Codex tasks"), Int64(count))
                : "Codex"
        )
    }

    @ViewBuilder
    private func notePreviewHeader(layout: NotchIslandLayout, height: CGFloat) -> some View {
        let snapshot = model.snapshot
        let cardWidth = layout.peekTotalBodyWidth
        if layout.isNotched {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                    Text(snapshot.noteTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Self.islandSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(width: layout.peekLeftWingWidth, height: height, alignment: .leading)

                Color.clear
                    .frame(width: layout.centerNotchWidth, height: height)

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if snapshot.keepAwake {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(focusColor)
                    }
                    if snapshot.focusActive, snapshot.totalTaskCount > 0 {
                        Text("\(snapshot.completedCount)/\(snapshot.totalTaskCount)")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Self.islandSecondary)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Self.islandSecondary)
                }
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .frame(width: layout.peekRightWingWidth, height: height, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpandPanel)
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 5.5, height: 5.5)
                Text(snapshot.noteTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Self.islandSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if snapshot.keepAwake {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(focusColor)
                }
                if snapshot.focusActive, snapshot.totalTaskCount > 0 {
                    Text("\(snapshot.completedCount)/\(snapshot.totalTaskCount)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Self.islandSecondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Self.islandSecondary)
            }
            .padding(.horizontal, 14)
            .frame(width: cardWidth, height: height)
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpandPanel)
        }
    }

    @ViewBuilder
    private func expandedCardDetailRow(snapshot: NotchIslandSnapshot, height: CGFloat) -> some View {
        if let taskText = snapshot.effectiveTaskText {
            HStack(spacing: 8) {
                taskCheckboxButton(
                    completed: snapshot.isShowingCompletedFeedback,
                    size: 15.5,
                    hitSize: 26
                )

                Button(action: onExpandPanel) {
                    HStack(spacing: 8) {
                        Text(taskText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(snapshot.isShowingCompletedFeedback ? Self.islandSecondary : .white)
                            .strikethrough(snapshot.isShowingCompletedFeedback, color: Self.islandSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentTransition(.opacity)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if snapshot.focusActive {
                            HStack(spacing: 4.5) {
                                miniProgressRing(progress: snapshot.focusProgress)
                                Text(L10n.compactMinutes(snapshot.remainingMinutes))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(focusColor)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(focusColor.opacity(0.12), in: Capsule())
                        } else if snapshot.totalTaskCount > 0 {
                            Text("\(snapshot.completedCount)/\(snapshot.totalTaskCount)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Self.islandSecondary)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 2.5)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                    .frame(height: height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(taskText) — \(L10n.string("Open notes"))")
            }
        } else {
            Button(action: onExpandPanel) {
                HStack(spacing: 8) {
                    if snapshot.focusActive {
                        miniProgressRing(progress: snapshot.focusProgress)
                        Text(L10n.focusRemaining(snapshot.remainingMinutes))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    } else if snapshot.keepAwake {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(focusColor)
                        Text(L10n.string("Keep Mac awake active"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 6)
                    Text(L10n.string("Open notes"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Self.islandSecondary)
                }
                .frame(height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Open notes"))
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func notchedCompactLeftWing(snapshot: NotchIslandSnapshot) -> some View {
        Group {
            if snapshot.focusActive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(focusColor)
                        .frame(width: 6, height: 6)
                    if snapshot.effectiveTaskText != nil {
                        Text(L10n.compactMinutes(snapshot.remainingMinutes))
                            .font(.system(size: 10.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    } else {
                        Text(L10n.string("Focus"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Self.islandSecondary)
                            .lineLimit(1)
                    }
                }
            } else if snapshot.keepAwake {
                HStack(spacing: 3.5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(focusColor)
                    Text(L10n.string("Awake"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 4) {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                    Text("\(snapshot.completedCount)/\(max(1, snapshot.totalTaskCount))")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Self.islandSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private func notchedCompactRightWing(
        snapshot: NotchIslandSnapshot,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        if let taskText = snapshot.effectiveTaskText {
            compactTaskRow(
                text: taskText,
                completed: snapshot.isShowingCompletedFeedback,
                checkboxSize: 13,
                height: height
            )
            .padding(.leading, 5)
            .padding(.trailing, 9)
        } else {
            Button(action: onExpandPanel) {
                HStack(spacing: 4) {
                    if snapshot.focusActive {
                        Text(L10n.compactMinutes(snapshot.remainingMinutes))
                            .font(.system(size: 10.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    } else {
                        if snapshot.keepAwake {
                            Circle()
                                .fill(focusColor.opacity(0.85))
                                .frame(width: 5, height: 5)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Self.islandSecondary)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 9)
                .frame(width: width, height: height, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Open notes"))
        }
    }

    private func compactStatusBadge(snapshot: NotchIslandSnapshot) -> some View {
        HStack(spacing: 4) {
            if snapshot.focusActive {
                Circle()
                    .fill(focusColor)
                    .frame(width: 6, height: 6)
                Text(L10n.compactMinutes(snapshot.remainingMinutes))
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(focusColor)
                Text(L10n.string("Awake"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
    }

    private func compactTaskRow(
        text: String,
        completed: Bool,
        checkboxSize: CGFloat,
        height: CGFloat
    ) -> some View {
        HStack(spacing: 3) {
            taskCheckboxButton(completed: completed, size: checkboxSize, hitSize: 20)
            Button(action: onExpandPanel) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(completed ? Self.islandSecondary : .white)
                    .strikethrough(completed, color: Self.islandSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: height, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(text)
        }
    }

    private func miniProgressRing(progress: Double) -> some View {
        let clamped = min(1, max(0.05, progress))
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    focusColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12.5, height: 12.5)
    }

    private func taskCheckboxButton(completed: Bool, size: CGFloat, hitSize: CGFloat) -> some View {
        Button {
            model.completeCurrentPinnedTask()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28)
                    .fill(
                        completed
                            ? accentColor
                            : Color.white.opacity(isHoveringCheckbox ? 0.14 : 0.06)
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.28)
                            .stroke(
                                completed
                                    ? accentColor
                                    : Color.white.opacity(isHoveringCheckbox ? 0.78 : 0.45),
                                lineWidth: 1.2
                            )
                    )
                if completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.62, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringCheckbox = hovering
        }
        .help(L10n.string("Complete task"))
        .accessibilityLabel(L10n.string("Complete task"))
    }

    @ViewBuilder
    private func progressOrBreathingOverlay(layout: NotchIslandLayout) -> some View {
        let snapshot = model.snapshot
        let midX = NotchIslandLayout.canvasWidth / 2
        let inset = max(10, layout.bottomCornerRadius)
        let trackMinX = midX - layout.leftSpan + inset
        let trackWidth = max(0, layout.leftSpan + layout.rightSpan - inset * 2)
        let trackY = max(2, layout.bodyHeight - 3.4)

        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: NotchIslandLayout.canvasWidth, height: layout.windowHeight)

            if trackWidth > 4 {
                if snapshot.focusActive {
                    let clamped = CGFloat(min(1, max(0.04, snapshot.focusProgress)))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: trackWidth, height: 2)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [accentColor, focusColor],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, trackWidth * clamped), height: 2)
                            .shadow(
                                color: focusColor.opacity(layout.isPeeking ? 0.68 : 0.50),
                                radius: layout.isPeeking ? 2.8 : 2.2,
                                y: 0
                            )
                    }
                    .offset(x: trackMinX, y: trackY)
                } else if snapshot.keepAwake {
                    Group {
                        if reduceMotion {
                            Capsule()
                                .fill(focusColor.opacity(0.62))
                                .frame(width: trackWidth, height: 2)
                        } else {
                            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                                let phase = timeline.date.timeIntervalSinceReferenceDate
                                let pulse = 0.34 + 0.44 * (0.5 + 0.5 * sin(phase * 1.9))
                                Capsule()
                                    .fill(focusColor.opacity(pulse))
                                    .frame(width: trackWidth, height: 2)
                                    .shadow(color: focusColor.opacity(pulse * 0.5), radius: 2)
                            }
                        }
                    }
                    .offset(x: trackMinX, y: trackY)
                }
            }
        }
        .frame(width: NotchIslandLayout.canvasWidth, height: layout.windowHeight, alignment: .topLeading)
    }
}

private struct CodexTaskRow: View {
    let task: CodexTask
    let failedToOpen: Bool
    let open: () -> Void

    @State private var hovered = false

    var body: some View {
        let title = task.title ?? L10n.string("Untitled Codex task")
        let subtitle = failedToOpen ? L10n.string("Could not open Codex chat") : task.project

        Button(action: open) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.66))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: NotchIslandLayout.codexRowHeight)
            .background(Color.white.opacity(hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class IslandHitTestContainerView: NSView {
    override var isFlipped: Bool { true }

    var interactiveRect: CGRect = .zero {
        didSet {
            if oldValue != interactiveRect {
                window?.invalidateCursorRects(for: self)
                updateTrackingAreas()
            }
        }
    }

    var onHoverStateChanged: ((Bool) -> Void)?
    private var activeTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard interactiveRect.width > 0,
              interactiveRect.height > 0,
              interactiveRect.contains(localPoint) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let activeTrackingArea {
            removeTrackingArea(activeTrackingArea)
            self.activeTrackingArea = nil
        }
        guard interactiveRect.width > 0, interactiveRect.height > 0 else { return }
        let area = NSTrackingArea(
            rect: interactiveRect.insetBy(dx: -2, dy: -2),
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        activeTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        if interactiveRect.insetBy(dx: -2, dy: -2).contains(localPoint) {
            onHoverStateChanged?(true)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        if interactiveRect.contains(localPoint) {
            onHoverStateChanged?(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        if !interactiveRect.insetBy(dx: -6, dy: -6).contains(localPoint) {
            onHoverStateChanged?(false)
        }
    }
}

@MainActor
final class NotchIslandCoordinator {
    private let panel: IslandPanel
    private let containerView: IslandHitTestContainerView
    private let hostingView: NSView
    private let model: NotchIslandModel
    private let store: WorkspaceStore
    private let layoutState: PanelLayoutState
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var peekExitWatchTimer: Timer?
    private var hoverExitDebounceTask: Task<Void, Never>?
    private var panelTransitionTask: Task<Void, Never>?
    private var codexMonitor: Task<Void, Never>?
    private var fadeOutGeneration: UInt64 = 0
    private weak var preferredScreen: NSScreen?
    private var desiredMainPanelVisible = false
    private(set) var isVisible = false

    var onVisibilityChanged: ((Bool) -> Void)?

    init(
        store: WorkspaceStore,
        reminder: BreakReminder,
        layoutState: PanelLayoutState,
        onExpandPanel: @escaping () -> Void,
        onFilesDropped: @escaping ([URL]) -> Bool
    ) {
        self.store = store
        self.layoutState = layoutState
        self.model = NotchIslandModel(store: store, reminder: reminder)

        let initialRect = NSRect(x: 0, y: 0, width: NotchIslandLayout.canvasWidth, height: 92)
        panel = IslandPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        containerView = IslandHitTestContainerView(frame: initialRect)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        let rootView = NotchIslandView(
            model: model,
            layoutState: layoutState,
            onExpandPanel: onExpandPanel,
            onFilesDropped: onFilesDropped
        )
        let hosted = NSHostingView(rootView: rootView)
        hosted.frame = containerView.bounds
        hosted.autoresizingMask = [.width, .height]
        containerView.addSubview(hosted)
        hostingView = hosted
        panel.contentView = containerView

        containerView.onHoverStateChanged = { [weak self] hovering in
            MainActor.assumeIsolated {
                self?.handleHoverChanged(hovering)
            }
        }

        model.$snapshot
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncPresentation()
                }
            }
            .store(in: &cancellables)

        model.$isPeeking
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncInteractiveBounds()
                }
            }
            .store(in: &cancellables)

        model.$isRetracted
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncInteractiveBounds()
                }
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncWindowFrameIfNeeded()
                self?.syncInteractiveBounds()
            }
        }
    }

    deinit {
        peekExitWatchTimer?.invalidate()
        hoverExitDebounceTask?.cancel()
        panelTransitionTask?.cancel()
        codexMonitor?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    var islandModel: NotchIslandModel { model }

    func setMainPanelVisible(_ visible: Bool, activeScreen: NSScreen?) {
        if let activeScreen {
            preferredScreen = activeScreen
        }
        desiredMainPanelVisible = visible
        panelTransitionTask?.cancel()
        panelTransitionTask = nil
        hoverExitDebounceTask?.cancel()
        hoverExitDebounceTask = nil

        if visible {
            stopPeekWatchTimer()
            containerView.interactiveRect = .zero

            guard isVisible else {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    model.isPeeking = false
                    model.isRetracted = false
                    model.setMainPanelVisible(true)
                }
                hideImmediately()
                return
            }

            isVisible = false
            onVisibilityChanged?(false)
            model.isPeeking = false
            model.isRetracted = true
            fadeOutGeneration &+= 1
            let generation = fadeOutGeneration
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let fadeDuration: TimeInterval = reduceMotion ? 0.07 : 0.13
            animatePanelAlpha(to: 0, duration: fadeDuration)

            let waitNs: UInt64 = reduceMotion ? 80_000_000 : 140_000_000
            panelTransitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: waitNs)
                guard let self, !Task.isCancelled, self.desiredMainPanelVisible else { return }
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    self.model.setMainPanelVisible(true)
                    self.model.isRetracted = false
                }
                if self.fadeOutGeneration == generation, !self.isVisible {
                    self.panel.orderOut(nil)
                }
            }
        } else {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let delayNs: UInt64 = reduceMotion ? 55_000_000 : 115_000_000
            panelTransitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delayNs)
                guard let self, !Task.isCancelled, !self.desiredMainPanelVisible else { return }

                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    self.model.isPeeking = false
                    self.model.isRetracted = true
                    self.model.setMainPanelVisible(false)
                }

                guard self.model.snapshot.shouldPresent else {
                    self.model.isRetracted = false
                    self.hideImmediately()
                    return
                }

                self.fadeOutGeneration &+= 1
                self.syncWindowFrameIfNeeded()
                self.hostingView.layoutSubtreeIfNeeded()
                self.isVisible = true
                self.panel.alphaValue = 0
                self.panel.orderFrontRegardless()
                self.onVisibilityChanged?(true)
                self.animatePanelAlpha(to: 1, duration: reduceMotion ? 0.08 : 0.14)

                await Task.yield()
                guard !Task.isCancelled, !self.desiredMainPanelVisible else { return }
                self.model.isRetracted = false
                self.syncInteractiveBounds()
            }
        }
    }

    func setSuppressed(_ suppressed: Bool) {
        panelTransitionTask?.cancel()
        panelTransitionTask = nil
        model.setSuppressed(suppressed)
        if suppressed {
            hideImmediately()
        } else if !desiredMainPanelVisible {
            syncPresentation()
        }
    }

    func refreshForPreferencesChange() {
        model.refreshSnapshot()
        updateCodexMonitoring()
        if !desiredMainPanelVisible {
            syncPresentation()
        }
    }

    private func updateCodexMonitoring() {
        if !store.preferences.notchIslandEnabled {
            codexMonitor?.cancel()
            codexMonitor = nil
            model.setCodexActivity(.loading)
            return
        }
        guard codexMonitor == nil else { return }
        codexMonitor = Task.detached(priority: .utility) { [weak model] in
            var reader = CodexTaskReader()
            while !Task.isCancelled {
                let activity = reader.refresh()
                await model?.setCodexActivity(activity)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func handleHoverChanged(_ hovering: Bool) {
        guard isVisible, !desiredMainPanelVisible, !model.isRetracted, model.snapshot.shouldPresent else { return }
        if hovering {
            hoverExitDebounceTask?.cancel()
            hoverExitDebounceTask = nil
            if !model.isPeeking {
                model.isPeeking = true
                syncInteractiveBounds()
                startPeekWatchTimer()
            }
        } else if model.isPeeking, hoverExitDebounceTask == nil {
            hoverExitDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 85_000_000)
                guard let self, !Task.isCancelled else { return }
                self.hoverExitDebounceTask = nil
                self.collapsePeekIfPointerOutside()
            }
        }
    }

    private func startPeekWatchTimer() {
        peekExitWatchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.14, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.collapsePeekIfPointerOutside()
            }
        }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        peekExitWatchTimer = timer
    }

    private func stopPeekWatchTimer() {
        peekExitWatchTimer?.invalidate()
        peekExitWatchTimer = nil
    }

    private func collapsePeekIfPointerOutside() {
        guard model.isPeeking else {
            stopPeekWatchTimer()
            return
        }
        let mouseScreen = NSEvent.mouseLocation
        let windowPoint = panel.convertPoint(fromScreen: mouseScreen)
        let localPoint = containerView.convert(windowPoint, from: nil)
        if !containerView.interactiveRect.insetBy(dx: -8, dy: -8).contains(localPoint) {
            stopPeekWatchTimer()
            model.isPeeking = false
            syncInteractiveBounds()
        }
    }

    private func syncPresentation() {
        guard !desiredMainPanelVisible else { return }
        let shouldShow = model.snapshot.shouldPresent
        if shouldShow {
            fadeOutGeneration &+= 1
            syncWindowFrameIfNeeded()
            syncInteractiveBounds()
            if !isVisible {
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    model.isRetracted = true
                }
                hostingView.layoutSubtreeIfNeeded()
                isVisible = true
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                onVisibilityChanged?(true)
                animatePanelAlpha(to: 1, duration: reduceMotion ? 0.08 : 0.15)

                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.isVisible, !self.desiredMainPanelVisible else { return }
                    self.model.isRetracted = false
                    self.syncInteractiveBounds()
                }
            } else if panel.alphaValue < 1 {
                animatePanelAlpha(to: 1, duration: 0.12)
            }
        } else {
            hideImmediately()
        }
    }

    private func animatePanelAlpha(to target: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = target
        }, completionHandler: nil)
    }

    private func hideImmediately() {
        stopPeekWatchTimer()
        hoverExitDebounceTask?.cancel()
        hoverExitDebounceTask = nil
        fadeOutGeneration &+= 1
        containerView.interactiveRect = .zero
        guard isVisible else {
            if panel.isVisible {
                panel.orderOut(nil)
            }
            return
        }
        isVisible = false
        panel.orderOut(nil)
        onVisibilityChanged?(false)
    }

    private func resolveTargetScreen() -> NSScreen? {
        if let preferredScreen, NSScreen.screens.contains(preferredScreen) {
            return preferredScreen
        }
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Positions the fixed-height canvas once per screen configuration—never called to resize on hover!
    private func syncWindowFrameIfNeeded() {
        guard let screen = resolveTargetScreen() else { return }
        layoutState.update(for: screen)
        let fixedHeight = NotchIslandLayout.fixedWindowHeight(for: layoutState.safeLayout)

        let centerX: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            centerX = (left.maxX + right.minX) / 2
        } else {
            centerX = screen.frame.midX
        }

        let targetFrame = NSRect(
            x: round(centerX - NotchIslandLayout.canvasWidth / 2),
            y: round(screen.frame.maxY - fixedHeight),
            width: NotchIslandLayout.canvasWidth,
            height: fixedHeight
        )
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
            containerView.frame = NSRect(origin: .zero, size: targetFrame.size)
            hostingView.frame = containerView.bounds
        }
    }

    private func syncInteractiveBounds() {
        guard model.snapshot.shouldPresent, !desiredMainPanelVisible else {
            containerView.interactiveRect = .zero
            return
        }
        let islandLayout = NotchIslandLayout.compute(
            safeLayout: layoutState.safeLayout,
            snapshot: model.snapshot,
            isPeeking: model.isPeeking,
            isRetracted: model.isRetracted
        )
        containerView.interactiveRect = islandLayout.interactiveRect
    }
}
