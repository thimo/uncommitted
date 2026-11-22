# GitHub status integration

Per-repo PR and CI signals in the menu bar popover, alongside the local
git state badges. Answers two questions Uncommitted couldn't before:

- "Is what I just pushed green?"
- "Is there anything queued (open PRs, dependabot) that needs cleanup?"

Status: **shipped in v0.5.**

## What you see

In the popover, each repo row gets up to four extra badges, rendered to
the **left** of the existing local-status pills:

| Badge | Meaning |
|---|---|
| `⚠️` (red shield) | CI is failing on the latest push to your current branch |
| `🕐` (yellow clock) | CI is running on the latest push |
| `⤴ 2 / 3` | 2 open PRs need you, 3 more are just open (the `/ 3` is muted) |
| `⤴ 3` (muted) | 3 open PRs, none need you |
| `⊙ 2 / 5` | 2 open issues need you, 5 are someone else's (the `/ 5` is muted) |
| `⊙ 5` (muted) | 5 open issues, none need you |
| `📦 3` (brown) | 3 commits on the default branch are not deployed to production |

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

### Where the CI verdict comes from

Two sources, merged into one badge:

- **GitHub Actions workflow runs** on the branch — the latest run of
  each workflow. Cancelled runs and GitHub-managed runs (Dependabot
  updates, CodeQL default setup) don't count.
- **Commit statuses** on the branch head — what a local or third-party
  CI posts through the statuses API, for instance a `bin/ci` script that
  reports its own verdict.

Any failure (a failed run, or a status in `failure` or `error`) makes the
badge red; otherwise anything still running or `pending` makes it yellow.
The hover panel names what failed, workflow names first, then status
contexts. Check runs from GitHub Apps other than Actions are not read.

Statuses belong to one commit, so a push clears them until the CI
reports on the new head. When one of the two calls fails, the badge
keeps that branch's last answer rather than judging on half the picture.

### Undeployed commits

The deploy pill shows how far the repository's default branch is ahead
of production: the number of commits after the newest
[GitHub Deployment][deployments] for the environment `production` whose
latest status is `success`. A newer deployment that failed or is still
in progress doesn't move that point. The pill is hidden at zero, and a
repo without such a deployment never shows it.

The records can come from anything that writes GitHub Deployments —
GitHub Actions environments, or a deploy tool's hook calling the API
(a Kamal `post-deploy` hook, say). The environment name has to be
exactly `production`, and only the 20 most recent records are read.

Like PRs and issues, the pill belongs to the remote: it shows on the
first clone of a repo only, and a repo with undeployed commits stays
visible under "Hide repositories with no changes".

A repo that has a `config/deploy.yml` also gets a "Deploy with Kamal" entry
in its right-click menu. It runs `bin/kamal deploy` (or `kamal deploy` when
the repo has no binstub) in a terminal in the repo, so the deploy can
ask for a 1Password login. In Ghostty that is a background tab of the front
window, titled `deploy: <repo>`; it closes itself after a successful deploy
and stays open after a failed one. The terminal is Ghostty or Terminal, whichever
comes first among the configured actions, and Terminal when neither is
configured. Kamal ships the local HEAD, so the entry is disabled, with the
reason in its title, while the working tree has uncommitted changes, a git
operation is in progress, HEAD is detached, or the checkout is not on the
default branch. For Ghostty, macOS asks once for permission to control it.

[deployments]: https://docs.github.com/en/rest/deployments/deployments

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
  pre-filtered to the current branch. A failing commit status has no
  page there; the hover panel names it.
- **Click the deploy pill** → opens the comparison
  `compare/<deployed sha>...<default branch>`: the undeployed commits.

## Muting a single repo

Right-click a repo row and choose **Mute GitHub status** to hide the PR,
issue and deploy pills and CI badges for that repo only. A muted repo also
stops contributing to the red menu bar icon and, when "Hide repositories
with no changes" is on, no longer stays visible just because it has open
PRs, open issues, undeployed commits or failing CI.

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

- **Popover open** — every repo whose GitHub data is older than five
  minutes gets refreshed, bypassing the cadence. A repo with pending or
  failing CI is refreshed when its data is older than one minute, and a
  repo with a commit, push or checkout since its last refresh always.
- **Refresh button** — refreshes every repo, whatever its age.

A full refresh costs about six GraphQL points per repository, out of the
5000 an account gets per hour and shares with every other `gh` user on
the machine. Hence the five minutes: without them, opening the popup
often enough spent the whole budget.

There's no exponential back-off on failures. Most GitHub failures are
transient — we just retry on the next tick. The rate limit is the
exception: at the first refused call the refresh stops, and no further
calls go out for five minutes. The badges keep their last answer
meanwhile, and whatever was skipped — the Refresh button included — is
fetched once the pause is over. If `gh` outright isn't available, the scheduler stays inert.

## Caching and multi-clone repos

It's common to have several local clones of the same upstream (e.g.
four checkouts of `electrolyte` for parallel feature branches).
Uncommitted dedupes API calls so multiple clones don't multiply the
GitHub traffic:

- **PRs and issues** are keyed by `owner/repo` — fetched **once** per
  slug, in a single GraphQL call, and shown on the first clone of that
  slug in your repo order only.
- **Undeployed commits** are keyed by `owner/repo` too — one GraphQL
  call per slug, plus one compare call when production is behind.
- **CI status** is keyed by `owner/repo + branch` — fetched once per
  unique (slug, branch) pair (one call for the workflow runs, one for
  the commit statuses), broadcast to clones on the same branch.

So four clones of `sportcity-nl/electrolyte` on four different feature
branches share the PR and deployment fetches and do four CI fetches per
cycle; two clones on the same branch collapse the CI fetch too.

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
