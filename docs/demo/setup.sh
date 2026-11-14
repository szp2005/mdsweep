#!/bin/sh
# Rebuild docs/demo/fixture as its own git repo so the demo grades files
# the same way every time. NOTES.md stays untracked on purpose.
set -eu
cd "$(dirname "$0")/fixture"
rm -rf .git .mdsweep

git init -q -b main
git config user.email "demo@example.com"
git config user.name "Demo"
git config commit.gpgsign false

OLD_ROOT="2026-08-01T00:00:00"
OLD_ARTIFACTS="2026-08-02T00:00:00"

git add README.md CLAUDE.md
GIT_AUTHOR_DATE="$OLD_ROOT" GIT_COMMITTER_DATE="$OLD_ROOT" \
  git commit -qm "initial project"

git add SUMMARY.md PLAN_auth.md CHECKLIST.md
GIT_AUTHOR_DATE="$OLD_ARTIFACTS" GIT_COMMITTER_DATE="$OLD_ARTIFACTS" \
  git commit -qm "$(printf '%s\n\n%s\n' 'add session artifacts' 'Co-Authored-By: Claude <noreply@anthropic.com>')"

git add HANDOFF.md
git commit -qm "add handoff note"

# Grade uses the later of mtime and last commit. Commit dates alone leave
# the working tree looking new, so the two old artifacts are backdated here.
touch -m -d "$OLD_ARTIFACTS" SUMMARY.md PLAN_auth.md CHECKLIST.md
