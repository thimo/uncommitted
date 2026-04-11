import AppKit
import SwiftUI
import Combine

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

        repoStore.$repos
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

    private func updateStatusLabel() {
        guard let button = statusItem?.button else { return }

        button.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Uncommitted")
        button.imagePosition = .imageLeft
        button.imageHugsTitle = true

        // Single at-a-glance number: how many repositories need attention.
        // Unknown (nil) status doesn't count — we only tally what we know
        // to be dirty, so a momentarily-stale repo never inflates the badge.
        let dirtyCount = repoStore.repos.filter { $0.status?.isClean == false }.count
        let title = dirtyCount > 0 ? " \(dirtyCount)" : ""

        // NSStatusBarButton silently drops a plain `title` alongside an image
        // in some macOS versions. `attributedTitle` with an explicit font is
        // the reliable way to render icon + text in the menu bar.
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
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
        popover.animates = true
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
