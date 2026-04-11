#!/bin/bash
# Create ~/tmp/uncommitted-demo/ with git repos in every status-badge state.
# Use this to take README screenshots without exposing real project names.
# Pair with teardown-screenshots.sh to clean up afterwards.
#
# After running, add ~/tmp/uncommitted-demo/ as a source in
# Uncommitted → Settings → Repositories (scan depth 1). The paired bare
# upstreams live in a hidden .upstream/ subdir that gets skipped by the scan.

set -euo pipefail

DEMO="$HOME/tmp/uncommitted-demo"
UPSTREAM="$DEMO/.upstream"

echo "==> Preparing clean demo directory at $DEMO"
if [ -d "$DEMO" ]; then
    if command -v trash >/dev/null 2>&1; then
        trash "$DEMO"
    else
        rm -rf "$DEMO"
    fi
fi
mkdir -p "$UPSTREAM"

# --- helpers ----------------------------------------------------------------

git_id() {
    git config user.email "demo@uncommitted.local"
    git config user.name "Uncommitted Demo"
}

init_repo() {
    # Initialize a working repo with one README commit and a paired bare
    # upstream that it tracks as origin/main.
    local name="$1"
    local dir="$DEMO/$name"
    local bare="$UPSTREAM/$name.git"

    git init -q -b main "$dir"
    (
        cd "$dir"
        git_id
        echo "# $name" > README.md
        git add README.md
        git commit -q -m "Initial commit"
    )

    git init -q --bare "$bare"
    (
        cd "$dir"
        git remote add origin "$bare"
        git push -q -u origin main
    )
}

commit_to_upstream() {
    # Clone the bare upstream into a temp dir, add one commit per message,
    # push, drop the temp clone, then fetch in the working repo so branch.ab
    # reflects the new upstream state.
    local name="$1"
    shift

    local bare="$UPSTREAM/$name.git"
    local tmp
    tmp=$(mktemp -d)
    git clone -q "$bare" "$tmp/clone"
    (
        cd "$tmp/clone"
        git_id
        local i=0
        for msg in "$@"; do
            i=$((i + 1))
            echo "upstream change $i" > "_upstream_$i.txt"
            git add "_upstream_$i.txt"
            git commit -q -m "$msg"
        done
        git push -q
    )
    rm -rf "$tmp"

    (
        cd "$DEMO/$name"
        git fetch -q
    )
}

# --- repositories -----------------------------------------------------------

echo "==> 1/7 acme-web — clean"
init_repo "acme-web"

echo "==> 2/7 acme-api — 3 untracked files (★3)"
init_repo "acme-api"
(
    cd "$DEMO/acme-api"
    touch routes.ts models.ts middleware.ts
)

echo "==> 3/7 acme-infra — 2 staged files (A2)"
init_repo "acme-infra"
(
    cd "$DEMO/acme-infra"
    echo 'terraform {}' > main.tf
    echo 'variable "region" {}' > variables.tf
    git add main.tf variables.tf
)

echo "==> 4/7 payments — 5 modified unstaged files (M5)"
init_repo "payments"
(
    cd "$DEMO/payments"
    for f in charge refund webhook invoice customer; do
        echo "class $f" > "$f.rb"
    done
    git add .
    git commit -q -m "Add payment primitives"
    git push -q

    for f in charge refund webhook invoice customer; do
        echo "# TODO" >> "$f.rb"
    done
)

echo "==> 5/7 internal-tools — 5 commits ahead of upstream (↑5)"
init_repo "internal-tools"
(
    cd "$DEMO/internal-tools"
    for i in 1 2 3 4 5; do
        echo "tool $i" > "tool-$i.sh"
        git add "tool-$i.sh"
        git commit -q -m "Add internal tool $i"
    done
    # Intentionally NOT pushed — these stay ahead.
)

echo "==> 6/7 design-system — 4 commits behind upstream (↓4)"
init_repo "design-system"
commit_to_upstream "design-system" \
    "Add Button component" \
    "Add Card component" \
    "Add Input component" \
    "Add Modal component"

echo "==> 7/7 checkout — kitchen sink (↑2 ↓1 ★3 M2 A1)"
init_repo "checkout"
(
    cd "$DEMO/checkout"
    for f in cart session order tax; do
        echo "class $f" > "$f.rb"
    done
    git add .
    git commit -q -m "Add checkout primitives"
    git push -q
)
commit_to_upstream "checkout" "Add coupon support"
(
    cd "$DEMO/checkout"

    # ↑2 — two local commits on top of the shared base
    echo "refactor" > refactor1.rb
    git add refactor1.rb
    git commit -q -m "Refactor cart logic"
    echo "more refactor" > refactor2.rb
    git add refactor2.rb
    git commit -q -m "Refactor session logic"

    # ★3 — three untracked files
    touch new1.rb new2.rb new3.rb

    # M2 — two modified unstaged files
    echo "# TODO" >> cart.rb
    echo "# TODO" >> session.rb

    # A1 — one staged file
    echo "# reviewed" >> tax.rb
    git add tax.rb
)

echo
echo "Done. 7 demo repositories at: $DEMO"
echo
echo "Next:"
echo "  1. Uncommitted → Settings → Repositories → add $DEMO (scan depth 1)"
echo "  2. Take your screenshots"
echo "  3. Run scripts/teardown-screenshots.sh to clean up"
