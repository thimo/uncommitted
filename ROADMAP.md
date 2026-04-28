# Roadmap

Informal plan for what's next. Tracks roughly by version. Not a promise —
order can shift, ideas can drop.

## Where we are

**v0.5.0** (2026-04) — GitHub PR + CI signals per repo. PR pill shows
`⤴ N / N` (humans / bots, bot count muted), CI surfaces only red and
running (green stays silent), menu-bar branch icon turns red when any
tracked repo has red CI. Backed by the `gh` CLI with tiered refresh
(15 min for recent-active, 1×/day rest, eager on popover open, fast
re-poll on failing/pending CI), multi-clone-aware caching, and a
graceful-degrade banner when `gh` isn't installed. Row context menu
also gained "Open remote in browser".

**v0.4.0** (2026-04-11) — first tagged release. Daily-usable: AppKit-hosted
menu bar, configurable actions, per-source scan depth, git-porcelain status
badges, four-tab Settings, Sparkle 2.x auto-updater integrated, MIT license
on GitHub.

Distribution is still ad-hoc signed — no notarized binary yet.

## v0.6 — Distribution

Goal: ship a signed, notarized binary so anyone with a Mac can install
Uncommitted without running `swift build`. Blocked on Apple Developer
Program enrollment (in progress 2026-04-26).

- [ ] Enroll in Apple Developer Program (~$99/year)
- [ ] Generate a Developer ID Application certificate
- [ ] Store notary credentials with `xcrun notarytool store-credentials`
- [ ] Wire `build.sh` to read `UNCOMMITTED_SIGN_IDENTITY` from `.env.local`
      — use it when set, fall back to ad-hoc for dev builds
- [ ] Add `--timestamp --options runtime` to the `codesign` call
- [ ] Build universal (`arm64` + `x86_64`) so both architectures work
- [ ] New `release.sh`: builds release, zips with `ditto`, submits to
      notarytool, staples the ticket, re-zips for upload, runs `spctl` for
      sanity, runs `generate_appcast` to update `appcast.xml`, commits
      and tags
- [ ] Add a "Download" section at the top of the README
- [ ] Create a personal Homebrew tap at `thimo/homebrew-tap` with a
      `Casks/uncommitted.rb` pointing at the GitHub Release zip

The scaffolding for this is already in the repo: `.env.example` documents
the env vars the release flow needs. Sparkle 2.x is already integrated
(see CLAUDE.md). Only the script edits and the Apple enrollment step are
outstanding.

## Other ideas (unordered backlog)

These are worth doing when the mood strikes. Not blocked on anything.

- **Error reporting & crash logging.** Two parts: (1) surface git errors,
  parse failures, and watcher problems to the user instead of silently
  swallowing them — a small "last error" indicator, notification, or log
  viewer in Settings. (2) Crash/diagnostic reporting so users can share
  logs or they're uploaded automatically — something like Sentry, or
  Apple's MetricKit + `MXCrashDiagnostic`, or a lightweight custom
  solution that writes to `~/Library/Logs/Uncommitted/` with an "Export
  diagnostics…" button in Settings that bundles the last N log files
  for sharing.
- **Opt-in periodic status refresh.** Even with FSEvents and the existing
  sleep/wake backstop, nothing guarantees status reflects reality after
  long idle periods — some filesystem operations don't fire events, and
  other git tools (Tower, VSCode, dependabot) make changes out-of-band.
  Add an opt-in "refresh every N minutes" setting in General (default off,
  suggested 5–10 min when enabled) that runs `rebuildFromConfig()` on a
  timer. Distinct from the existing internal 10-min wake-recovery timer.
- **GitHub status follow-ups.** State-transition notifications opt-in
  ("CI just broke on repo X", "Dependabot opened a new PR"). Default branch
  CI as a secondary signal. Per-PR review status when current branch has
  an open PR.
- **Daily commit summary.** "Today's work" / "Yesterday" pull-down that
  pulls commits across all watched repos as markdown — useful for
  standups, FreeAgent descriptions, retros. Could replace parts of the
  existing FreeAgent-hours prompt scrape (`gh search commits`).
- **Stash awareness.** `≡ N` badge for stashed changes. Right-click a row
  → `git stash list` in a popover. Prevents forgotten stashes.
- **Quick commit from menu.** Hover repo row → small text input, Enter
  runs `git add -A && git commit -m "..."`. Power-user shortcut.
- **README screenshots.** `scripts/setup-screenshots.sh` creates demo
  repos in every status state. Drop the output into `docs/menubar.png`
  and friends, update the README image references.
- **Per-repo overrides.** Right-click a repo row → Pin, Hide, Rename.
  Config gets a `repoOverrides: [path: overrides]` map.
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
