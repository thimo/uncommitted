import SwiftUI
import AppKit
import UncommittedCore

struct MenuContentView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var fetchScheduler: FetchScheduler
    @EnvironmentObject var githubScheduler: GitHubStatusScheduler
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissPopover) private var dismissPopover
    @Environment(\.resizePanel) private var resizePanel
    @Environment(\.hoverDetail) private var hoverDetail

    /// Tracks whether the Option modifier is currently held. Updated by
    /// a long-lived NSEvent monitor owned by the StateObject below — a
    /// plain @State + closure approach would capture a stale view value
    /// and stop working after the popup is closed and reopened.
    @StateObject private var modifierTracker = ModifierTracker()
    @StateObject private var busyIndicator = BusyIndicator()

    private var visibleRepos: [Repo] {
        // Holding Option temporarily reveals clean repos even when the filter
        // is on — a peek, not a state change. The header toggle is for the
        // persisted preference.
        let hide = configStore.config.hideCleanRepos && !modifierTracker.optionHeld
        guard hide else { return store.repos }
        let muted = Set(configStore.config.gitHubMutedRepos)
        return store.repos.filter { repo in
            // Local git state needs attention…
            if !(repo.status?.isClean ?? false) { return true }
            // …or GitHub side does, but only if the user hasn't muted
            // this repo's GitHub status — a muted row is "I don't want
            // to see this", which has to extend to the visibility
            // filter, not just the badges.
            let isMuted = muted.contains(repo.url.standardizedFileURL.path)
            guard !isMuted else { return false }
            guard let gh = githubScheduler.statuses[repo.url] else { return false }
            // Failing or running CI — keep visible.
            if gh.ciStatus == .failure || gh.ciStatus == .pending { return true }
            // Open PRs (any author) — keep visible too. Dependabot pile-ups
            // are still "something to deal with", just at lower urgency.
            if gh.prCount?.isEmpty == false { return true }
            return false
        }
    }

    /// Cap the repo list at ~55% of the current screen's visible height
    /// so the popover grows with the display instead of sitting at a
    /// hardcoded 440pt. Falls back to 440 if we can't read the screen.
    private var maxListHeight: CGFloat {
        guard let screenHeight = NSScreen.main?.visibleFrame.height else {
            return 440
        }
        return max(300, screenHeight * 0.55)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            repoList(for: visibleRepos)
            Divider()
            footer
        }
        .frame(width: 360)
        .onChange(of: fetchScheduler.inFlightFetches) { _, newValue in
            busyIndicator.update(busy: newValue > 0)
        }
        .onChange(of: modifierTracker.optionHeld) { _, _ in
            // Dispatch to the next runloop so SwiftUI has committed the
            // updated body before we read the hosting view's fitting size
            // — reading it synchronously inside onChange sometimes returns
            // the stale size, leaving the resize a no-op until Auto
            // Layout's own cadence kicks in 100–300ms later. The panel's
            // resize notification handler in AppDelegate re-anchors the
            // top edge whenever the panel actually changes size.
            DispatchQueue.main.async {
                resizePanel()
            }
        }
        .onChange(of: visibleRepos.count) { _, _ in
            // A repo dropping off the visible list (e.g. push cleared
            // its unpushed count and "hide clean repos" is on) has to
            // shrink the panel too — the controller's $repos sink fires
            // before SwiftUI commits the new layout, so it'd read the
            // old fittingSize. Hopping to the next runloop after we
            // already saw the count change gives layout a beat to land.
            DispatchQueue.main.async {
                resizePanel()
            }
        }
        .onDisappear {
            // Popup closed — drop any lingering hover detail panel.
            hoverDetail?.dismissImmediately()
        }
    }

    @ViewBuilder
    private func repoList(for visible: [Repo]) -> some View {
        if store.repos.isEmpty {
            emptyNoSources
        } else if visible.isEmpty {
            emptyAllClean
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, repo in
                        RepoRow(
                            repo: repo,
                            actions: configStore.config.actions,
                            onDefault: {
                                guard let first = configStore.config.actions.first else { return }
                                ActionRunner.run(repoURL: repo.url, action: first)
                                // The other app becoming active should auto-close a
                                // transient popover, but the timing isn't reliable —
                                // sometimes the popover stays open. Explicit dismiss.
                                dismissPopover()
                            },
                            onAlternate: { action in
                                ActionRunner.run(repoURL: repo.url, action: action)
                                dismissPopover()
                            },
                            onHoverChange: { hovering, rowFrameOnScreen in
                                if hovering, let frame = rowFrameOnScreen {
                                    hoverDetail?.showDetail(
                                        for: repo,
                                        rowFrameOnScreen: frame,
                                        actions: configStore.config.actions,
                                        onAction: { action in
                                            ActionRunner.run(repoURL: repo.url, action: action)
                                            dismissPopover()
                                        },
                                        onFetch: {
                                            fetchScheduler.manualFetch(repos: [repo])
                                        }
                                    )
                                } else {
                                    hoverDetail?.scheduleDismiss(for: repo.id)
                                }
                            }
                        )
                        if index < visible.count - 1 {
                            Divider().padding(.horizontal, 10)
                        }
                    }
                }
            }
            .frame(maxHeight: maxListHeight)
        }
    }

    private var header: some View {
        HStack {
            Text("Uncommitted")
                .font(.headline)
                .padding(.horizontal, 6)
            Spacer()
            Button {
                // One-click "refresh everything": rescan source folders
                // (catches just-cloned repos), kick a manual `git fetch`
                // on every repo (bypasses cadence + back-off), and
                // poke the GitHub scheduler so CI/PR badges aren't
                // stuck on the last cadence tick.
                //
                // No pulse() here: manualFetch synchronously bumps
                // FetchScheduler.inFlightFetches on the main thread,
                // which drives the spinner via .onChange. Pulsing on
                // top of that produced a visible flicker (pulse hides
                // at 0.5s, then the real fetch counter shows the
                // spinner again).
                store.rebuildFromConfig()
                fetchScheduler.manualFetch(repos: store.repos)
                githubScheduler.eagerRefresh(store.repos)
            } label: {
                Group {
                    if busyIndicator.visible {
                        // Same pattern as ActionBadge uses for push/pull
                        // in-flight: a scaled-down system ProgressView.
                        // Built-in animation, no custom rotation math to
                        // fight with the button's own hover/press states.
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .regular))
                    }
                }
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary.opacity(0.70))
            }
            .buttonStyle(GhostButtonStyle())
            .pointingHandCursor()
            .hoverTip("Refresh local repos and remotes", growsLeft: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var emptyNoSources: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.primary.opacity(0.70))
            Text("No repositories configured")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.70))
            Text("Open Settings to add a folder.")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.50))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var emptyAllClean: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("You're fully committed")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.70))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            Button {
                // LSUIElement apps don't auto-activate when a SwiftUI window
                // opens, so without this the Settings window comes up with
                // an inactive titlebar. dismissPopover() is hosted by our
                // AppDelegate via the DismissPopoverKey environment.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                dismissPopover()
            } label: {
                Text(Image(systemName: "gearshape"))
            }
            .buttonStyle(GhostButtonStyle())
            .foregroundStyle(.primary.opacity(0.70))
            .font(.callout)
            .keyboardShortcut(",")
            .help("Settings")
            .pointingHandCursor()

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(GhostButtonStyle())
            .foregroundStyle(.primary.opacity(0.70))
            .font(.callout)
            .keyboardShortcut("q")
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Hover cursor helper

extension View {
    /// Changes the cursor to a pointing hand while hovering this view so
    /// clickable controls read as clickable (macOS doesn't do this by
    /// default the way web browsers do).
    func pointingHandCursor() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    /// SwiftUI-only hover tip. `.help()` is broken in our popover host
    /// because the panel uses `.nonactivatingPanel` (never becomes key),
    /// and AppKit's tooltip subsystem requires a key window. This
    /// modifier just listens for hover, then renders a small caption
    /// box below the view — no AppKit tooltip-tracking needed.
    /// `growsLeft` controls overflow direction: trailing-anchored
    /// labels grow left so they stay inside the popover for buttons
    /// on the right edge (like the header refresh).
    func hoverTip(_ text: String, growsLeft: Bool = false) -> some View {
        modifier(HoverTipModifier(text: text, growsLeft: growsLeft))
    }
}

private struct HoverTipModifier: ViewModifier {
    let text: String
    let growsLeft: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovered = $0 }
            .overlay(alignment: growsLeft ? .bottomTrailing : .bottom) {
                if isHovered {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thickMaterial,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.12),
                                radius: 6, x: 0, y: 2)
                        .fixedSize()
                        .offset(y: 26)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(999)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Busy indicator

/// Debounced "is the app doing work right now?" signal for the header
/// refresh button's spinner. Raw counter changes from RepoStore and
/// FetchScheduler blink rapidly during FSEvents-driven status refreshes,
/// so we wrap them in a leading-edge delay (brief bursts under 150ms
/// never surface a spinner) and a minimum visible duration (once shown,
/// the spinner holds for at least 400ms so it doesn't flicker off as
/// quick refreshes finish). Together these match the "was there sustained
/// activity worth showing" heuristic we actually want.
final class BusyIndicator: ObservableObject {
    @Published var visible = false

    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var shownAt: Date?

    private static let leadingDelay: TimeInterval = 0.15
    private static let minDuration: TimeInterval = 0.40

    /// Forces the spinner visible for at least `duration` seconds,
    /// regardless of whether any underlying work is actually running.
    /// Used as "click feedback" for the refresh button — the refresh
    /// itself is often faster than the eye can register, so we pulse
    /// the spinner for a fixed window just to confirm the click.
    func pulse(duration: TimeInterval = 0.5) {
        showWork?.cancel()
        showWork = nil
        hideWork?.cancel()
        visible = true
        shownAt = Date()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.visible = false
            self.shownAt = nil
            self.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func update(busy: Bool) {
        if busy {
            // Cancel any pending hide — work picked back up.
            hideWork?.cancel()
            hideWork = nil
            if visible || showWork != nil { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.visible = true
                self.shownAt = Date()
                self.showWork = nil
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.leadingDelay, execute: work)
        } else {
            // Cancel any pending show — burst ended before the leading
            // delay elapsed, so we skip rendering the spinner entirely.
            showWork?.cancel()
            showWork = nil
            if !visible || hideWork != nil { return }
            let elapsed = shownAt.map { Date().timeIntervalSince($0) } ?? 0
            let delay = max(0, Self.minDuration - elapsed)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.visible = false
                self.shownAt = nil
                self.hideWork = nil
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}

// MARK: - Modifier tracking

/// Polls the system modifier state at ~60Hz so SwiftUI views can react to
/// Option being held. We can't use `NSEvent.addLocalMonitor(.flagsChanged)`
/// because the popup is hosted in a `.nonactivatingPanel` — local
/// monitors only fire while the app is `.active`, which our popup is
/// careful to avoid. Polling `NSEvent.modifierFlags` (a static system
/// query) works regardless of activation state at negligible cost.
final class ModifierTracker: ObservableObject {
    @Published var optionHeld: Bool

    private var timer: Timer?

    init() {
        self.optionHeld = NSEvent.modifierFlags.contains(.option)
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let held = NSEvent.modifierFlags.contains(.option)
            if self.optionHeld != held {
                self.optionHeld = held
            }
        }
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Ghost button style

/// Shared corner radius for interactive elements (ghost buttons, action
/// badges, row hover highlights). Kept in one place so adjusting the
/// overall "roundness" is a single-constant change.
let interactiveCornerRadius: CGFloat = 6

/// A compact button style with a rounded-rect hover fill and a pressed
/// state — used for the popover's chrome (Settings, Quit, Refresh).
/// Adds 6pt horizontal / 3pt vertical internal padding so the fill has
/// room to breathe around the label.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct GhostButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: interactiveCornerRadius)
                    .fill(fill)
                    // Animate ONLY on press state changes so the click
                    // fades in/out instead of snapping. Scoping to
                    // `value: isPressed` keeps the animation from
                    // bleeding into other properties.
                    .animation(.easeOut(duration: 0.35), value: isPressed)
            )
            .contentShape(RoundedRectangle(cornerRadius: interactiveCornerRadius))
            .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if isPressed { return Color.primary.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.08) }
        return .clear
    }
}

struct RepoRow: View {
    let repo: Repo
    let actions: [Action]
    let onDefault: () -> Void
    let onAlternate: (Action) -> Void
    /// Reports hover state changes along with the row's screen-space
    /// frame so the hover detail controller can position its floating
    /// panel next to the correct row. Frame is nil on hover-out.
    let onHoverChange: (Bool, NSRect?) -> Void

    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var fetchStateStore: FetchStateStore
    @EnvironmentObject var fetchScheduler: FetchScheduler
    @EnvironmentObject var githubScheduler: GitHubStatusScheduler
    @EnvironmentObject var configStore: ConfigStore
    @State private var isHovered = false
    @StateObject private var frameRef = RowFrameReference()

    var body: some View {
        let fetchState = fetchStateStore.states[repo.url.standardizedFileURL.path]
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Name + branch. Clickable area for the default action.
            Button(action: onDefault) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(repo.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if let fetchState, FetchScheduler.shouldSurfaceFailure(fetchState) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(FetchScheduler.isDisabled(fetchState)
                                                 ? Color.primary.opacity(0.40)
                                                 : Color.orange)
                                .help(fetchFailureTooltip(fetchState))
                        }
                    }
                    Text(repo.status?.displayBranch ?? "Loading…")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.70))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            // Right: status badges. Push and pull badges are independently
            // clickable; the rest are read-only counts.
            if let status = repo.status {
                StatusBadges(
                    status: status,
                    githubStatus: showGitHubStatusForThisRepo
                        ? githubScheduler.statuses[repo.url]
                        : nil,
                    inFlight: store.inFlight[repo.id],
                    onPush: { store.push(repo: repo) },
                    onPull: { store.pull(repo: repo) },
                    onOpenPRs: { openPRsPage() },
                    onOpenCI: { openCIPage() }
                )
            }

        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: interactiveCornerRadius)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
        )
        // Outer padding: the "gap" between rows at the popup edge still
        // counts as part of the row for hover purposes. Without
        // contentShape the outer padding is empty space and the hover
        // flickers off when the cursor drifts into it.
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(RowFrameReader(reference: frameRef))
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering, hovering ? frameRef.currentFrameOnScreen : nil)
        }
        .contextMenu {
            Section("Open with") {
                ForEach(actions) { action in
                    Button {
                        onAlternate(action)
                    } label: {
                        Label {
                            Text(action.name)
                        } icon: {
                            if let nsImage = AppIcons.icon(for: action) {
                                Image(nsImage: resized(nsImage, to: 16))
                            } else {
                                Image(systemName: "terminal")
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    fetchScheduler.manualFetch(repos: [repo])
                } label: {
                    Label("Fetch from remote", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    openRemoteInBrowser()
                } label: {
                    Label("Open remote in browser", systemImage: "safari")
                }
                if configStore.config.showGitHubStatus {
                    Button {
                        toggleGitHubMute()
                    } label: {
                        if showGitHubStatusForThisRepo {
                            Label("Mute GitHub status", systemImage: "eye.slash")
                        } else {
                            Label("Unmute GitHub status", systemImage: "eye")
                        }
                    }
                }
            }
        }
    }

    /// Whether GitHub-side badges should render for this row. Honors
    /// both the global Show toggle and the per-repo mute list.
    private var showGitHubStatusForThisRepo: Bool {
        guard configStore.config.showGitHubStatus else { return false }
        return !configStore.config.gitHubMutedRepos.contains(repo.url.standardizedFileURL.path)
    }

    private func toggleGitHubMute() {
        let key = repo.url.standardizedFileURL.path
        if let idx = configStore.config.gitHubMutedRepos.firstIndex(of: key) {
            configStore.config.gitHubMutedRepos.remove(at: idx)
        } else {
            configStore.config.gitHubMutedRepos.append(key)
        }
    }

    /// Opens the repo's remote in the user's default browser. Works for
    /// any host (GitHub, GitLab, Bitbucket, self-hosted) by translating
    /// the SSH or HTTPS clone URL into the host's web URL.
    private func openRemoteInBrowser() {
        guard let urlString = GitService.remoteURL(at: repo.url),
              let webURL = Self.remoteWebURL(from: urlString) else {
            return
        }
        NSWorkspace.shared.open(webURL)
    }

    /// Translate any remote URL — SSH `git@host:owner/repo[.git]`,
    /// `ssh://git@host/path`, or `https://host/path[.git]` — into the
    /// host's web URL. Returns nil for unparseable input or local-only
    /// remotes; callers treat that as "no remote, don't open."
    static func remoteWebURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // SCP-style SSH: `git@host:owner/repo[.git]`. Has no scheme,
        // contains a colon, and the part before the colon parses as
        // user@host.
        if !trimmed.contains("://"), let colonIdx = trimmed.firstIndex(of: ":") {
            let userHost = trimmed[..<colonIdx]
            let pathPart = trimmed[trimmed.index(after: colonIdx)...]
            let host = userHost.split(separator: "@").last.map(String.init) ?? String(userHost)
            let cleaned = stripDotGit(String(pathPart))
            guard !host.isEmpty, !cleaned.isEmpty else { return nil }
            return URL(string: "https://\(host)/\(cleaned)")
        }

        // URL form (ssh://, https://, http://, git://).
        guard let url = URL(string: trimmed),
              let host = url.host, !host.isEmpty else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleaned = stripDotGit(path)
        guard !cleaned.isEmpty else { return nil }
        return URL(string: "https://\(host)/\(cleaned)")
    }

    private static func stripDotGit(_ path: String) -> String {
        path.hasSuffix(".git") ? String(path.dropLast(4)) : path
    }

    /// Opens the PR list page for this repo on github.com. Resolves the
    /// owner/repo from the local origin URL — if the remote isn't a
    /// GitHub remote, the click does nothing (the badge wouldn't have
    /// been rendered in that case anyway).
    private func openPRsPage() {
        guard let urlString = GitService.remoteURL(at: repo.url),
              let remote = GitHubRemoteParser.parse(urlString),
              let url = URL(string: "https://github.com/\(remote.owner)/\(remote.repo)/pulls") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens the GitHub Actions page for this repo, pre-filtered to the
    /// current branch when one is known. The badge tracks workflow-run
    /// conclusions (not third-party check apps), so /actions is the
    /// page that surfaces exactly what our badge represents.
    private func openCIPage() {
        guard let urlString = GitService.remoteURL(at: repo.url),
              let remote = GitHubRemoteParser.parse(urlString) else {
            return
        }
        var path = "https://github.com/\(remote.owner)/\(remote.repo)/actions"
        if let branch = repo.status?.branch, branch != "(detached)",
           let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?query=branch:\(encoded)"
        }
        if let url = URL(string: path) {
            NSWorkspace.shared.open(url)
        }
    }

    private func fetchFailureTooltip(_ state: FetchState) -> String {
        if FetchScheduler.isDisabled(state) {
            return "Fetch disabled — Option-click refresh to retry"
        }
        let n = state.consecutiveFailures
        let attempts = n == 1 ? "1 attempt" : "\(n) attempts"
        return "Fetch failed (\(attempts))"
    }

    private func resized(_ image: NSImage, to size: CGFloat) -> NSImage {
        let target = NSSize(width: size, height: size)
        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }
}

/// Rich hover detail for a repo row. Shows every pending state as its own
/// section with a colored glyph, count, and the paths or commit subjects
/// backing it. Matches the glyph/color scheme of the inline badges so the
/// popover reads as "the badges, expanded".
struct RepoDetailPopover: View {
    let repoName: String
    let repoURL: URL
    let status: RepoStatus
    var actions: [Action] = []
    var fetchEnabled: Bool = false
    var fetchStateStore: FetchStateStore? = nil
    var fetchScheduler: FetchScheduler? = nil
    var githubStatus: GitHubRepoStatus? = nil
    var onAction: (Action) -> Void = { _ in }
    var onFetch: (() -> Void)? = nil

    /// Max paths/commits to list per section before "+N more".
    private static let itemLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if status.isClean && !hasGitHubSignal {
                cleanMessage
            } else {
                sections
                githubSections
            }
            if fetchEnabled,
               let fetchStateStore,
               let fetchScheduler {
                LiveFetchStatusLine(
                    repoURL: repoURL,
                    fetchStateStore: fetchStateStore,
                    fetchScheduler: fetchScheduler,
                    onFetch: onFetch
                )
            }
        }
        .padding(14)
        .frame(minWidth: 260, idealWidth: 320, maxWidth: 420, alignment: .leading)
    }

    /// True if there's a non-trivial GitHub signal worth explaining —
    /// otherwise we still show "No pending changes" for clean repos.
    private var hasGitHubSignal: Bool {
        guard let gh = githubStatus else { return false }
        if gh.ciStatus == .failure || gh.ciStatus == .pending { return true }
        if let prs = gh.prCount, !prs.isEmpty { return true }
        return false
    }

    @ViewBuilder
    private var githubSections: some View {
        if let gh = githubStatus {
            // CI: failure and pending each get a one-liner with the
            // matching badge icon. Green is silent. Phrasing is kept
            // tight so the line wraps to one row in the typical card
            // width — the panel's branch context already implies "this
            // branch", so we don't repeat it.
            switch gh.ciStatus {
            case .failure:
                GitHubLine(
                    systemImage: "xmark.circle.fill",
                    color: .red,
                    text: failureText(failing: gh.failingCheckNames)
                )
            case .pending:
                GitHubLine(
                    systemImage: "record.circle.fill",
                    color: .yellow,
                    text: "CI is running on the latest push"
                )
            default:
                EmptyView()
            }
            // PRs: only render when there's something open. Phrase the
            // line so the human/bot split is unambiguous in plain text.
            // Color matches the popover badge (.indigo) for consistency.
            if let prs = gh.prCount, !prs.isEmpty {
                GitHubLine(
                    systemImage: "arrow.triangle.pull",
                    color: .indigo,
                    text: prText(prs)
                )
            }
        }
    }

    /// Failure line text. When we know which check broke, name it —
    /// otherwise stick with the generic phrasing. Capping at three names
    /// keeps the line readable when many checks fail at once.
    private func failureText(failing names: [String]) -> String {
        guard !names.isEmpty else { return "CI failed on the latest push" }
        let head = names.prefix(3).joined(separator: ", ")
        if names.count > 3 {
            return "CI failed: \(head) +\(names.count - 3) more"
        }
        return "CI failed: \(head)"
    }

    private func prText(_ prs: PRCount) -> String {
        // Same shape across all three cases ("X PR(s) by humans/bots")
        // so the wording is predictable. Mixed-case symmetry — both
        // halves use "by …" — keeps the second number from reading as
        // a subset of the first.
        let prWord = { (n: Int) in n == 1 ? "PR" : "PRs" }
        switch (prs.humans, prs.bots) {
        case (0, let b):
            return "\(b) \(prWord(b)) by bots"
        case (let h, 0):
            return "\(h) \(prWord(h)) by humans"
        case (let h, let b):
            return "\(h) \(prWord(h)) by humans · \(b) by bots"
        }
    }

    /// Bottom-row "Last fetched X ago" line, observing FetchStateStore +
    /// FetchScheduler so the text refreshes the moment a fetch completes
    /// and the icon swaps to a spinner while one is in flight. Clickable
    /// to force a fetch when `onFetch` is wired — same call as the
    /// "Fetch from remote" item in the row's right-click menu.
    private struct LiveFetchStatusLine: View {
        let repoURL: URL
        @ObservedObject var fetchStateStore: FetchStateStore
        @ObservedObject var fetchScheduler: FetchScheduler
        let onFetch: (() -> Void)?
        @State private var isHovering = false

        private var state: FetchState { fetchStateStore.state(for: repoURL) }
        private var isFetching: Bool { fetchScheduler.inFlightURLs.contains(repoURL) }

        var body: some View {
            if state.noRemote {
                // Don't waste a row on no-remote repos in the detail panel.
                EmptyView()
            } else {
                Divider()
                if let onFetch {
                    Button(action: onFetch) {
                        content
                    }
                    .buttonStyle(.plain)
                    .disabled(isFetching)
                    .onHover { hovering in
                        isHovering = hovering && !isFetching
                        if hovering && !isFetching {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                } else {
                    content
                }
            }
        }

        @ViewBuilder
        private var content: some View {
            HStack(spacing: 6) {
                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: state.consecutiveFailures == 0
                          ? "arrow.clockwise"
                          : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(state.consecutiveFailures == 0
                                         ? .primary.opacity(isHovering ? 0.85 : 0.50)
                                         : Color.orange)
                        .frame(width: 12, height: 12)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(isHovering ? 0.95 : 0.70))
            }
        }

        private var statusText: String {
            if isFetching { return "Fetching…" }
            if state.consecutiveFailures > 0 {
                if let last = state.lastAttemptAt {
                    return "Last fetch failed \(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))"
                }
                return "Last fetch failed"
            }
            if let success = state.lastSuccessAt {
                return "Last fetched \(Self.relativeFormatter.localizedString(for: success, relativeTo: Date()))"
            }
            return "Not fetched yet"
        }

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return f
        }()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(repoName)
                .font(.headline)
            Text(status.displayBranch)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.70))
                .monospaced()
        }
    }

    private var cleanMessage: some View {
        Label("No pending changes", systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
    }

    /// Single-line GitHub-side signal explainer used in the hover detail
    /// panel. Mirrors the icon + color of the popover badge so the line
    /// reads as "the badge, in words". Aligned to the first text baseline
    /// so the icon sits next to the first line if the text wraps to two.
    private struct GitHubLine: View {
        let systemImage: String
        let color: Color
        let text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(color)
                    .frame(width: 16, alignment: .center)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        if status.ahead > 0 {
            DetailSection(
                glyph: "↑",
                noun: "commit to push",
                count: status.ahead,
                items: status.aheadCommits,
                color: .blue,
                limit: Self.itemLimit
            )
        }
        if status.behind > 0 {
            DetailSection(
                glyph: "↓",
                noun: "commit to pull",
                count: status.behind,
                items: status.behindCommits,
                color: .purple,
                limit: Self.itemLimit
            )
        }
        if status.untracked > 0 {
            DetailSection(
                glyph: "★",
                noun: "untracked file",
                count: status.untracked,
                items: status.untrackedPaths,
                color: .green,
                limit: Self.itemLimit
            )
        }
        if status.unstaged > 0 {
            DetailSection(
                glyph: "●",
                noun: "modified file",
                count: status.unstaged,
                items: status.unstagedPaths,
                color: .orange,
                limit: Self.itemLimit
            )
        }
        if status.staged > 0 {
            DetailSection(
                glyph: "+",
                noun: "staged file",
                count: status.staged,
                items: status.stagedPaths,
                color: .teal,
                limit: Self.itemLimit
            )
        }
    }
}

private struct DetailSection: View {
    let glyph: String
    let noun: String
    let count: Int
    let items: [String]
    let color: Color
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(glyph)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                Text(headerText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            if items.isEmpty {
                // `git log` follow-up failed (rare) — header alone is fine.
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary.opacity(0.70))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if items.count > limit {
                        Text("+\(items.count - limit) more")
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.50))
                    }
                }
                .padding(.leading, 18) // align under the header text, not the glyph
            }
        }
    }

    private var headerText: String {
        let word = count == 1 ? noun : noun + "s"
        return "\(count) \(word)"
    }
}

struct StatusBadges: View {
    let status: RepoStatus
    let githubStatus: GitHubRepoStatus?
    let inFlight: InFlightAction?
    let onPush: () -> Void
    let onPull: () -> Void
    let onOpenPRs: () -> Void
    let onOpenCI: () -> Void

    var body: some View {
        // The green "all clear" checkmark only appears when *nothing*
        // needs attention — local-clean alone isn't enough, since a
        // failing CI or open PR also counts. Otherwise it'd sit next to
        // the very badges it contradicts.
        let hasCIBadge = githubStatus?.ciStatus == .failure
                      || githubStatus?.ciStatus == .pending
        let hasPRBadge = githubStatus?.prCount?.isEmpty == false
        let allClear = status.isClean && !hasCIBadge && !hasPRBadge

        HStack(spacing: 4) {
            // GitHub-side signals come first — they're "outside world"
            // status, separate from the local git state pills on the right.
            // CI red/running is rendered as a single icon (no count); PR
            // pill shows the human/bot split with the bot tail muted.
            if let gh = githubStatus {
                CIBadge(status: gh.ciStatus, action: onOpenCI)
                if let prs = gh.prCount, !prs.isEmpty {
                    PRBadge(count: prs, action: onOpenPRs)
                }
            }

            if allClear {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.green)
            } else if !status.isClean {
                // Commit-level state first (ahead / behind), then file-level
                // as a progression (untracked → unstaged → staged). Unicode
                // arrows for direction, git porcelain letters for file state.
                // The ahead/behind badges are interactive — click to push/pull.
                if status.ahead > 0 {
                    ActionBadge(
                        glyph: "↑",
                        count: status.ahead,
                        color: .blue,
                        isInFlight: inFlight == .push,
                        action: onPush
                    )
                }
                if status.behind > 0 {
                    ActionBadge(
                        glyph: "↓",
                        count: status.behind,
                        color: .purple,
                        isInFlight: inFlight == .pull,
                        action: onPull
                    )
                }
                if status.untracked > 0 {
                    ReadOnlyBadge(glyph: "★", count: status.untracked, color: .green)
                }
                if status.unstaged > 0 {
                    ReadOnlyBadge(glyph: "●", count: status.unstaged, color: .orange)
                }
                if status.staged > 0 {
                    ReadOnlyBadge(glyph: "+", count: status.staged, color: .teal)
                }
            }
        }
    }
}

/// Compact PR pill: `⤴ 4 / 2` where `4` is human-authored open PRs in
/// the primary color and `/ 2` is bot PRs in a muted secondary color.
/// Bots stay visible but recede so dependabot pile-ups don't shout.
/// Edge cases:
///   - Only humans → just `⤴ N`
///   - Only bots   → `⤴ N` rendered fully muted
private struct PRBadge: View {
    let count: PRCount
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        // .indigo so the pill never reads as a push/pull badge — the
        // existing ↑/↓ pills already own .blue/.purple. Border and icon
        // are always indigo so the pill's identity stays consistent
        // across human-only, bot-only, and mixed cases. The numeric
        // weight follows authorship: human counts in primary, bot
        // counts in muted secondary — so a bot-only pile-up reads as
        // "low priority noise" while humans-needed-attention stays
        // visually loud.
        let primary: Color = .indigo
        let isBotOnly = count.humans == 0
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull")
                    .foregroundStyle(primary)
                Text("\(count.humans > 0 ? count.humans : count.bots)")
                    .foregroundStyle(isBotOnly ? .secondary : primary)
                if count.humans > 0 && count.bots > 0 {
                    // Stay in the indigo family but much lighter, so the
                    // bot tail recedes visually while still feeling like
                    // part of the same pill rather than disconnected
                    // grey text.
                    Text("/ \(count.bots)")
                        .foregroundStyle(primary.opacity(0.4))
                }
            }
            .font(.body.weight(.medium).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: interactiveCornerRadius)
                    .fill(isHovered ? primary.opacity(0.18) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: interactiveCornerRadius)
                    .strokeBorder(primary.opacity(isHovered ? 0.0 : 0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: interactiveCornerRadius))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
        .help(prTooltip)
    }

    private var prTooltip: String {
        switch (count.humans, count.bots) {
        case (0, let b): return "\(b) bot PR\(b == 1 ? "" : "s") open"
        case (let h, 0): return "\(h) PR\(h == 1 ? "" : "s") open"
        case (let h, let b): return "\(h) PR\(h == 1 ? "" : "s") · \(b) by bots"
        }
    }
}

/// CI status indicator. Renders nothing for `.success` and `.none` —
/// matches the "hide repos with no changes" philosophy: green CI is not
/// a signal worth showing. `.failure` and `.pending` get visible icons.
private struct CIBadge: View {
    let status: CIStatus
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        // Icon + color follow GitHub Actions' own visual language so
        // the badges read as "this is what github.com would show":
        //   ✕ red filled circle  → failure
        //   ◉ yellow ring + dot  → running / queued
        switch status {
        case .failure:
            badge(systemName: "xmark.circle.fill", color: .red, tip: "CI failed on the latest push to this branch")
        case .pending:
            badge(systemName: "record.circle.fill", color: .yellow, tip: "CI is running on the latest push")
        default:
            EmptyView()
        }
    }

    private func badge(systemName: String, color: Color, tip: String) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: interactiveCornerRadius)
                        .fill(isHovered ? color.opacity(0.18) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: interactiveCornerRadius)
                        .strokeBorder(color.opacity(isHovered ? 0.0 : 0.35), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: interactiveCornerRadius))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
        .help(tip)
    }
}

/// Read-only status indicator — untracked / modified / staged. No hover
/// state, no tooltip — the enclosing row's detail popover surfaces the
/// full breakdown on hover.
private struct ReadOnlyBadge: View {
    let glyph: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Text(glyph)
            Text("\(count)")
        }
        .font(.body.weight(.medium).monospacedDigit())
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}


/// Interactive push/pull badge. Shows a hover-fill and a pointing-hand
/// cursor so it's obviously clickable, and swaps to a spinner while the
/// command is running. Details (counts, commit subjects) are surfaced
/// via the enclosing row's hover popover instead of a per-badge tooltip.
private struct ActionBadge: View {
    let glyph: String
    let count: Int
    let color: Color
    let isInFlight: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 14)
                } else {
                    HStack(spacing: 2) {
                        Text(glyph)
                        Text("\(count)")
                    }
                }
            }
            .font(.body.weight(.medium).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: interactiveCornerRadius)
                    .fill(isHovered ? color.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: interactiveCornerRadius)
                    .strokeBorder(color.opacity(isHovered ? 0.0 : 0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: interactiveCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isInFlight)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Actions menu button

/// A "⋯" button that shows the configured actions as a native NSMenu.
/// Replaces SwiftUI's `.contextMenu` which doesn't work inside an
/// NSMenu custom-view item (the menu's tracking loop swallows events).
private struct ActionsMenuButton: View {
    let actions: [Action]
    let onAction: (Action) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            showMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.primary.opacity(isHovered ? 0.70 : 0.40))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for action in actions {
            let item = ActionMenuItem(title: action.name, callback: { onAction(action) })
            if let nsImage = AppIcons.icon(for: action) {
                let size: CGFloat = 16
                let resized = NSImage(size: NSSize(width: size, height: size))
                resized.lockFocus()
                nsImage.draw(in: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
                             from: .zero, operation: .sourceOver, fraction: 1.0)
                resized.unlockFocus()
                item.image = resized
            }
            menu.addItem(item)
        }

        // Show at the mouse location.
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }
}

/// NSMenuItem subclass that holds a closure callback instead of
/// relying on target-action with a stable `self` reference.
private final class ActionMenuItem: NSMenuItem {
    private let callback: () -> Void

    init(title: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { callback() }
}
