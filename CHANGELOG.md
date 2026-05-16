# Changelog

User-facing notes for each release. Bullets are curated — not a 1:1
mapping of commits.

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
