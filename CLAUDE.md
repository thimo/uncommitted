# Uncommitted

Native macOS menubar app for tracking uncommitted and unpushed git changes
across multiple repositories. LSUIElement, Swift Package Manager, AppKit +
SwiftUI hybrid.

This file is the fast-warm-up doc for Claude Code. For end-user docs see
`README.md`; for what's next see `ROADMAP.md`.

## Current state

- **v0.5.0** released. MIT-licensed on GitHub at `thimo/uncommitted`. Adds
  per-repo GitHub PR + CI signals via the `gh` CLI, with tiered refresh
  cadence and multi-clone-aware caching.
- **v0.6** (Distribution) is blocked on Apple Developer Program activation
  email. Once that lands: Developer ID signing, notarization, universal
  binary, release.sh, Homebrew tap. See `ROADMAP.md`.

## Build & install

- `./build.sh` — compiles release, renders the iconset, bundles the `.app`,
  ad-hoc signs, installs to `~/Applications/Uncommitted.app`.
  - **Kills any running instance** with `killall -q uncommitted` before
    replacing the bundle, so every build terminates the live app. User
    needs to relaunch from Finder / menu bar after the build.
- `.build/release/UncommittedTests` — custom plain-Swift test runner, not
  XCTest/swift-testing (neither ships with the CLT). 26 tests covering
  parser, config round-trip, repo resolution.

## Target layout

Three SPM targets:

- **`UncommittedCore`** (library) — `Sources/UncommittedCore/`. Holds
  `Config`, `Repo`/`RepoStatus`, `GitService`, `RepoStore`, `RepoWatcher`.
  Imported by the executable and the test runner.
- **`Uncommitted`** (executable) — `Sources/Uncommitted/`. AppKit delegate,
  SwiftUI views, hover detail panel, settings.
- **`UncommittedTests`** (executable) — `Tests/UncommittedTests/`. Runs as
  a plain binary, not via `swift test`.

## Non-obvious architecture

Read this before wondering why a choice looks weird. These are deliberate
and usually fix a specific pitfall:

1. **NSMenu with custom-view item, not SwiftUI `MenuBarExtra`.** The
   popup is an NSMenu containing one NSMenuItem whose `view` is an
   NSHostingView with our SwiftUI content — the same approach CodexBar
   and iStat Menus use. NSMenu gives us system-managed button highlight,
   proper dismissal of other status item menus, correct positioning, and
   no arrow. Earlier iterations used NSPopover (arrow can't be hidden on
   macOS 15) and a custom NSPanel (couldn't get reliable button highlight
   or cross-menu dismiss). Code in `AppDelegate.swift`.

2. **FSEvents with a retained context.** `RepoWatcher.swift` uses
   `Unmanaged.passRetained(self)` as the stream's info pointer plus a
   matching release callback. Without that, in-flight callbacks can race
   `stop()` and deref a dangling pointer.

3. **Pipe drain timeout after git exits.** `GitService.execute()` waits
   unbounded for `git` itself (slow fetches are fine) then applies a 2s
   timeout on the stdout/stderr drain. Catches the case where an ssh
   `ControlMaster` child subprocess inherited our pipe FDs and is keeping
   them open past git's own exit — EOF never fires otherwise. Process-
   group kill on timeout.

4. **Sleep/wake + 10-min safety net.** `RepoStore` observes
   `NSWorkspace.didWakeNotification` and runs a slow repeating timer that
   calls `rebuildFromConfig()`. FSEvents drifts after sleep and misses
   out-of-band changes from other tools; this is the backstop.

5. **Hover detail panel is a custom `NSPanel`, not SwiftUI `.popover`.**
   `HoverDetailWindow.swift`. We tried SwiftUI `.popover` three ways
   (default fade, `animates=false`, hit-testing) — all rejected. Problems:
   the default fade is too slow and there's no duration knob, hit-testing
   makes clicks dismiss the main `.transient` popover, and `.popover` in
   a `ForEach` oscillates when swapping between rows. The custom panel is
   attached as a **child window** of the main popup so clicks don't kill
   the parent, picks right-of-popup or left-of-popup by available screen
   space, and uses a unified `CardWithArrowShape` (single path) so the
   card and pointer arrow render as one material fill — no visible seam.

6. **Sparkle 2.x auto-updater.** Added as an SPM binary dependency. The
   `SPUStandardUpdaterController` is initialized in `AppDelegate.init()`
   with `startingUpdater: true`. The EdDSA public key (`SUPublicEDKey`)
   and feed URL (`SUFeedURL`) live in `Resources/Info.plist`. The private
   key is stored in the macOS Keychain by Sparkle's `generate_keys` tool
   — never on disk, never in the repo. `release.sh` runs `generate_appcast`
   after stapling to produce/update `appcast.xml` in the repo root,
   which is read from GitHub raw by Sparkle at runtime.

7. **App icon follows Apple's Big Sur template strictly.** `make-icon.swift`
   draws the gradient inside an 824×824 rect centered in a 1024 canvas,
   with the 100px gutter reserved for the drop shadow (28px blur, 12px Y,
   50% black). Drawing full-bleed made macOS Quick Look wrap the icon in
   its generic grey container — the template geometry is the fix.

## Key files

- `Sources/Uncommitted/AppDelegate.swift` — menu bar + NSMenu-based popup
- `Sources/Uncommitted/MenuContentView.swift` — main popup SwiftUI, repo
  rows, badges, context menu, hover detail wiring
- `Sources/Uncommitted/HoverDetailWindow.swift` — custom NSPanel, positioning,
  fade, `CardWithArrowShape`
- `Sources/Uncommitted/SettingsView.swift` — General/Repositories/Actions/About tabs
- `Sources/UncommittedCore/RepoStore.swift` — repos + FSEvents + backstops
- `Sources/UncommittedCore/GitService.swift` — subprocess runner, parser,
  commit subject fetch for hover detail
- `Sources/UncommittedCore/Models.swift` — `Repo`, `RepoStatus` (counts are
  computed from `*Paths` arrays so they can't drift)
- `Resources/make-icon.swift` — programmatic iconset renderer
- `Resources/Info.plist` — LSUIElement, Sparkle keys (SUFeedURL, SUPublicEDKey)
- `Resources/Uncommitted.entitlements` — hardened runtime for notarization
- `release.sh` — full release pipeline (universal build, sign, notarize, appcast, GitHub release)
- `appcast.xml` — Sparkle update feed (generated by release.sh, committed to main)

## Conventions

- **No `swift test`**. Run `./build.sh` (which compiles the test target)
  then `.build/release/UncommittedTests` to see test output.
- **Commit messages** kept short — subject + at most 1-2 sentences of why.
- **Don't push to origin** — user handles all pushes themselves.
- **Commit identity** — use `thimo@defrog.nl`.
