import AppKit
import SwiftUI
import UncommittedCore

/// Manages a floating NSPanel that shows the currently-hovered repo
/// row's rich detail. Lives in its own window so it can extend past the
/// main NSPopover's bounds and position itself adjacent to a row.
/// Added as a child window of the main popover's window so clicks on
/// the panel don't count as "outside the popover" and dismiss the main
/// menu as a side effect.
///
/// Animation is deliberately short (see `fadeDuration`) because the
/// default NSPopover fade was rejected as "too slow" — the whole point
/// of rolling our own panel is control over this.
///
/// Not `@MainActor`-annotated — all call sites are already on the main
/// thread (SwiftUI hover events, AppKit window callbacks), and adding
/// the annotation makes `closePopover()` need to hop through the actor
/// boundary which cascades into `AppDelegate` requiring isolation.
final class HoverDetailController {
    /// Optional fetch state lookup. Set by AppDelegate at construction time
    /// so the detail panel can show "Last fetched X ago" / failure status.
    weak var fetchStateStore: FetchStateStore?
    /// Whether the auto-fetch feature is on. The detail panel only shows
    /// fetch info when this is true — there's nothing to report otherwise.
    var fetchEnabled: Bool = false
    /// Closure that returns the latest GitHub status snapshot for a repo.
    /// Set by AppDelegate so the detail panel can explain the PR pill and
    /// CI badge in plain text. Nil while the feature is disabled.
    var githubStatusLookup: ((URL) -> GitHubRepoStatus?)?
    /// Fade-in / fade-out duration. Tweak this to change the feel.
    private static let fadeDuration: TimeInterval = 0.1
    /// How long the cursor must sit on a row before the panel appears.
    private static let showDelay: TimeInterval = 0.3
    /// Grace period after hover-out before the panel dismisses. Long
    /// enough that the cursor can travel from the row to the panel.
    private static let dismissDelay: TimeInterval = 0.18
    /// Gap between the row's edge and the panel's edge.
    private static let panelGap: CGFloat = 10

    private var panel: HoverDetailPanel?
    private var hostingView: NSHostingView<HoverDetailContent>?
    private var showWorkItem: DispatchWorkItem?
    private var dismissWorkItem: DispatchWorkItem?
    private var currentRepoId: UUID?
    private var isPanelHovered = false
    private var currentActions: [Action] = []
    private var currentOnAction: ((Action) -> Void)?

    /// The repo ID currently being displayed. Used by the right-click
    /// handler in AppDelegate to show a context menu for the right row.
    var hoveredRepoId: UUID? { currentRepoId }
    /// Actions and callback for the currently hovered repo, exposed
    /// for the right-click context menu.
    var hoveredActions: [Action] { currentActions }
    var hoveredOnAction: ((Action) -> Void)? { currentOnAction }
    /// Which side of the popup the panel is currently sitting on.
    /// Determines which edge the arrow renders on.
    private var currentSide: PanelSide = .right
    /// Parent window (main menu popover's content window) that we attach
    /// to as a child. Captured from the row frame update so we don't
    /// need AppDelegate to hand it to us.
    private weak var parentWindow: NSWindow?
    /// The main popup's NSHostingView, captured from AppDelegate when
    /// the popover opens. Used to get the true visible content frame on
    /// screen (NSPopover's window.contentView is an internal wrapper
    /// that includes arrow + shadow padding, so its bounds are wider
    /// than the visible content and make the panel float too far away).
    weak var popupHostingView: NSView?

    /// Called by a `RepoRow` on hover-in. Shows the panel after a short
    /// delay (debounced). When called while another panel is already
    /// visible, switches content instantly without re-running the delay.
    func showDetail(
        for repo: Repo,
        rowFrameOnScreen: NSRect,
        actions: [Action],
        onAction: @escaping (Action) -> Void
    ) {
        guard let status = repo.status else { return }

        currentActions = actions
        currentOnAction = onAction
        dismissWorkItem?.cancel()

        // Already visible → swap content and reposition instantly.
        if currentRepoId != nil {
            showWorkItem?.cancel()
            currentRepoId = repo.id
            updateContent(repo: repo, status: status, rowFrameOnScreen: rowFrameOnScreen)
            return
        }

        // Not visible yet → schedule a delayed show.
        showWorkItem?.cancel()
        let pendingRepoId = repo.id
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentRepoId == nil else { return }
            self.present(repo: repo, status: status, rowFrameOnScreen: rowFrameOnScreen)
            self.currentRepoId = pendingRepoId
        }
        showWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.showDelay,
            execute: item
        )
    }

    /// Called by a `RepoRow` on hover-out. Cancels any pending show and
    /// schedules a delayed dismiss. If the cursor lands on the panel
    /// during the grace period, `panelHover(true)` cancels the dismiss.
    func scheduleDismiss(for repoId: UUID) {
        showWorkItem?.cancel()
        dismissWorkItem?.cancel()

        // If the row that's leaving isn't the one currently shown (e.g.
        // racy hover events), ignore.
        guard currentRepoId == nil || currentRepoId == repoId else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isCursorOverPanel { return }
            self.dismiss()
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.dismissDelay,
            execute: item
        )
    }

    /// Tears the panel down immediately, skipping fade. Used when the
    /// main popup closes — we don't want a leftover floating panel.
    func dismissImmediately() {
        showWorkItem?.cancel()
        dismissWorkItem?.cancel()
        currentRepoId = nil
        isPanelHovered = false
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    /// Called by the panel itself when the cursor enters or leaves it.
    /// Keeps the panel alive while hovered, dismisses when both row and
    /// panel have been empty for the grace period.
    fileprivate func panelHover(_ hovering: Bool) {
        isPanelHovered = hovering
        if hovering {
            dismissWorkItem?.cancel()
        } else {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.isCursorOverPanel { return }
                self.dismiss()
            }
            dismissWorkItem = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.dismissDelay,
                execute: item
            )
        }
    }

    /// Checks cursor position directly via NSEvent rather than relying
    /// on SwiftUI's `.onHover` which doesn't fire during NSMenu tracking.
    private var isCursorOverPanel: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    // MARK: - Internals

    private func present(
        repo: Repo,
        status: RepoStatus,
        rowFrameOnScreen: NSRect
    ) {
        let panel = ensurePanel()

        // Re-find the parent window on every show rather than caching
        // across dismiss cycles. When the panel was dismissed its parent
        // link was broken; we need to re-establish it freshly so size
        // and origin math run against the current popup window.
        parentWindow = NSApp.windows.first { window in
            window.isVisible && window.frame.intersects(rowFrameOnScreen)
        }

        // Add as child window BEFORE we size/position. On repeat shows,
        // the system can reposition a just-added child based on its
        // existing frame — we want our explicit setFrameOrigin to be
        // the final word, so run it after the hierarchy change.
        if let parent = parentWindow, panel.parent == nil {
            parent.addChildWindow(panel, ordered: .above)
        }

        // Decide which side the panel will live on up-front so the
        // arrow renders on the matching edge BEFORE we measure/position.
        currentSide = preferredSide(for: rowFrameOnScreen)
        updateContent(repo: repo, status: status, rowFrameOnScreen: rowFrameOnScreen)

        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func updateContent(
        repo: Repo,
        status: RepoStatus,
        rowFrameOnScreen: NSRect
    ) {
        // Recompute side on each update in case a previous call stored
        // a stale value for a different row/row frame.
        currentSide = preferredSide(for: rowFrameOnScreen)

        let actions = currentActions
        let onAction = currentOnAction
        let fetchState = fetchEnabled ? fetchStateStore?.state(for: repo.url) : nil
        let githubStatus = githubStatusLookup?(repo.url)
        let content = HoverDetailContent(
            repoName: repo.name,
            status: status,
            arrowSide: currentSide,
            actions: actions,
            fetchState: fetchState,
            githubStatus: githubStatus,
            onAction: { action in onAction?(action) },
            onHoverChange: { [weak self] in self?.panelHover($0) }
        )
        if let hostingView {
            hostingView.rootView = content
        } else {
            let view = NSHostingView(rootView: content)
            view.translatesAutoresizingMaskIntoConstraints = false
            hostingView = view
            panel?.contentView = view
        }

        // Size the panel to its content, then position.
        guard let panel, let hostingView else { return }
        // Force layout so fittingSize reflects the new content.
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        panel.setContentSize(fitting)
        positionPanel(panel, relativeTo: rowFrameOnScreen, size: panel.frame.size)
    }

    /// Returns the side of the popup the panel should live on based on
    /// available screen space: right if it fits, otherwise left.
    private func preferredSide(for rowFrameOnScreen: NSRect) -> PanelSide {
        let horizontalFrame = popupContentFrameOnScreen() ?? parentWindow?.frame ?? rowFrameOnScreen
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(horizontalFrame) })
            ?? NSScreen.main else { return .right }
        // Use the current panel width if we have one, else a reasonable
        // default so the decision is stable before first layout.
        let panelWidth = panel?.frame.width ?? 268
        let rightX = horizontalFrame.maxX + Self.panelGap
        if rightX + panelWidth <= screen.visibleFrame.maxX {
            return .right
        }
        return .left
    }

    private func positionPanel(
        _ panel: NSPanel,
        relativeTo rowFrame: NSRect,
        size: NSSize
    ) {
        let horizontalFrame = popupContentFrameOnScreen() ?? parentWindow?.frame ?? rowFrame

        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(horizontalFrame) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        // The panel's window includes the arrow on one edge. We want
        // the visible card to sit `panelGap` away from the popup, not
        // the whole panel-including-arrow. When the arrow is on the
        // inward edge (closest to the popup), shift the panel so its
        // tip touches the "gap past the popup edge" line.
        let arrowWidth = HoverDetailContent.arrowWidth
        let x: CGFloat
        switch currentSide {
        case .right:
            // Panel right of popup, arrow on the panel's LEFT edge
            // (tip touching the popup side of the gap).
            x = horizontalFrame.maxX + Self.panelGap - arrowWidth
        case .left:
            // Panel left of popup, arrow on the panel's RIGHT edge.
            // panel.maxX = popup.minX - panelGap + arrowWidth
            x = horizontalFrame.minX - Self.panelGap + arrowWidth - size.width
        }
        // Clamp so the card itself doesn't run off-screen.
        let minX = visible.minX
        let maxX = visible.maxX - size.width
        let clampedX = max(minX, min(x, maxX))

        // Vertical: align panel's top with the row's top so the panel
        // moves to match whichever row is hovered.
        var y = rowFrame.maxY - size.height
        if y < visible.minY {
            y = visible.minY
        } else if y + size.height > visible.maxY {
            y = visible.maxY - size.height
        }

        panel.setFrameOrigin(NSPoint(x: clampedX, y: y))
    }

    /// Returns the parent popup's visible content frame in screen
    /// coordinates. Uses the explicit hosting view reference if
    /// `AppDelegate` handed one over; otherwise falls back to the
    /// window's content view (which will be off by the NSPopover
    /// shadow/arrow padding but is better than nothing).
    private func popupContentFrameOnScreen() -> NSRect? {
        if let hosting = popupHostingView,
           let window = hosting.window {
            let inWindow = hosting.convert(hosting.bounds, to: nil)
            return window.convertToScreen(inWindow)
        }
        guard let window = parentWindow,
              let rootContent = window.contentView else { return nil }
        let inWindow = rootContent.convert(rootContent.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    private func dismiss() {
        guard let panel else { return }
        showWorkItem?.cancel()
        dismissWorkItem?.cancel()
        currentRepoId = nil
        isPanelHovered = false

        // Capture the panel locally so the completion closure doesn't
        // need to cross isolation boundaries to read `self.panel`.
        let dismissingPanel = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dismissingPanel.animator().alphaValue = 0
        }, completionHandler: {
            dismissingPanel.parent?.removeChildWindow(dismissingPanel)
            dismissingPanel.orderOut(nil)
            dismissingPanel.alphaValue = 1
        })
    }

    private func ensurePanel() -> HoverDetailPanel {
        if let panel { return panel }
        let panel = HoverDetailPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }
}

/// Borderless NSPanel that hosts the SwiftUI detail content. Must allow
/// `canBecomeKey = true` so SwiftUI buttons inside can receive clicks;
/// the `.nonactivatingPanel` style mask prevents the app from being
/// activated and keeps the main menu popup from losing focus.
final class HoverDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Which side of the main popup the detail panel is attached to.
/// Drives arrow orientation and positioning decisions.
enum PanelSide {
    case left   // panel sits to the left of the popup
    case right  // panel sits to the right of the popup
}

/// Wrapper view that applies the card + arrow styling as a single
/// combined shape, so the material fills seamlessly and there's no
/// visible seam where the arrow meets the card. Delivers its own hover
/// state back to the controller.
struct HoverDetailContent: View {
    let repoName: String
    let status: RepoStatus
    let arrowSide: PanelSide
    let actions: [Action]
    let fetchState: FetchState?
    let githubStatus: GitHubRepoStatus?
    let onAction: (Action) -> Void
    let onHoverChange: (Bool) -> Void

    /// Arrow dimensions. 8pt wide, 14pt tall is a system-popover-ish feel.
    static let arrowWidth: CGFloat = 8
    static let arrowHeight: CGFloat = 14
    /// Y offset (from view top) of the TOP of the arrow's base, picked
    /// so the arrow's center lands roughly on the hovered row's center.
    static let arrowTopOffset: CGFloat = 24
    static let cornerRadius: CGFloat = 10

    var body: some View {
        RepoDetailPopover(
            repoName: repoName,
            status: status,
            actions: actions,
            fetchState: fetchState,
            githubStatus: githubStatus,
            onAction: onAction
        )
            .frame(width: 260)
            .fixedSize(horizontal: false, vertical: true)
            // Reserve space for the arrow on the appropriate side. The
            // shape draws into this padded area — the card occupies
            // the non-arrow side and the arrow pokes out into the
            // padded strip.
            .padding(.leading, arrowSide == .right ? Self.arrowWidth : 0)
            .padding(.trailing, arrowSide == .left ? Self.arrowWidth : 0)
            .background(
                cardWithArrow.fill(Material.regular)
            )
            .overlay(
                cardWithArrow.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .onHover { onHoverChange($0) }
    }

    private var cardWithArrow: CardWithArrowShape {
        CardWithArrowShape(
            arrowSide: arrowSide,
            cornerRadius: Self.cornerRadius,
            arrowWidth: Self.arrowWidth,
            arrowHeight: Self.arrowHeight,
            arrowTopOffset: Self.arrowTopOffset
        )
    }
}

/// A single-path shape combining a rounded card with an arrow that
/// pokes out of one edge. Rendering as one shape (instead of separate
/// card + triangle) means the material fills as one unit and any
/// stroke wraps the whole outline — no visible seam at the join.
struct CardWithArrowShape: Shape {
    let arrowSide: PanelSide
    let cornerRadius: CGFloat
    let arrowWidth: CGFloat
    let arrowHeight: CGFloat
    let arrowTopOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = cornerRadius

        // The card occupies the side of `rect` that's NOT reserved for
        // the arrow. The arrow fills the remaining strip.
        let cardRect: CGRect
        switch arrowSide {
        case .right:
            cardRect = CGRect(
                x: rect.minX + arrowWidth,
                y: rect.minY,
                width: rect.width - arrowWidth,
                height: rect.height
            )
        case .left:
            cardRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width - arrowWidth,
                height: rect.height
            )
        }

        let arrowTopY = rect.minY + arrowTopOffset
        let arrowBottomY = arrowTopY + arrowHeight
        let arrowTipY = arrowTopY + arrowHeight / 2

        switch arrowSide {
        case .right:
            // Panel is right of popup → arrow on the LEFT edge of the
            // card, pointing left. Walk clockwise starting at the top
            // of the left edge.
            path.move(to: CGPoint(x: cardRect.minX + r, y: cardRect.minY))
            path.addLine(to: CGPoint(x: cardRect.maxX - r, y: cardRect.minY))
            path.addQuadCurve(
                to: CGPoint(x: cardRect.maxX, y: cardRect.minY + r),
                control: CGPoint(x: cardRect.maxX, y: cardRect.minY)
            )
            path.addLine(to: CGPoint(x: cardRect.maxX, y: cardRect.maxY - r))
            path.addQuadCurve(
                to: CGPoint(x: cardRect.maxX - r, y: cardRect.maxY),
                control: CGPoint(x: cardRect.maxX, y: cardRect.maxY)
            )
            path.addLine(to: CGPoint(x: cardRect.minX + r, y: cardRect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: cardRect.minX, y: cardRect.maxY - r),
                control: CGPoint(x: cardRect.minX, y: cardRect.maxY)
            )
            // Left edge going UP. Detour out through the arrow.
            path.addLine(to: CGPoint(x: cardRect.minX, y: arrowBottomY))
            path.addLine(to: CGPoint(x: rect.minX, y: arrowTipY))
            path.addLine(to: CGPoint(x: cardRect.minX, y: arrowTopY))
            path.addLine(to: CGPoint(x: cardRect.minX, y: cardRect.minY + r))
            path.addQuadCurve(
                to: CGPoint(x: cardRect.minX + r, y: cardRect.minY),
                control: CGPoint(x: cardRect.minX, y: cardRect.minY)
            )

        case .left:
            // Panel is left of popup → arrow on the RIGHT edge of the
            // card, pointing right. Same traversal pattern mirrored.
            path.move(to: CGPoint(x: cardRect.minX + r, y: cardRect.minY))
            path.addLine(to: CGPoint(x: cardRect.maxX - r, y: cardRect.minY))
            path.addQuadCurve(
                to: CGPoint(x: cardRect.maxX, y: cardRect.minY + r),
                control: CGPoint(x: cardRect.maxX, y: cardRect.minY)
            )
            // Right edge going DOWN. Detour out through the arrow.
            path.addLine(to: CGPoint(x: cardRect.maxX, y: arrowTopY))
            path.addLine(to: CGPoint(x: rect.maxX, y: arrowTipY))
            path.addLine(to: CGPoint(x: cardRect.maxX, y: arrowBottomY))
            path.addLine(to: CGPoint(x: cardRect.maxX, y: cardRect.maxY - r))
            path.addQuadCurve(
                to: CGPoint(x: cardRect.maxX - r, y: cardRect.maxY),
                control: CGPoint(x: cardRect.maxX, y: cardRect.maxY)
            )
            path.addLine(to: CGPoint(x: cardRect.minX + r, y: cardRect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: cardRect.minX, y: cardRect.maxY - r),
                control: CGPoint(x: cardRect.minX, y: cardRect.maxY)
            )
            path.addLine(to: CGPoint(x: cardRect.minX, y: cardRect.minY + r))
            path.addQuadCurve(
                to: CGPoint(x: cardRect.minX + r, y: cardRect.minY),
                control: CGPoint(x: cardRect.minX, y: cardRect.minY)
            )
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - Environment plumbing

private struct HoverDetailKey: EnvironmentKey {
    static let defaultValue: HoverDetailController? = nil
}

extension EnvironmentValues {
    var hoverDetail: HoverDetailController? {
        get { self[HoverDetailKey.self] }
        set { self[HoverDetailKey.self] = newValue }
    }
}

// MARK: - Row frame reader

/// Holds a weak reference to the backing NSView so SwiftUI call sites
/// can query the row's current screen frame on demand rather than
/// relying on a cached value that was written on a SwiftUI layout pass.
/// Earlier versions cached the frame in an `@State` updated from
/// `viewDidMoveToWindow` / `layout` / `resizeSubviews`, but those
/// callbacks don't fire when a LazyVStack's children shift around after
/// initial layout — producing stale frames for every row except the
/// first one that was displayed.
final class RowFrameReference: ObservableObject {
    weak var view: FrameReportingView?

    /// Reads `view.bounds` through the live NSView chain at call time,
    /// returning its position in screen coordinates. `nil` if the view
    /// isn't in a window yet.
    var currentFrameOnScreen: NSRect? {
        guard let view, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }
}

/// NSViewRepresentable wrapper whose only job is to hand the backing
/// NSView's reference to a `RowFrameReference`. The reference is read
/// on demand from `.onHover`, which is the only place we actually need
/// the row's screen frame.
struct RowFrameReader: NSViewRepresentable {
    let reference: RowFrameReference

    func makeNSView(context: Context) -> FrameReportingView {
        let view = FrameReportingView()
        reference.view = view
        return view
    }

    func updateNSView(_ nsView: FrameReportingView, context: Context) {
        reference.view = nsView
    }
}

final class FrameReportingView: NSView {}
