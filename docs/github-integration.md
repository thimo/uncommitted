# GitHub status integration

Per-repo PR and CI signals in the menu bar popover, alongside the local
git state badges. Answers two questions Uncommitted couldn't before:

- "Is what I just pushed green?"
- "Is there anything queued (open PRs, dependabot) that needs cleanup?"

Status: **shipped in v0.5.**

## What you see

In the popover, each repo row gets up to two extra badges, rendered to
the **left** of the existing local-status pills:

| Badge | Meaning |
|---|---|
| `⚠️` (red shield) | CI is failing on the latest push to your current branch |
| `🕐` (yellow clock) | CI is running on the latest push |
| `⤴ 4 / 2` | 4 human-authored open PRs, 2 by bots (the `/ 2` is muted) |
| `⤴ 4` | only humans, no bots |
| `⤴ 2` (muted) | only bots, no humans |

Green CI is intentionally **invisible** — Uncommitted's job is to
surface what needs attention, not confirm what's working.

In the menu bar itself, the branch icon turns red whenever **any**
tracked repo has failing CI. The count number stays on
uncommitted+unpushed (pure local git state), so you get two bits of
info at a glance:

- The number = "do I need to commit/push?"
- The icon color = "is something stuck or broken on the remote?"

## Click behavior

- **Click the PR pill** → opens `https://github.com/<owner>/<repo>/pulls`
  in your browser.
- **Click the CI badge (red or yellow)** → opens the Actions tab,
  pre-filtered to the current branch.

## Prerequisites

GitHub access goes through the [`gh` CLI][gh] — Uncommitted shells out
to `gh api` instead of carrying its own credentials. You need:

1. **`gh` installed.** Easiest path: `brew install gh`.
2. **`gh auth login` completed.** Pick `github.com`, HTTPS, and authenticate
   in the browser. Uncommitted needs `repo` scope (the default `gh`
   scope set already includes this).

Verify with `gh auth status` — it should report you as logged in.

If `gh` isn't installed or hasn't been authenticated, the **Show GitHub
status** toggle in Settings → General disables itself and shows
instructions in the footer. The rest of Uncommitted keeps working.

[gh]: https://cli.github.com

## Refresh cadence

Tiered, internal — no slider in Settings. The defaults are tuned for
"recent push lands on a feature branch and CI runs in ~3 min":

| Tier | Definition | Refresh interval |
|---|---|---|
| **Active** | `.git/HEAD` touched within the last 24 hours | 15 minutes |
| **Idle** | older than that | 24 hours |

Plus two on-demand triggers:

- **Popover open** — every visible repo gets refreshed eagerly,
  bypassing the cadence. Means a freshly-opened popup is never showing
  old CI/PR data.
- **Manual refresh** (planned) — the existing refresh button
  Option-clicked.

There's no exponential back-off on failures. Most GitHub failures are
transient (rate limit, network blip) — we just retry on the next tick.
If `gh` outright isn't available, the scheduler stays inert.

## Caching and multi-clone repos

It's common to have several local clones of the same upstream (e.g.
four checkouts of `electrolyte` for parallel feature branches).
Uncommitted dedupes API calls so multiple clones don't multiply the
GitHub traffic:

- **PR count** is keyed by `owner/repo` — fetched **once** per slug,
  broadcast to every clone of that slug.
- **CI status** is keyed by `owner/repo + branch` — fetched once per
  unique (slug, branch) pair, broadcast to clones on the same branch.

So four clones of `sportcity-nl/electrolyte` on four different feature
branches collapse to **1 PR fetch + 4 CI fetches** per cycle, not 8.
Two clones on the same branch collapse the CI fetch too.

## Bot detection

A PR is classified as a bot when **any** of these match:

- `user.type == "Bot"` (GitHub's own flag — most reliable)
- Login ends in `[bot]` (the universal GitHub Apps suffix)
- Login is one of: `dependabot`, `renovate`, `renovate-bot`,
  `github-actions` (covers a few self-hosted flows that don't carry
  the suffix)

Anything else is treated as human.

## What we don't show (yet)

- Per-PR review status / comments — the badge only counts open PRs,
  not whether any need your attention specifically. Click through to
  GitHub for review state.
- Default-branch CI as a separate signal — we only show CI for your
  current branch. If you want to see whether `main` is healthy, switch
  to that branch (or open the Actions page directly).
- Notifications — there's no "ping when CI breaks" yet. v0.5 is
  visible-only. State-transition notifications are on the
  [roadmap](../ROADMAP.md).
