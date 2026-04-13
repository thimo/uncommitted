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
        self.hoverDetail = HoverDetailController()
        self.hoverDetail.fetchStateStore = fetchStateStore
        self.hoverDetail.fetchEnabled = configStore.config.fetchFromRemotes
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()
        setupPanel()
        updateStatusLabel()

        Publishers.Merge(
            repoStore.$repos.map { _ in () }.eraseToAnyPublisher(),
            configStore.$config
                .map(\.menuBarLabelStyle)
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

        // When repo data changes while the panel is open (e.g. after a
        // push clears "unpushed" counts), re-fit the panel to the new
        // SwiftUI content size.
        repoStore.$repos
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resizePanelIfVisible()
            }
            .store(in: &cancellables)
    }

    private func resizePanelIfVisible() {
        guard let panel, panel.isVisible, let hView = hostingController?.view else { return }
        hView.invalidateIntrinsicContentSize()
        hView.layoutSubtreeIfNeeded()
        let fitting = hView.fittingSize
        guard fitting != panel.frame.size else { return }
        var frame = panel.frame
        // Anchor the panel's top-left (below the menu bar) so it grows
        // downward, not upward into the menu bar.
        frame.origin.y += frame.size.height - fitting.height
        frame.size = fitting
        panel.setFrame(frame, display: true, animate: false)
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

    private func updateStatusLabel() {
        guard let button = statusItem?.button else { return }

        button.image = AppDelegate.menuBarIcon ?? NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Uncommitted")
        button.imagePosition = .imageLeft
        button.imageHugsTitle = true

        let title = labelTitle(for: configStore.config.menuBarLabelStyle)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: paragraph,
                .kern: 0,
            ]
        )
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
            .environment(\.dismissPopover) { [weak self] in
                self?.closePopup()
            }
            .environment(\.hoverDetail, hoverDetail)

        let hosting = NSHostingController(rootView: AnyView(contentView))
        self.hostingController = hosting

        let panel = NSPanel(
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
        let fitting = hView.fittingSize
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

// MARK: - Environment key

struct DismissPopoverKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var dismissPopover: () -> Void {
        get { self[DismissPopoverKey.self] }
        set { self[DismissPopoverKey.self] = newValue }
    }
}
