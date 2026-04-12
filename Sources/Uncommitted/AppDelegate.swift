import AppKit
import SwiftUI
import Combine
import Sparkle
import UncommittedCore

/// Owns the AppKit menu-bar presence. The popup is an NSMenu with a
/// single custom-view NSMenuItem hosting our SwiftUI content — the same
/// approach CodexBar and iStat Menus use. NSMenu gives us system-managed
/// button highlight, proper dismissal of other status item menus, correct
/// positioning, no arrow, and no Bartender interference.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Singleton accessor — SwiftUI's `@NSApplicationDelegateAdaptor`
    /// wraps the delegate so `NSApp.delegate as? AppDelegate` fails.
    /// Set in `applicationDidFinishLaunching`.
    static weak var shared: AppDelegate?

    let configStore: ConfigStore
    let repoStore: RepoStore
    let hoverDetail: HoverDetailController
    /// Sparkle auto-updater. Starts checking on launch; the "Check for
    /// Updates" action in the popup calls through to it.
    let updaterController: SPUStandardUpdaterController

    private var statusItem: NSStatusItem?
    private var popupMenu: NSMenu?
    private var hostingController: NSHostingController<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var rightClickMonitor: Any?

    override init() {
        self.configStore = ConfigStore()
        self.repoStore = RepoStore(configStore: configStore)
        self.hoverDetail = HoverDetailController()
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
        setupMenu()
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
            self?.resizeMenuIfNeeded()
        }
        .store(in: &cancellables)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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

    // MARK: - NSMenu-based popup

    private func setupMenu() {
        let contentView = MenuContentView()
            .environmentObject(configStore)
            .environmentObject(repoStore)
            .environment(\.dismissPopover) { [weak self] in
                self?.closePopup()
            }
            .environment(\.hoverDetail, hoverDetail)
            .environment(\.checkForUpdates) { [weak self] in
                self?.updaterController.updater.checkForUpdates()
            }

        let hosting = NSHostingController(rootView: AnyView(contentView))
        self.hostingController = hosting

        let menu = NSMenu()
        menu.delegate = self

        // Single menu item with our entire SwiftUI popup as its view.
        let item = NSMenuItem()
        item.view = hosting.view
        menu.addItem(item)

        self.popupMenu = menu
        statusItem?.menu = menu
    }

    func closePopup() {
        hoverDetail.dismissImmediately()
        popupMenu?.cancelTracking()
    }

    /// Re-measure the SwiftUI content and update the menu item's view
    /// frame so the menu window resizes when rows appear or disappear.
    private func resizeMenuIfNeeded() {
        guard let hView = hostingController?.view,
              popupMenu?.highlightedItem != nil || popupMenu?.numberOfItems ?? 0 > 0
        else { return }
        hView.layoutSubtreeIfNeeded()
        let fitting = hView.fittingSize
        if hView.frame.size != fitting {
            hView.frame.size = fitting
            popupMenu?.update()
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        hoverDetail.popupHostingView = hostingController?.view

        // Size the menu item's view to its SwiftUI content so the
        // menu window fits correctly.
        if let hView = hostingController?.view {
            hView.layoutSubtreeIfNeeded()
            let fitting = hView.fittingSize
            hView.frame.size = fitting
        }

        // Install a local event monitor to catch right-clicks. NSMenu's
        // tracking loop swallows them otherwise. The monitor lets us
        // show a context menu for the currently hovered repo row.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            if self.showRepoContextMenu(for: event) {
                return nil
            }
            return event
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        hoverDetail.dismissImmediately()
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
    }

    /// Shows a context menu with the "Open with" actions for the
    /// currently hovered repo. Returns true if a menu was shown (event
    /// should be swallowed), false otherwise.
    private func showRepoContextMenu(for event: NSEvent) -> Bool {
        guard hoverDetail.hoveredRepoId != nil,
              let onAction = hoverDetail.hoveredOnAction else { return false }
        let actions = hoverDetail.hoveredActions
        guard !actions.isEmpty else { return false }

        let menu = NSMenu()
        let header = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for action in actions {
            let item = RepoActionMenuItem(
                title: action.name,
                action: action,
                onAction: onAction
            )
            if let nsImage = AppIcons.icon(for: action) {
                let size: CGFloat = 16
                let resized = NSImage(size: NSSize(width: size, height: size))
                resized.lockFocus()
                nsImage.draw(
                    in: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                resized.unlockFocus()
                item.image = resized
            }
            menu.addItem(item)
        }

        // popUp(positioning:at:in:) opens a nested tracking loop so
        // this works while the parent menu is still tracking.
        if let window = event.window {
            menu.popUp(positioning: nil, at: event.locationInWindow, in: window.contentView)
        } else {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
        return true
    }
}

// MARK: - Right-click context menu item

/// NSMenuItem subclass that holds a closure and a repo action, used
/// by the right-click handler in AppDelegate.
final class RepoActionMenuItem: NSMenuItem {
    private let onAction: (Action) -> Void
    private let repoAction: Action

    init(title: String, action: Action, onAction: @escaping (Action) -> Void) {
        self.repoAction = action
        self.onAction = onAction
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        onAction(repoAction)
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

struct CheckForUpdatesKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var checkForUpdates: () -> Void {
        get { self[CheckForUpdatesKey.self] }
        set { self[CheckForUpdatesKey.self] = newValue }
    }
}
