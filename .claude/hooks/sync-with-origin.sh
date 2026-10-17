#!/bin/bash
# Cloud sessions can start from a cached clone that is days old. Fetch origin and fast-forward
# the checked-out branch to GitHub's state. No-op with local changes, a detached HEAD, a branch
# without upstream or when GitHub can't be reached; never fails the session start.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

timeout 60 git fetch --quiet origin 2>/dev/null || exit 0

branch=$(git symbolic-ref --quiet --short HEAD) || exit 0
git rev-parse --verify --quiet "origin/$branch" >/dev/null || exit 0
[ -z "$(git status --porcelain --untracked-files=no)" ] || exit 0

before=$(git rev-parse --short HEAD)
git merge --ff-only --quiet "origin/$branch" >/dev/null 2>&1 || exit 0
after=$(git rev-parse --short HEAD)
[ "$before" = "$after" ] || echo "Synced $branch with GitHub: $before → $after."
exit 0
