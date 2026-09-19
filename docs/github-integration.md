# GitHub status integration

Per-repo PR and CI signals in the menu bar popover, alongside the local
git state badges. Answers two questions Uncommitted couldn't before:

- "Is what I just pushed green?"
- "Is there anything queued (open PRs, dependabot) that needs cleanup?"

Status: **shipped in v0.5.**

## What you see

In the popover, each repo row gets up to three extra badges, rendered to
the **left** of the existing local-status pills:

| Badge | Meaning |
|---|---|
| `⚠️` (red shield) | CI is failing on the latest push to your current branch |
| `🕐` (yellow clock) | CI is running on the latest push |
| `⤴ 2 / 3` | 2 open PRs need you, 3 more are just open (the `/ 3` is muted) |
| `⤴ 3` (muted) | 3 open PRs, none need you |
| `⊙ 2 / 5` | 2 open issues need you, 5 are someone else's (the `/ 5` is muted) |
| `⊙ 5` (muted) | 5 open issues, none need you |

An issue **needs you** when it's assigned to you, or when it's assigned
to nobody on a repo you run (admin or maintainer) — there, nobody else
is going to pick it up. Anywhere else unassigned issues stay grey: a
clone of someone else's project, a team repo where you merely have
write access along with everyone else, an archived repo. Mute the repo
if even grey is too much.

The hover panel lists the PRs and issues behind those counts — whatever
needs you first — and each row opens on github.com.

Issues have their own switch: **Include open issues** in Settings →
Remote, under **Show GitHub status**. With it off, issues are left out
of the GitHub query entirely. The unassigned and ignored-label counts
are exact, straight from GitHub; "assigned to you" is judged from the
50 most recently updated open issues, so on a repo with more than that
an assigned issue nobody touched in a while counts as someone else's.

A configurable label — **Ignore issues labelled**, default `someday` —
marks issues that aren't worth surfacing: an icebox, an
intake/triage bucket, whatever your team parks low-priority work under.
A matching issue doesn't count in the badge, doesn't keep an otherwise
clean repo visible under "Hide repositories with no changes", and if
it's also assigned to you, ignored wins — it's excluded from `mine` too.
It still shows up in the hover panel's issue list, sorted to the bottom,
with its label name in the caption, so "why isn't this in the count" has
a visible answer instead of the issue just vanishing. The match is
case-insensitive and trims whitespace; clearing the field turns the
feature off and every open issue counts again.

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
- **Click the issue pill** → opens `https://github.com/<owner>/<repo>/issues`.
- **Click the CI badge (red or yellow)** → opens the Actions tab,
  pre-filtered to the current branch.

## Muting a single repo

Right-click a repo row and choose **Mute GitHub status** to hide the PR
and issue pills and CI badges for that repo only. A muted repo also stops
contributing to the red menu bar icon and, when "Hide repositories with
no changes" is on, no longer stays visible just because it has open PRs,
open issues or failing CI.

Nothing git-side changes: uncommitted files, unpushed commits, the
behind count, pull/push buttons and auto-fetch all keep working. The
scheduler still polls the repo (multi-clone caching makes this cheap);
only the rendering is suppressed.

The mute is per clone path, so two checkouts of the same repository are
muted separately. Muted repos are listed in Settings → Remote under
"Muted repositories" with an unmute button per row; the config key is
`gitHubMutedRepos`.

## Prerequisites

GitHub access goes through the [`gh` CLI][gh] — Uncommitted shells out
to `gh api` instead of carrying its own credentials. You need:

1. **`gh` installed.** Easiest path: `brew install gh`.
2. **`gh auth login` completed.** Pick `github.com`, HTTPS, and authenticate
   in the browser. Uncommitted needs `repo` scope (the default `gh`
   scope set already includes this).

Verify with `gh auth status` — it should report you as logged in.

If `gh` isn't installed or hasn't been authenticated, the **Show GitHub
status** toggle in Settings → Remote disables itself and shows
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

- **PRs and issues** are keyed by `owner/repo` — fetched **once** per
  slug, in a single GraphQL call, and shown on the first clone of that
  slug in your repo order only.
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

- Default-branch CI as a separate signal — we only show CI for your
  current branch. If you want to see whether `main` is healthy, switch
  to that branch (or open the Actions page directly).
- Notifications — there's no "ping when CI breaks" yet. v0.5 is
  visible-only. State-transition notifications are on the
  [ideas list](../IDEAS.md).
