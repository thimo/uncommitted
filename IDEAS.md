# Ideas

Unordered backlog of things worth doing when the mood strikes — not a plan,
not a promise, nothing here is blocked or scheduled. What already shipped
lives in `CHANGELOG.md`; current state is in `CLAUDE.md`.

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
- **Per-repo overrides.** Right-click a repo row → Pin, Hide, Rename.
  Config gets a `repoOverrides: [path: overrides]` map.
- **Bulk pull across sibling clones (shared remote).** Several local clones
  of the same remote is common (e.g. `electrolyte`, `electrolyte-calcium`,
  `electrolyte-magnesium`, `electrolyte-natrium` — four worktrees of one
  repo). When you commit+push in one, the other three show "N to pull" and
  you currently fast-forward them one click at a time. The pain is the
  repeated clicks, not the visual layout — the clones already cluster by
  name and sort adjacently, so a group *header* buys almost nothing and
  taxes the common single-clone case with collapse/sort/label complexity.
  Lean version instead: detect siblings by shared remote URL
  (`GitService.remoteURL(at:)` already exists; add the value to `Repo` and
  compute sibling sets in `RepoStore`), and when ≥2 fast-forwardable
  siblings exist, offer one batch action — a row context-menu item ("Pull
  others on this remote (3)") or a hover-panel line ("3 sibling repos
  behind — pull all"). Open question: scope to same-remote-**and**-same-branch
  (safest — won't touch a clone parked on a feature branch) vs. same-remote-
  any-branch (broader). Only fast-forwardable siblings are eligible; diverged
  ones stay manual.
- **Custom branch filters.** Hide repos whose current branch matches
  `main`, `master`, `develop` — useful for folks who only care about
  feature branches needing commit/push.
- **Status tooltips.** Hover a badge → tooltip with the full breakdown
  ("3 new files: `routes.ts`, `models.ts`, `middleware.ts`").

## README screenshots (mechanical TODO)

- `scripts/setup-screenshots.sh` creates demo repos in every status state.
  Drop the output into `docs/menubar.png` and friends, update the README
  image references.
