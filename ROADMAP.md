# Roadmap

Informal plan for what's next. Tracks roughly by version. Not a promise —
order can shift, ideas can drop.

## Where we are

**v0.6.2** (2026-04-30) — popover polish. Bottom row's subtitle no
longer briefly clips on first show: a synchronous `intrinsicContentSize`
read can lag SwiftUI's settled body by 15-20pt when a Combine publisher
hasn't yet committed, so we now follow up with a one-tick async resize
that catches the drift before the user sees it. Switching Spaces /
Mission Control desktops dismisses the popover so the next menu-bar
click opens a fresh one on the current desktop, matching the rest of
macOS's status-bar apps. README gained screenshots, a Download section
pointing at the GitHub release, and a few stale technical references
got fixed.

**v0.6.1** (2026-04-30) — first signed + notarized release. Apple Developer ID
signing with hardened runtime + secure timestamp, universal binary
(`arm64` + `x86_64`), `release.sh` automates the whole pipeline (build,
sign, notarize, staple, appcast, GitHub release, version commit). Bundle
id renamed to `nl.defrog.uncommitted` for proper reverse-DNS hygiene.
Hover detail panel's "Last fetched X ago" line is now a clickable refresh
that shows a live spinner while a fetch is in flight; the popup footer
shifted Settings to a gear icon to match the header chrome.

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

## Distribution follow-ups

- [ ] Personal Homebrew tap at `thimo/homebrew-tap` with a
      `Casks/uncommitted.rb` pointing at the latest GitHub Release zip.

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
