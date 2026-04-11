# Roadmap

Informal plan for what's next. Tracks roughly by version. Not a promise —
order can shift, ideas can drop.

## Where we are

**v0.4.0** (2026-04-11) — first tagged release. Feature-complete enough to
use daily: AppKit-hosted menu bar, configurable actions, per-source scan
depth, git-porcelain status badges, Settings with four tabs, MIT license on
GitHub.

Distribution is still "build from source" — no signed binary yet, no
auto-update.

## v0.5 — Distribution

Goal: ship a signed, notarized binary so anyone with a Mac can install
Uncommitted without running `swift build`.

- [ ] Enroll in Apple Developer Program (~$99/year)
- [ ] Generate a Developer ID Application certificate
- [ ] Store notary credentials with `xcrun notarytool store-credentials`
- [ ] Wire `build.sh` to read `UNCOMMITTED_SIGN_IDENTITY` from `.env.local`
      — use it when set, fall back to ad-hoc for dev builds
- [ ] Add `--timestamp --options runtime` to the `codesign` call
- [ ] Build universal (`arm64` + `x86_64`) so both architectures work
- [ ] New `release.sh`: calls `build.sh` in release mode, zips with
      `ditto`, submits to notarytool, staples the ticket, re-zips for
      upload, runs `spctl` for sanity
- [ ] Add a "Download" section at the top of the README
- [ ] Create a personal Homebrew tap at `thimo/homebrew-tap` with a
      `Casks/uncommitted.rb` pointing at the GitHub Release zip

The scaffolding for this is already in the repo: `.env.example` documents
the env vars the release flow needs. Only the script edits and the Apple
enrollment step are outstanding.

## v0.5.1 — Cheap auto-update nag

Goal: tell users when there's a new release, without the Sparkle ceremony.
Depends on v0.5 (signed binaries so the "install" link actually works).

- [ ] On app launch (and once an hour after), hit
      `GET https://api.github.com/repos/thimo/uncommitted/releases/latest`
- [ ] Compare `tag_name` with `CFBundleShortVersionString`
- [ ] If newer, show an `NSAlert` or a Settings banner: "Uncommitted 0.6.0
      is available. [Open Release Page] [Later] [Don't ask again]"
- [ ] User clicks through, downloads from the release page, manually
      replaces the app. Notification-driven, not silent.

Cheapest possible solution — ~40 lines of Swift, no dependencies, no
EdDSA keys, works immediately after v0.5 lands.

## v0.7 — Sparkle auto-updater

Goal: proper silent background updates. Depends on v0.5 (real code
signing is non-negotiable for Sparkle).

- [ ] Add [Sparkle 2.x](https://sparkle-project.org/) as a Swift Package
      dependency
- [ ] Generate an EdDSA keypair with Sparkle's `generate_keys` tool —
      keep the private key out of the repo, embed the public key in
      `Info.plist` as `SUPublicEDKey`
- [ ] Initialize `SPUStandardUpdaterController` in `AppDelegate` with
      `startingUpdater: true`
- [ ] Configure `Info.plist`: `SUFeedURL` pointing at
      `https://raw.githubusercontent.com/thimo/uncommitted/main/appcast.xml`
- [ ] Add a "Check for Updates…" menu item in the popover footer
- [ ] Extend `release.sh` to run `generate_appcast build/` after each
      release, which produces/updates `appcast.xml` with correct
      version, size, EdDSA signature, and download URL
- [ ] Commit and push `appcast.xml` alongside the release tag

The whole feed lives in the GitHub repo — no separate website, no CDN,
no hosting bill. Sparkle reads XML from GitHub raw just fine.

## Other ideas (unordered backlog)

These are worth doing when the mood strikes. Not blocked on anything.

- **FSEvents safety net.** The watcher can drift after sleep/wake. Listen
  for `NSWorkspace.didWakeNotification` and rebuild the stream. Cheap
  belt-and-suspenders against silent drift.
- **Interval-based status refresh.** Even with FSEvents, nothing guarantees
  the status reflects reality after long idle periods — FSEvents drops
  events on sleep, some filesystem operations don't fire events, and other
  git tools (Tower, VSCode, dependabot) make changes out-of-band that
  eventually get picked up but not immediately. Add an opt-in "refresh
  every N minutes" setting in General (default off, suggested 5–10 min
  when enabled) that runs `rebuildFromConfig()` on a timer. Independent
  of `git fetch` — this is purely status re-checks, so no network. Pairs
  well with the FSEvents safety net above as defense in depth.
- **README screenshots.** `scripts/setup-screenshots.sh` creates demo
  repos in every status state. Drop the output into `docs/menubar.png`
  and friends, update the README image references.
- **Per-repo overrides.** Right-click a repo row → Pin, Hide, Rename.
  Config gets a `repoOverrides: [path: overrides]` map.
- **Keyboard shortcut** to open the popover from anywhere — via the
  [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
  package. `Cmd+Shift+U` default, user-configurable.
- **Custom branch filters.** Hide repos whose current branch matches
  `main`, `master`, `develop` — useful for folks who only care about
  feature branches needing commit/push.
- **Click behavior toggles.** Different click = different action (e.g.
  left-click default, Opt-click second, etc.) instead of right-click for
  alternates. Or in addition.
- **Status tooltips.** Hover a badge → tooltip with the full breakdown
  ("3 new files: `routes.ts`, `models.ts`, `middleware.ts`").
- **Badge styles setting.** Some people prefer symbols, some prefer
  letters, some prefer Xcode-style coloured dots. Make it a picker.
- **Dark mode accent tuning.** Status badge colors work in both modes but
  could use a pass for readability in dark.
