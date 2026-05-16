import AppKit
import SwiftUI
import Combine
import Sparkle
import UncommittedCore

/// Owns the AppKit menu-bar presence: an NSStatusItem that toggles a
/// floating NSPanel hosting our SwiftUI content. We use a custom panel
/// instead of NSPopover for full control: no arrow, left-aligned to the
/// button, custom highlight. We use an NSPanel instead of NSMenu so
/// right-click context menus, scrolling, and other SwiftUI interactions
/// work correctly — NSMenu's tracking loop breaks all of those.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Singleton accessor — SwiftUI's `@NSApplicationDelegateAdaptor`
    /// wraps the delegate so `NSApp.delegate as? AppDelegate` fails.
    /// Set in `applicationDidFinishLaunching`.
    static weak var shared: AppDelegate?

    let configStore: ConfigStore
    let fetchStateStore: FetchStateStore
    let repoStore: RepoStore
    let fetchScheduler: FetchScheduler
    let githubScheduler: GitHubStatusScheduler
    let hoverDetail: HoverDetailController
    /// Sparkle auto-updater. Starts checking on launch; the "Check for
    /// Updates" action in Settings calls through to it.
    let updaterController: SPUStandardUpdaterController

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let hotkeyManager = HotkeyManager()

    private static let cornerRadius: CGFloat = 10

    /// 9-slice resizable image fed to `NSVisualEffectView.maskImage`.
    /// `layer.cornerRadius` alone doesn't work: NSVisualEffectView's
    /// behind-window vibrancy bypasses normal CALayer compositing, so
    /// the window shadow reads a rectangular backing and draws a
    /// rectangular shadow. `maskImage` is the documented hook that
    /// actually shapes the alpha channel so `panel.hasShadow = true`
    /// produces a rounded shadow.
    private static let roundedMaskImage: NSImage = {
        let radius = cornerRadius
        let edge = radius * 2 + 1
        let image = NSImage(
            size: NSSize(width: edge, height: edge),
            flipped: false
        ) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()

    override init() {
        self.configStore = ConfigStore()
        self.fetchStateStore = FetchStateStore()
        self.repoStore = RepoStore(configStore: configStore, fetchStateStore: fetchStateStore)
        self.fetchScheduler = FetchScheduler(
            configStore: configStore,
            repoStore: repoStore,
            fetchStateStore: fetchStateStore
        )
        self.githubScheduler = GitHubStatusScheduler(
            repoStore: repoStore,
            configStore: configStore
        )
        self.repoStore.onCancelFetch = { [weak fetchScheduler] url in
            fetchScheduler?.cancelFetch(for: url)
        }
        self.hoverDetail = HoverDetailController()
        self.hoverDetail.fetchStateStore = fetchStateStore
        self.hoverDetail.fetchScheduler = fetchScheduler
        self.hoverDetail.fetchEnabled = configStore.config.fetchFromRemotes
        // Capture weakly so the controller doesn't keep the scheduler
        // alive past app shutdown — the closure is replaced if needed.
        // Honor the global toggle + per-repo mute list so the detail
        // panel stays in sync with the row badges.
        self.hoverDetail.githubStatusLookup = { [weak githubScheduler, weak configStore] url in
            guard let configStore, configStore.config.showGitHubStatus else { return nil }
            let key = url.standardizedFileURL.path
            if configStore.config.gitHubMutedRepos.contains(key) { return nil }
            return githubScheduler?.statuses[url]
        }
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        installMinimalMenu()
        setupStatusItem()
        setupPanel()
        updateStatusLabel()

        Publishers.Merge4(
            repoStore.$repos.map { _ in () }.eraseToAnyPublisher(),
            configStore.$config
                .map(\.menuBarLabelStyle)
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            configStore.$config
                .map(\.gitHubMutedRepos)
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            githubScheduler.$statuses
                .map { statuses in statuses.values.contains { $0.ciStatus == .failure } }
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateStatusLabel()
        }
        .store(in: &cancellables)

        // Keep the hover detail controller's fetch flag in sync with the
        // setting so the detail panel stops showing the fetch line as
        // soon as the user disables auto-fetch.
        configStore.$config
            .map(\.fetchFromRemotes)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.hoverDetail.fetchEnabled = enabled
            }
            .store(in: &cancellables)

        // Global hotkey: register on launch, re-register when config changes.
        hotkeyManager.onTrigger = { [weak self] in
            self?.togglePopup(nil)
        }
        configStore.$config
            .map(\.globalShortcut)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shortcut in
                if let shortcut {
                    self?.hotkeyManager.register(shortcut)
                } else {
                    self?.hotkeyManager.unregister()
                }
            }
            .store(in: &cancellables)

        // When repo data changes while the panel is open (e.g. after a
        // push clears "unpushed" counts), re-fit the panel to the new
        // SwiftUI content size.
        repoStore.$repos
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resizePanelIfVisible()
                // SwiftUI may not have re-rendered yet (e.g. clean repos
                // being filtered out after status loads). Follow up on
                // the next runloop so fittingSize reflects the new content.
                DispatchQueue.main.async {
                    self?.resizePanelIfVisible()
                }
            }
            .store(in: &cancellables)
    }

    private func resizePanelIfVisible() {
        guard let panel, panel.isVisible, let hView = hostingController?.view else { return }
        // Force the hosting view to drop any cached intrinsic size and
        // re-measure against the current SwiftUI body. Without this,
        // shrinking content (e.g. a row dropping off `visibleRepos`)
        // leaves the panel at the previous, taller size — producing a
        // band of empty space above the footer.
        hView.invalidateIntrinsicContentSize()
        hView.layoutSubtreeIfNeeded()
        let fitting = hView.intrinsicContentSize
        guard fitting.width > 0, fitting.height > 0,
              fitting != panel.frame.size else { return }

        // Unconditionally re-pin the top edge 1pt below the menu bar rather
        // than preserving the panel's old top: Auto Layout can auto-grow
        // the panel upward when intrinsic content expands, which displaces
        // the top into the menu bar. Re-deriving the origin from
        // `visibleFrame.maxY` every resize makes us robust to that.
        let screen = panel.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? panel.frame
        var frame = panel.frame
        frame.size = fitting
        frame.origin.y = visibleFrame.maxY - fitting.height - 1
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Menu bar (LSUIElement fix)

    /// LSUIElement apps have no menu bar, which breaks `performClose:`
    /// (the red traffic-light button) because it needs a `close:` action
    /// in the responder chain. Install a minimal hidden menu so the
    /// Settings window can close normally. Bonus: Cmd+W works too.
    private func installMinimalMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window",
                        action: #selector(NSWindow.performClose(_:)),
                        keyEquivalent: "w")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopup(_:))
            // mouseDown so Bartender doesn't trigger its hidden bar.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        statusItem = item
    }

    private static let menuBarIcon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "icon-glyph", withExtension: "svg"),
              let svg = NSImage(contentsOf: url) else {
            return nil
        }
        let targetHeight: CGFloat = 14
        let aspect = svg.size.width / svg.size.height
        svg.size = NSSize(width: targetHeight * aspect, height: targetHeight)
        svg.isTemplate = true
        return svg
    }()

    /// Red glyph used as a trailing CI-alert indicator on the status
    /// item. Same `xmark.circle.fill` symbol the popover badge uses, so
    /// the in-text alert reads as "the popover badge, in the menu bar."
    /// Sized to match the system font so it sits inline with the count
    /// digits without throwing off baseline alignment.
    private static func alertShieldImage() -> NSImage? {
        let pointSize = NSFont.systemFontSize
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let glyph = NSImage(systemSymbolName: "xmark.circle.fill",
                                  accessibilityDescription: "CI failure")?
                                   .withSymbolConfiguration(config) else {
            return nil
        }
        let tinted = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSColor.systemRed.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private func updateStatusLabel() {
        guard let button = statusItem?.button else { return }

        button.image = AppDelegate.menuBarIcon ?? NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Uncommitted")
        button.imagePosition = .imageLeft
        button.imageHugsTitle = true

        let title = labelTitle(for: configStore.config.menuBarLabelStyle)
        // Muted repos are excluded from the menubar shield: if the user
        // marked a repo as "not my problem", a red CI on it shouldn't
        // keep nagging from the menu bar either.
        let muted = Set(configStore.config.gitHubMutedRepos)
        let useAlert = githubScheduler.statuses.contains { url, status in
            status.ciStatus == .failure && !muted.contains(url.standardizedFileURL.path)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: paragraph,
            .kern: 0,
        ]

        let attributed = NSMutableAttributedString(string: title, attributes: baseAttrs)
        if useAlert, let shield = AppDelegate.alertShieldImage() {
            // A leading space separates the shield from the count digits;
            // when the count is empty (iconOnly style) we skip the space
            // so the shield sits flush against the branch icon.
            if !title.isEmpty {
                attributed.append(NSAttributedString(string: " ", attributes: baseAttrs))
            }
            let attachment = NSTextAttachment()
            attachment.image = shield
            // Nudge the glyph down a hair so its visual center aligns
            // with the digit baseline.
            attachment.bounds = NSRect(x: 0, y: -2,
                                       width: shield.size.width,
                                       height: shield.size.height)
            attributed.append(NSAttributedString(attachment: attachment))
        }
        button.attributedTitle = attributed
    }

    private func labelTitle(for style: MenuBarLabelStyle) -> String {
        switch style {
        case .total:
            let total = repoStore.totalUncommitted + repoStore.totalUnpushed + repoStore.totalUnpulled
            return total > 0 ? "\(total)" : ""
        case .dirtyRepos:
            let count = repoStore.repos.filter { $0.status?.isClean == false }.count
            return count > 0 ? "\(count)" : ""
        case .split:
            var parts: [String] = []
            let uncommitted = repoStore.totalUncommitted
            let unpushed = repoStore.totalUnpushed
            let unpulled = repoStore.totalUnpulled
            if uncommitted > 0 { parts.append("\(uncommitted)") }
            if unpushed > 0 { parts.append("↑\(unpushed)") }
            if unpulled > 0 { parts.append("↓\(unpulled)") }
            return parts.joined(separator: " ")
        case .iconOnly:
            return ""
        }
    }

    // MARK: - Popup panel

    private func setupPanel() {
        let contentView = MenuContentView()
            .environmentObject(configStore)
            .environmentObject(repoStore)
            .environmentObject(fetchStateStore)
            .environmentObject(fetchScheduler)
            .environmentObject(githubScheduler)
            .environment(\.dismissPopover) { [weak self] in
                self?.closePopup()
            }
            .environment(\.resizePanel) { [weak self] in
                self?.resizePanelIfVisible()
            }
            .environment(\.hoverDetail, hoverDetail)

        let hosting = NSHostingController(rootView: AnyView(contentView))
        hosting.sizingOptions = .intrinsicContentSize
        self.hostingController = hosting

        let panel = PopupPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Surface over fullscreen apps too — expected status-bar
        // behaviour. We deliberately do *not* set `.canJoinAllSpaces`:
        // the popover should dismiss when the user switches Spaces
        // (handled below via `activeSpaceDidChangeNotification`) so
        // the next menu-bar click opens a fresh popover on the
        // current desktop, like every other status-bar app.
        panel.collectionBehavior = [.fullScreenAuxiliary]

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .headerView
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.maskImage = Self.roundedMaskImage

        let hView = hosting.view
        hView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hView)
        NSLayoutConstraint.activate([
            hView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        panel.contentView = visualEffect
        self.panel = panel

        // Auto Layout auto-resizes the panel whenever the hosting view's
        // intrinsic content size changes (e.g. Option-hold reveals clean
        // repos). NSWindow grows upward by default — origin stays, height
        // increases — which pushes the top past the menu bar. Re-anchor
        // the top whenever the panel resizes. The notification fires on
        // any size change, including our own setFrame calls, so the guard
        // inside re-anchor skips when nothing needs moving.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: panel
        )

        // Dismiss the popover when the user switches Spaces. Without
        // this, the panel stays pinned to its original Space — clicking
        // the menu-bar icon on the new Space would toggle that hidden
        // panel "closed", so the next click is the one that opens a
        // fresh popover. Standard status-bar apps dismiss on switch.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func activeSpaceDidChange(_ note: Notification) {
        guard let panel, panel.isVisible else { return }
        closePopup()
    }

    @objc private func panelDidResize(_ note: Notification) {
        guard let panel, panel.isVisible else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let desiredY = visibleFrame.maxY - panel.frame.size.height - 1
        guard panel.frame.origin.y != desiredY else { return }
        var frame = panel.frame
        frame.origin.y = desiredY
        panel.setFrame(frame, display: true, animate: false)
    }

    @objc private func togglePopup(_ sender: Any?) {
        guard let panel, let button = statusItem?.button else { return }
        if panel.isVisible {
            closePopup()
        } else {
            showPopup(from: button)
        }
    }

    private func showPopup(from button: NSStatusBarButton) {
        guard let panel, let hostingController else { return }

        // Size the panel to its SwiftUI content.
        let hView = hostingController.view
        hView.layoutSubtreeIfNeeded()
        let fitting = hView.intrinsicContentSize
        panel.setContentSize(fitting)

        // Position: left-aligned to the button, 1pt below the menu bar.
        guard let buttonWindow = button.window else { return }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)

        let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonFrameOnScreen.origin) })
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let panelX = buttonFrameOnScreen.minX
        let panelY = visibleFrame.maxY - fitting.height - 1

        // If the panel extends past the screen's right edge, shift left.
        let maxX = visibleFrame.maxX - fitting.width
        let clampedX = min(panelX, maxX)

        panel.setFrameOrigin(NSPoint(x: clampedX, y: panelY))
        panel.orderFrontRegardless()
        // Become key (without activating the app — `.nonactivatingPanel`
        // + the PopupPanel `canBecomeKey` override) so the SwiftUI search
        // field in the header can take keyboard focus on open. The click-
        // outside monitors still dismiss as before.
        panel.makeKey()
        NotificationCenter.default.post(name: .popupDidOpen, object: nil)

        // The synchronous `intrinsicContentSize` read above can be 15-20pt
        // smaller than the steady-state height when SwiftUI hasn't yet
        // committed all pending body updates (e.g. a row's subtitle line
        // that only renders after a Combine publisher settles a beat
        // later). Schedule a follow-up resize on the next runloop tick
        // to catch the settled size and correct the panel before the
        // user sees the too-small popover with its bottom row clipped.
        DispatchQueue.main.async { [weak self] in
            self?.resizePanelIfVisible()
        }

        // Eager-refresh GitHub status for visible repos so freshly-opened
        // popups don't show stale data. The scheduler dedups by slug + sha
        // so this is cheap even when the cadence has just fired.
        githubScheduler.eagerRefresh(repoStore.repos)

        hoverDetail.popupHostingView = hView

        // Native status item highlight while the panel is open.
        // `highlight(true/false)` uses the button's own state machine,
        // which doesn't fight mouseDown/mouseUp the way a custom
        // layer overlay does.
        button.highlight(true)

        installEventMonitors()
    }

    func closePopup() {
        hoverDetail.dismissImmediately()
        statusItem?.button?.highlight(false)
        panel?.orderOut(nil)
        removeEventMonitors()
        NotificationCenter.default.post(name: .popupDidClose, object: nil)
    }

    // MARK: - Click-outside dismissal

    private func installEventMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopup()
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }

            if event.window == panel { return event }
            if event.window == self.statusItem?.button?.window { return event }
            if event.window is HoverDetailPanel { return event }

            self.closePopup()
            return event
        }
    }

    private func removeEventMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
}

// MARK: - Popup panel

/// Borderless panels return `canBecomeKey == false` by default, which
/// would block keyboard focus for the header search field. Overriding it
/// lets the panel become key so typing works — without activating the
/// (LSUIElement) app, since the style mask stays `.nonactivatingPanel`.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    /// Posted when the menu-bar popup is shown / hidden so the SwiftUI
    /// content can focus (and reset) the search field per session.
    static let popupDidOpen = Notification.Name("UncommittedPopupDidOpen")
    static let popupDidClose = Notification.Name("UncommittedPopupDidClose")
}

// MARK: - Environment key

struct DismissPopoverKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

struct ResizePanelKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var dismissPopover: () -> Void {
        get { self[DismissPopoverKey.self] }
        set { self[DismissPopoverKey.self] = newValue }
    }

    var resizePanel: () -> Void {
        get { self[ResizePanelKey.self] }
        set { self[ResizePanelKey.self] = newValue }
    }
}
