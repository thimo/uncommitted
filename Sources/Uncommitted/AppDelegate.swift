import AppKit
import SwiftUI
import Combine
import UncommittedCore

/// Owns the AppKit menu-bar presence: an NSStatusItem that toggles an
/// NSPopover hosting our SwiftUI content. We went AppKit-hosted (same shape
/// as CodexBar) because SwiftUI's MenuBarExtra gives you no way to dismiss
/// its popover programmatically — NSPopover exposes performClose() and
/// supports `.transient` behavior for auto-dismiss on focus loss.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let configStore: ConfigStore
    let repoStore: RepoStore

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        self.configStore = ConfigStore()
        self.repoStore = RepoStore(configStore: configStore)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        updateStatusLabel()

        // Re-render the menu bar label whenever repos change OR when the
        // user picks a different label style in Settings.
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
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Cached menu bar icon — loaded once from the bundled SVG and sized
    /// to match typical menu bar glyph proportions. Marked as template
    /// so macOS inverts it for dark menu bar backgrounds automatically.
    private static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "icon-glyph", withExtension: "svg"),
              let svg = NSImage(contentsOf: url) else {
            return nil
        }
        // The SVG is tall (289×448). Scale to a menu bar-friendly height
        // while preserving aspect ratio.
        let targetHeight: CGFloat = 18
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

        // NSStatusBarButton silently drops a plain `title` alongside an image
        // in some macOS versions. `attributedTitle` with an explicit font is
        // the reliable way to render icon + text in the menu bar.
        // Paragraph style with zero head indent tightens the gap between
        // the SF Symbol image and the leading character of the title.
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
            // Everything that needs your attention: files to commit, commits
            // to push, commits to pull.
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

    // MARK: - Popover

    private func setupPopover() {
        let contentView = MenuContentView()
            .environmentObject(configStore)
            .environmentObject(repoStore)
            .environment(\.dismissPopover) { [weak self] in
                self?.closePopover()
            }

        let hosting = NSHostingController(rootView: contentView)
        // Let the SwiftUI content drive the popover size — no more hardcoded frames.
        hosting.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.behavior = .transient
        // Menu-bar popovers should feel instant. The default animation makes
        // the app feel laggy on open/close for no benefit.
        popover.animates = false
        popover.contentViewController = hosting
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make the popover's window key so SwiftUI receives events normally.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover?.performClose(nil)
    }
}

// MARK: - Environment key

/// Environment hook that lets a SwiftUI view hosted in our NSPopover ask
/// AppDelegate to close the popover.
struct DismissPopoverKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var dismissPopover: () -> Void {
        get { self[DismissPopoverKey.self] }
        set { self[DismissPopoverKey.self] = newValue }
    }
}
