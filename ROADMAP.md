# Roadmap

Informal plan for what's next. Tracks roughly by version. Not a promise —
order can shift, ideas can drop.

## Where we are

**v0.4.0** (2026-04-11) — first tagged release. Daily-usable: AppKit-hosted
menu bar, configurable actions, per-source scan depth, git-porcelain status
badges, four-tab Settings, Sparkle 2.x auto-updater integrated, MIT license
on GitHub.

Distribution is still ad-hoc signed — no notarized binary yet.

## v0.5 — GitHub status integration

Goal: surface PR and CI signals per repo. Uncommitted now answers two more
questions next to "do I need to commit/push?":

- "Is what I just pushed green?"
- "Is there anything queued (PRs, dependabot) that needs cleanup?"

**Design decisions (locked in 2026-04-26):**

- **CI status** — current branch's HEAD on remote. Silent if the branch is
  local-only; the branch-switch is the signal.
- **PR pill** — single badge `⤴ N / N` where the second number is bot-PR
  count, rendered muted. `arrow.triangle.pull` icon. Edge cases:
  - Only humans → just `⤴ N`
  - Only bots → `⤴ N` rendered fully muted
  - No PRs → no badge
- **CI icons** — only red and running show. Green stays silent (matches the
  "hide repos with no changes" philosophy).
  - Red: `exclamationmark.shield.fill` in `.systemRed`
  - Running: `clock.fill` in `.systemYellow`
  - Click red → `gh run view --web`
  - Click PR pill → `gh pr list --web`
- **Auth** — `gh` CLI as backend (`gh api ...` via Process). Reuses the user's
  existing `gh auth login`. Graceful degrade with a Settings banner if `gh`
  isn't installed; feature disables itself silently.
- **Refresh cadence** — tiered, internal:
  - Recent-active (commit <24h old or FSEvents activity): every 15 min
  - Rest: 1×/day
  - Popover-open: eager refresh of visible repos
  - Manual refresh button: forces all
- **Caching** — multi-clone-aware. Cache key for PR-count = `owner/repo`
  (shared across clones). CI status keyed by `owner/repo + commit-sha`
  (shared when clones happen to be on the same commit). Four clones of the
  same repo collapse to 1 PR fetch + N CI fetches where N = unique commits.
- **Menu bar** — branch icon turns red when any tracked repo has red CI.
  Count number stays on uncommitted+unpushed (pure git signal). Two bits
  of info at a glance: cijfer = "moet ik committen?", kleur = "is iets
  stuk?".
- **No notifications in v1** — visible-only. Notifications can come later
  if the visual signal isn't enough.

**Build sequence:**

- [ ] `UncommittedCore/GitHubStatus.swift` — model types
  (`GitHubRepoStatus`, `CIStatus`, `PRCount`)
- [ ] GitHub remote detection — parse `git remote get-url origin`, extract
  `owner/repo`, skip silently for non-GitHub remotes
- [ ] `gh api` Process wrapper — mirrors `GitService.execute()` patterns
  (subprocess, drain timeout, error surfacing)
- [ ] PR list fetch + bot filter (`user.type == "Bot"` or login matches
  `^(dependabot|renovate)`)
- [ ] CI status fetch — `repos/{owner}/{repo}/commits/{branch}/check-runs`,
  aggregate conclusion
- [ ] In-memory cache layer with TTL keyed per design above
- [ ] `GitHubStatusScheduler` — tiered cadence, popover-open eager refresh
- [ ] Popover row UI — PR pill, CI badge (placement: left of existing action
  pills, near the auto-fetch warning glyph)
- [ ] Menu-bar branch icon tint — red on any-CI-red
- [ ] Click handlers — `gh pr list --web` / `gh run view --web` via
  `NSWorkspace`
- [ ] Settings — master toggle "Show GitHub status", graceful-degrade banner
  if `gh` missing
- [ ] Tests — remote URL parser, bot filter, cache key collisions
- [ ] README section + `docs/github-integration.md` (`gh` install +
  `gh auth login` prerequisite)

**Open scope questions (revisit during build):**

- Does the PR pill count *all* open PRs, or only PRs against the default
  branch? Probably all — but worth re-checking once the data is real.
- Should CI status follow the local current branch even when that branch
  is checked out somewhere else? Walkable; revisit when implementing.

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
- **FSEvents safety net.** The watcher can drift after sleep/wake. Listen
  for `NSWorkspace.didWakeNotification` and rebuild the stream. Cheap
  belt-and-suspenders against silent drift. (Partially in place — see
  CLAUDE.md item 4.)
- **Interval-based status refresh.** Even with FSEvents, nothing guarantees
  the status reflects reality after long idle periods — FSEvents drops
  events on sleep, some filesystem operations don't fire events, and other
  git tools (Tower, VSCode, dependabot) make changes out-of-band that
  eventually get picked up but not immediately. Add an opt-in "refresh
  every N minutes" setting in General (default off, suggested 5–10 min
  when enabled) that runs `rebuildFromConfig()` on a timer.
- **GitHub status — phase 2.** State-transition notifications opt-in
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
