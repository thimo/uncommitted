# Changelog

User-facing notes for each release. Bullets are curated — not a 1:1
mapping of commits.

## Unreleased

### Changed
- The PR badge no longer counts humans vs. bots — it now shows how many
  open PRs actually need you vs. how many are just open. Each PR is
  classified per-viewer: yours with changes requested, CI failing, or
  approved and ready to merge; someone else's where your review was
  requested or there are new commits since you last reviewed — all count
  as "mine". Everything else (awaiting the author, a bot's PR, one you're
  not involved in) counts as "waiting". The badge turns fully grey the
  moment nothing needs you, even if PRs are still open. The hover panel's
  single PR line is now a full list — every open PR by title, sorted so
  what needs you floats to the top, with drafts shown only there (they
  never make the row badge appear).
- Several clones of the same GitHub repo now show the PR badge on one of
  them only — the first in your repo list. PRs belong to the remote, not
  the clone, so the other clones stop repeating it (their CI status is
  still per branch and unaffected).

## v0.11.0 — 2026-08-03

### New
- A repo stopped mid-merge, mid-rebase, mid-cherry-pick, mid-revert or
  mid-bisect now says so — an orange suffix on the row and a line in the
  hover panel. Previously a rebase parked on a conflict looked like any
  other repo with a few changed files.
- Conflicted files are called out separately with a red ⚠ badge instead of
  being counted as ordinary modifications.
- Branches whose upstream is gone (the remote branch was deleted after a
  merge) get an "upstream gone" row in the hover panel with a delete
  button, so cleaning up after a merged pull request doesn't need a
  terminal. Confirmation required — it's a `-D`.
- Optional daily reminder: pick a time under Settings → General and get a
  notification if any repo is still holding uncommitted or unpushed work.
  Clicking it opens the popup. Off by default.
- Diverged branches can now be pulled from the menu bar. Settings → Remote
  has a pull strategy — fast-forward only (default), rebase, or merge — and
  when a fast-forward-only pull fails, the dialog offers a one-off rebase
  or merge instead of sending you to the command line.
- Opening the popup now refreshes remote-tracking refs for any repo not
  fetched in the last 15 minutes, so the list reflects the remote at the
  moment you look instead of whenever the background cadence last ran.
  Throttled per repo, and repos whose remote is failing keep their
  back-off instead of being retried on every open.
- Errors now leave a trail. Failures from git, the file watcher and GitHub
  polling are written to daily files in `~/Library/Logs/Uncommitted`
  (14-day retention, mirrored to `os.log`), with the most recent error and
  an export button in Settings → About. The app also installs exit,
  exception and signal handlers, so a process that disappears leaves
  something behind to look at — June's vanishing-icon incident left nothing.

### Improvements
- The age of pending work is always shown now; the toggle for it is gone.
  Nobody wants the version of this app that hides how long something has
  been sitting there.

### Bug fixes
- Auto-fetch no longer demotes actively-developed repos to the weekly
  cadence. The "active in the last 7 days" check read `.git/HEAD`, which
  only changes when you switch branches — so a repo you commit to daily
  without leaving the branch looked untouched and got fetched once a week.
  It now reads the HEAD reflog. Visible symptom: repos silently missing
  from the list because their remote-tracking refs were days stale and the
  app therefore believed they were up to date.
- Multi-digit badge counts no longer break across two lines on a crowded
  row. The pills stay atomic and the repo name truncates instead.

## v0.10.0 — 2026-06-29

### New
- A repo whose current branch is clean but whose *other* local branches have
  work to pull or push no longer hides itself. A clone parked on `develop`
  while local `main` quietly falls behind `origin/main` now stays visible with
  a muted arrow teaser — open the hover panel's "Other branches" section to
  fast-forward or push it.
- Deleted files now get their own red − section and badge instead of being
  lumped in with modified files.

### Bug fixes
- Removed the colored glow discs behind the app icon's ring nodes — they bled
  blue/purple/pink past the holes onto the white strokes.

## v0.9.0 — 2026-06-22

### New
- The hover panel now shows your *other* local branches, not just the one
  you're on. Living on `develop` while your local `main` quietly falls behind
  `origin/main`? It shows up as "main ↓3" under "Other branches" — click to
  fast-forward it, no checkout needed. Branches with unpushed commits get a
  push button; diverged branches are greyed out (nothing safe to do from the
  menu bar).
- The current branch's "commits to pull / push" lines in the panel are
  clickable now too — pull or push straight from the detail card, and the
  counts update in place.

### Bug fixes
- The pull section read "2 commit to pulls"; now "2 commits to pull".

## v0.8.0 — 2026-06-19

### New
- Every repo with pending work now shows how long it's gone untouched —
  a muted age ("11d", "now") next to the branch, spelled out in the hover
  panel ("Last change 3 days ago"). It counts from your most recent change,
  so a repo you're actively editing never looks abandoned. Toggle under
  Settings → General.
- Click any changed file in the hover panel to open it with your default
  action — no more digging through the repo to find the one you touched.

## v0.7.1 — 2026-05-16

### Bug fixes
- Opening the popover via the global shortcut no longer has a ~1s lag
  before the first keystroke registers. A status refresh ran
  synchronously on the main thread on every open and stalled keyboard
  input until it finished; it now runs in the background.
- Arrow keys / Return / Esc respond immediately on open instead of
  waiting for the search field to take focus.
- Keyboard-selecting a repo shows its detail panel instantly rather
  than after the mouse-hover delay.
- The popover no longer keeps a stale selection from the previous
  session, and never flashes an orphan detail panel after it closes.

## v0.7.0 — 2026-05-16

### Improvements
- Search field in the popover header, auto-focused when the popup
  opens. Matches across every repository by name and path — including
  the fully-committed ones the "hide clean repos" filter normally
  hides — so you can jump to any repo, not just the ones needing
  attention. (Replaces the old "Uncommitted" title.)
- Full keyboard flow: ⌘⇧U to open, type to filter, ↑/↓ to move the
  selection, ⏎ to run the default action on it. Esc clears the query,
  or closes the popup if it's already empty.
- Mouse and keyboard share one selection — hovering a row makes it the
  active row, so a following arrow press steps from there, and the
  hover detail panel follows the keyboard selection just as it does
  the mouse.
- One configured action can be tagged "git client" in Settings.
  Push/pull error alerts then offer "Open in <name>" as the default
  button, opening the failing repo in that client.

### Bug fixes
- Fixed the pointing-hand cursor sticking on the text I-beam when
  moving between clickable rows in the popover.
- "Fetch from remote", "Open remote in browser", and "Mute GitHub
  status" are now disabled instead of silent no-ops for repositories
  without a remote.

## v0.6.2 — 2026-04-30

### Improvements
- Popover now dismisses when you switch Mission Control desktops;
  previously it stayed pinned to the original desktop, so you needed
  two clicks to open it on the new one.

### Bug fixes
- Fixed a brief flash where the bottom row's subtitle was clipped when
  opening the popover during an in-flight status update.

## v0.6.1 — 2026-04-30

### Improvements
- First signed + notarized release. Apple Developer ID with hardened
  runtime + secure timestamp; first launch passes Gatekeeper without
  prompts.
- Universal binary (Apple Silicon + Intel).
- Click the "Last fetched X ago" line in the hover detail panel to
  force a refresh; a spinner runs in place while the fetch is in
  flight, and the text updates live when it finishes.
- Settings link in the popover footer is now a gear icon, matching the
  header chrome.

## v0.6.0 — skipped

First signed + notarized build, but Apple's notary service sat on the
submissions for over a day; the actual public release was v0.6.1.

## v0.5.0 — 2026-04

### Improvements
- New per-repo GitHub signals next to the local-state pills. PR pill
  (`⤴ N / N`) splits human-authored from bot PRs (the bot count is
  muted). CI surfaces only red (failed) and yellow (running) — green
  stays invisible by design.
- Menu-bar branch icon turns red whenever any tracked repo has failing
  CI, so a single glance tells you "is anything broken?" without
  opening the popover.
- Click the PR pill to open the GitHub PR list; click the CI badge to
  open Actions filtered to that branch.
- Right-click a repo row → "Open remote in browser" to jump to its
  GitHub page.
- Multi-clone-aware caching: if you have several local clones of the
  same repo, they share GitHub API calls automatically.

## v0.4.0 — 2026-04-11

First tagged public release. Daily-usable menu-bar app: configurable
actions, per-source scan depth, git-porcelain status badges, four-tab
Settings, Sparkle 2.x auto-updater built in, MIT licensed.
