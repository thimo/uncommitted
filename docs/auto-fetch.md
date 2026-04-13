# Auto-fetch from remotes

Spec for letting Uncommitted run periodic `git fetch` against tracked
repos so the unpulled count reflects what's on the remote, not just
what was last fetched manually.

Status: **proposed, not implemented.**

## Setting

A single new toggle in Settings → General → Refresh:

- **Fetch from remotes** — default **off**

No exposed cadence knobs in v1. Sensible defaults are hardcoded;
preferences come later only if real usage shows we need them.

## Cadence

Two tiers, classified per repo on every check:

| Tier | Definition | Fetch interval |
|---|---|---|
| **Active** | local or remote HEAD commit in the last 7 days | 24 hours |
| **Idle** | older than that | 7 days |
| **Disabled** | see [Failure handling](#failure-handling) | never (manual only) |

Tier is recomputed each cycle, so an idle repo that just got a commit
naturally promotes back to active.

## Scheduler

A `FetchScheduler` lives on `AppDelegate`, started when the toggle is on.

- Wakes via `Timer` every **5 minutes**.
- Each tick: walk `repoStore.repos`, pick those whose
  `lastFetchAttemptAt + interval < now` and aren't disabled, run up to
  **3 fetches in parallel**, queue the rest for the next tick.
- On app launch: wait **2 minutes** before the first tick — never
  hammer the network during startup.
- On `NSWorkspace.didWakeNotification`: re-arm the timer but stagger
  catch-up. Don't fire every overdue fetch immediately; let the normal
  cadence absorb them over the next few ticks.

## What we run

A new method on `GitService`:

```swift
static func fetch(at url: URL) -> ExecuteResult
```

Implementation: `git fetch --quiet --no-tags --prune origin`, going
through the existing pipe-drain + SIGKILL plumbing in
`GitService.execute`. After a successful fetch, the existing per-repo
status refresh runs immediately so the unpulled count updates without
waiting for the next status tick.

If the repo has multiple remotes, v1 fetches `origin` only.

## Failure handling

Persisted per repo:

- `lastFetchAttemptAt: Date?`
- `lastFetchSuccessAt: Date?`
- `consecutiveFetchFailures: Int`

Failure counts when `git fetch` exits non-zero, the pipe-drain times
out, or the process group has to be SIGKILLed.

Back-off ladder:

| Consecutive failures | Next attempt after |
|---|---|
| 1 | normal cycle (24h or 7d) |
| 2 | 2× normal interval |
| 3 | 4× |
| 4 | 8× |
| … | doubling each time, capped at 30 days |
| ≥ enough to exceed 30 days continuous failure | **disabled** |

A disabled repo never auto-fetches. A user-initiated fetch always runs
unconditionally and clears `consecutiveFetchFailures` on success.

## Failure visibility

Layered, so healthy repos stay quiet but real problems surface:

| State | Where it shows |
|---|---|
| Healthy | Hover detail panel shows `Last fetched: 3h ago` |
| 1–2 failures | Hover detail panel shows `Last fetch failed` + next retry time |
| 3+ failures | `exclamationmark.triangle` glyph next to the repo name in the row, tooltip explains |
| Disabled (≥30d failing) | Same glyph in a muted colour, tooltip: `Fetch disabled — Option-click refresh to retry` |
| Manual fetch failure | Row glyph appears immediately (threshold lowers to 1 when the most recent attempt was user-initiated) |

## Repos with no remote

`git remote` returns empty → mark `noRemote = true` on the repo, skip
forever, no UI indicator. Re-checked once per app launch (cheap), so
adding a remote later picks up automatically.

## Manual fetch

Two entry points:

- **Refresh button**, header circular arrow — **Option-click** → "Fetch
  & refresh", same path as auto-fetch but unconditional and parallel
  across all repos. While Option is held the icon swaps
  (`arrow.clockwise` → `arrow.triangle.2.circlepath`) and the tooltip
  changes to make the alternate behavior visible.
- **Per-row right-click menu** → "Fetch from remote", added to the
  existing `Action` infrastructure so it sits next to "Open with…".

The macOS convention is Option = "alternate, often more thorough
version of the same action" (Apple uses it for *About This Mac* →
*System Information*, *Close* → *Close All*, etc.). Refresh = read
local; Option-refresh = also talk to the network. That fits exactly.

**Manual fetch is always available, regardless of the "Fetch from
remotes" toggle.** The toggle only gates the background scheduler;
Option-click and the right-click action are useful one-shot operations
even for users who don't want background fetching. A user-initiated
fetch always clears `consecutiveFetchFailures` on success and runs
even from the per-repo disabled state.

## Storage

Three new fields on `Repo` (or a sibling per-repo state struct, TBD
during implementation):

```
var lastFetchAttemptAt: Date?
var lastFetchSuccessAt: Date?
var consecutiveFetchFailures: Int
```

Persisted alongside the existing repo state. Bookkeeping is per-repo,
not global.

## Out of scope for v1

- No badge or notification for fetch errors during the silent phase.
- No SSH agent prompt handling — if it hangs, the SIGKILL plumbing
  kills it, the failure counter ticks up.
- No user-configurable cadence.
- No "fetch immediately on app launch" — auto-fetch is timer-driven only.
- No fetching of non-`origin` remotes.
- No diagnostic log or settings panel listing failing repos. (Hover
  detail and the row glyph are the only failure surface.)
