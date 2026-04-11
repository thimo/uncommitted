# Uncommitted

A native macOS menubar app that tracks uncommitted and unpushed changes across
your git repositories. SwiftUI + AppKit, no polling, no dependencies.

![menu bar label showing icon plus counts](./docs/menubar.png)

## What it does

At-a-glance status for every repo you care about:

- Live file-system watcher (FSEvents) — no polling, no refresh button needed
- Uncommitted file counts broken down by category (untracked / modified / staged)
- Unpushed and unpulled commit counts per repo
- Click a row to open in your preferred app (VS Code, Tower, Terminal, Finder,
  or any custom shell command)
- Right-click a row for the full action list
- "Hide repositories with no changes" toggle so you only see what needs attention

## Menu bar label

Shows a branch icon followed by the totals across every tracked repo:

| Example | Meaning |
|---|---|
| `⎇` | everything's clean |
| `⎇ 20` | 20 uncommitted files across all repos |
| `⎇ ↑7` | 7 commits ahead of upstream, nothing uncommitted |
| `⎇ 20 ↑7` | both |

## Status badges

Each repo row uses the same glyphs as git's porcelain output
(`git status --porcelain=v2`) so there's nothing new to learn:

| Badge | Meaning | Color |
|---|---|---|
| `↑ N` | N commits ahead of upstream | blue |
| `↓ N` | N commits behind upstream | purple |
| `★ N` | N untracked (new) files | green |
| `M N` | N modified (unstaged) files | orange |
| `A N` | N staged files | teal |
| `✓` | clean | green |

## Requirements

- macOS 14 (Sonoma) or later
- `git` in `/usr/bin/git` (Apple's `/usr/bin/git` shim, or Xcode Command Line
  Tools)

## Building from source

No Xcode project — just SwiftPM and a shell script.

```bash
git clone https://github.com/thimo/uncommitted.git
cd uncommitted
./build.sh
open ~/Applications/Uncommitted.app
```

`build.sh` does the whole bundle: `swift build -c release`, renders the app
icon programmatically via `Resources/make-icon.swift`, wraps the binary in a
proper `.app` with `Info.plist`, ad-hoc codesigns, quits any running instance,
and installs to `~/Applications/Uncommitted.app`.

The app is `LSUIElement`, so there's no Dock icon — look for it in the menu
bar.

## Usage

### Repositories (Cmd+, → Repositories)

Add *source folders* with the **+** button. A source folder is any directory:

- If it contains a `.git`, it's treated as a single repository
- Otherwise, it's scanned N levels deep for child `.git` directories

Depth is configurable per source (0–5). Scanning stops at each repo found, so
submodules and nested checkouts aren't treated as separate repos.

### Actions (Cmd+, → Actions)

Configure what happens when you click a repo row in the popover. Default list
is Finder + VS Code + Terminal; add more with the **+** menu:

- **Add Application…** — native file picker filtered to `.app` bundles; icon
  pulled from the bundle (also works for Setapp-installed apps)
- **Add Custom Command…** — zsh command template, use `{path}` as the repo
  path placeholder (e.g. `open -a Ghostty {path}`)

The **top** action runs on left-click. Right-click the repo row in the menu
bar popover to pick any of the others. Drag to reorder.

### General (Cmd+, → General)

- **Hide repositories with no changes** — only show repos that need attention
- **Launch Uncommitted at login** — via `SMAppService`

### Config file

Settings persist to `~/Library/Application Support/Uncommitted/config.json`
with atomic writes, debounced 300ms. Safe to edit by hand if you really want
to.

## Architecture

- Swift Package, single executable target, no Xcode project required
- SwiftUI views throughout: popover content, Settings scene, all tabs
- AppKit `NSStatusItem` + `NSPopover` hosted via `NSHostingController` — we
  tried SwiftUI's `MenuBarExtra` but it offers no way to dismiss its popover
  programmatically
- `FSEvents` watcher per resolved repo with configurable scan depth — no
  polling; the only background work is `git status --porcelain=v2 --branch`
  triggered by file changes, run on a serial utility queue so nothing blocks
  the main thread
- A failed or suspect `git status` parse never clobbers a known-good status,
  which keeps the UI stable when git is mid-operation (fetch, push, etc.)
- Popover is `.transient`, so it auto-closes on focus loss (e.g. when your
  editor takes focus after a click)

## Why not SwiftBar / Barmaid / AnyBar?

Those are all great tools, but I wanted:

- A real native Settings window with proper preferences, not a JSON file
- Live updates via FSEvents instead of a 5-minute polling interval
- Custom per-repo actions with icons pulled from the actual apps
- An excuse to learn SwiftUI on macOS properly

First "beautiful Mac app" project for me. Code is deliberately readable — if
you want to crib patterns for your own menu bar app, start at
`Sources/Uncommitted/AppDelegate.swift`.

## License

MIT — see [LICENSE](./LICENSE).

## Credits

Built collaboratively with [Claude Code](https://claude.com/claude-code)
(Claude Opus 4.6, 1M context). Every commit on the history carries a
co-authored-by line. Fully written from scratch on 2026-04-11.
