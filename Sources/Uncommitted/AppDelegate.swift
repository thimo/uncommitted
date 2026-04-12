import AppKit
import SwiftUI
import Combine
import UncommittedCore

/// Owns the AppKit menu-bar presence. The popup is an NSMenu with a
/// single custom-view NSMenuItem hosting our SwiftUI content — the same
/// approach CodexBar and iStat Menus use. NSMenu gives us system-managed
/// button highlight, proper dismissal of other status item menus, correct
/// positioning, no arrow, and no Bartender interference.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let configStore: ConfigStore
    let repoStore: RepoStore
    let hoverDetail: HoverDetailController

    private var statusItem: NSStatusItem?
    private var popupMenu: NSMenu?
    private var hostingController: NSHostingController<AnyView>?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        self.configStore = ConfigStore()
        self.repoStore = RepoStore(configStore: configStore)
        self.hoverDetail = HoverDetailController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func menuDidClose(_ menu: NSMenu) {
        hoverDetail.dismissImmediately()
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
