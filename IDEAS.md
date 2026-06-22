# Ideas

Unordered backlog of things worth doing when the mood strikes — not a plan,
not a promise, nothing here is blocked or scheduled. What already shipped
lives in `CHANGELOG.md`; current state is in `CLAUDE.md`.

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
  CI as a secondary signal — the CI cousin of the v0.9.0 "other branches"
  work, and a natural fit now that the panel already tracks other branches.
  Per-PR review status when current branch has an open PR.
- **Daily commit summary.** "Today's work" / "Yesterday" pull-down that
  pulls commits across all watched repos as markdown — useful for
  standups, FreeAgent descriptions, retros. Could replace parts of the
  existing FreeAgent-hours prompt scrape (`gh search commits`).
- **Stash awareness.** `≡ N` badge for stashed changes. Right-click a row
  → `git stash list` in a popover. Prevents forgotten stashes.
- **Quick commit from menu.** Hover repo row → small text input, Enter
  runs `git add -A && git commit -m "..."`. Power-user shortcut.
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
- **Homebrew tap.** (Unstarted — `thimo/homebrew-tap` doesn't exist yet.)
  A personal tap with a `Casks/uncommitted.rb` pointing at the latest
  GitHub Release zip, so `brew install --cask` works. Only worth it if the
  install-via-Homebrew audience justifies maintaining the cask.

## README screenshots (mechanical TODO)

- `scripts/setup-screenshots.sh` creates demo repos in every status state.
  Drop the output into `docs/menubar.png` and friends, update the README
  image references.
