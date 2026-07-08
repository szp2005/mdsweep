#!/usr/bin/env bash
# Smoke test: builds a throwaway fixture repo, then exercises
# scan -> quarantine (dry-run) -> quarantine --apply -> undo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/mdsweep.mjs"
SANDBOX="$ROOT/test/fixtures/sandbox"
REPO="$SANDBOX/repo"
OLD_STAMP="202601010000"   # mtime backdate: 2026-01-01
OLD_DATE="2026-01-01T00:00:00"

pass() { echo "ok - $1"; }
die()  { echo "FAIL: $1" >&2; exit 1; }

# ---------------------------------------------------------------- fixture

rm -rf "$SANDBOX"
mkdir -p "$REPO/src" "$REPO/docs"
cd "$REPO"
git init -q -b main
git config user.email "smoke@example.com"
git config user.name "Smoke Test"
git config commit.gpgsign false

cat > README.md <<'EOF'
# Fixture project
A fake repo for mdsweep's smoke test.
EOF
cat > CLAUDE.md <<'EOF'
# Project instructions
Auth work is tracked in PLAN_login.md — keep it in sync.
EOF
echo 'console.log("hello");' > src/app.js
echo '# User guide' > guide.md
git add -A
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" git commit -qm 'initial project'

printf '# Session summary\nDid some things.\n' > SUMMARY.md
git add SUMMARY.md
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
  git commit -qm $'add session summary\n\nCo-Authored-By: Claude <noreply@anthropic.com>'

printf '# Login plan\nSteps for auth.\n' > PLAN_login.md
git add PLAN_login.md
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
  git commit -qm $'draft login plan\n\nCo-Authored-By: Claude <noreply@anthropic.com>'

# Flagged only via frontmatter (name matches nothing, human commit).
printf -- '---\ngenerated_by: claude-code\n---\nOld design notes.\n' > docs/generated.md
git add docs/generated.md
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" git commit -qm 'add design notes'

# Untracked artifacts: one old (orphan), one fresh (active).
printf '# Findings\nStale scratch output.\n' > FINDINGS.md
printf '# Notes\nFresh scratch output.\n' > NOTES.md

# Backdate mtimes of everything except NOTES.md.
touch -m -t "$OLD_STAMP" README.md CLAUDE.md guide.md src/app.js \
  SUMMARY.md PLAN_login.md docs/generated.md FINDINGS.md

# ------------------------------------------------------------------- scan

node "$CLI" scan "$REPO" --json > "$SANDBOX/scan.json"
SCAN="$SANDBOX/scan.json" node --input-type=module - <<'EOF'
import fs from 'node:fs';
const d = JSON.parse(fs.readFileSync(process.env.SCAN, 'utf8'));
const by = Object.fromEntries(d.files.map((f) => [f.path, f]));
const ok = (cond, msg) => {
  if (!cond) { console.error(`FAIL: ${msg}`); process.exit(1); }
  console.log(`ok - ${msg}`);
};
ok(d.git === true, 'fixture recognized as git repo');
ok(by['SUMMARY.md']?.grade === 'orphan', 'SUMMARY.md graded orphan');
ok(by['SUMMARY.md'].signals.includes('git:claude-coauthor'), 'SUMMARY.md has claude-coauthor signal');
ok(by['PLAN_login.md']?.grade === 'stale', 'PLAN_login.md graded stale (referenced by CLAUDE.md)');
ok(by['PLAN_login.md'].refs >= 1, 'PLAN_login.md has inbound refs');
ok(by['NOTES.md']?.grade === 'active', 'NOTES.md graded active (fresh mtime)');
ok(by['FINDINGS.md']?.grade === 'orphan', 'FINDINGS.md graded orphan');
ok(by['FINDINGS.md'].signals.includes('git:untracked'), 'FINDINGS.md has untracked signal');
ok(by['docs/generated.md']?.grade === 'orphan', 'docs/generated.md graded orphan');
ok(by['docs/generated.md'].signals.includes('frontmatter'), 'docs/generated.md flagged via frontmatter only');
ok(!by['guide.md'], 'plain human file not flagged');
ok(!by['README.md'] && !by['CLAUDE.md'], 'protected files not flagged');
ok(d.summary.orphan === 3 && d.summary.stale === 1 && d.summary.active === 1, 'summary counts: 3 orphan / 1 stale / 1 active');
EOF

# --------------------------------------------------- quarantine (dry-run)

node "$CLI" quarantine "$REPO" > "$SANDBOX/dry.txt"
grep -q 'DRY RUN' "$SANDBOX/dry.txt" || die 'dry-run banner missing'
[ -f "$REPO/SUMMARY.md" ] || die 'dry-run must not move files'
[ ! -d "$REPO/.mdsweep" ] || die 'dry-run must not create .mdsweep'
pass 'quarantine defaults to dry-run'

# --------------------------------------------------- quarantine --apply

( cd "$REPO" && shasum SUMMARY.md FINDINGS.md docs/generated.md > "$SANDBOX/sums.txt" )
node "$CLI" quarantine "$REPO" --apply > "$SANDBOX/apply.txt"

[ ! -f "$REPO/SUMMARY.md" ] || die 'SUMMARY.md should be quarantined'
[ ! -f "$REPO/FINDINGS.md" ] || die 'FINDINGS.md should be quarantined'
[ ! -f "$REPO/docs/generated.md" ] || die 'docs/generated.md should be quarantined'
[ -f "$REPO/PLAN_login.md" ] || die 'stale file must never be touched'
[ -f "$REPO/NOTES.md" ] || die 'active file must never be touched'

BATCH="$(echo "$REPO/.mdsweep/trash/"*)"
[ -f "$BATCH/SUMMARY.md" ] || die 'SUMMARY.md missing from trash'
[ -f "$BATCH/docs/generated.md" ] || die 'relative path not preserved in trash'
[ -f "$BATCH/manifest.json" ] || die 'manifest.json missing'
MANIFEST="$BATCH/manifest.json" node --input-type=module - <<'EOF'
import fs from 'node:fs';
const m = JSON.parse(fs.readFileSync(process.env.MANIFEST, 'utf8'));
const paths = m.files.map((f) => f.path).sort();
const want = ['FINDINGS.md', 'SUMMARY.md', 'docs/generated.md'];
if (JSON.stringify(paths) !== JSON.stringify(want)) {
  console.error(`FAIL: manifest lists ${JSON.stringify(paths)}, want ${JSON.stringify(want)}`);
  process.exit(1);
}
console.log('ok - manifest lists exactly the 3 orphans');
EOF
pass 'quarantine --apply moved only orphans'

# ------------------------------------------------------------------- undo

node "$CLI" undo "$REPO" > "$SANDBOX/undo.txt"
( cd "$REPO" && shasum -c "$SANDBOX/sums.txt" > /dev/null ) || die 'restored files differ from originals'
FOUND_MANIFESTS="$(find "$REPO/.mdsweep" -name manifest.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$FOUND_MANIFESTS" = "0" ] || die 'manifest should be consumed after full undo'
pass 'undo restored all files byte-identical'

# -------------------------------------------- non-git dir + docs exclusion

# Outside the sandbox: the sandbox may live inside a git checkout of
# mdsweep itself, and this test needs a genuinely git-free directory.
PLAINTMP="$(mktemp -d)"
trap 'rm -rf "$PLAINTMP"' EXIT
PLAIN="$PLAINTMP/plain"
mkdir -p "$PLAIN/docs" "$PLAIN/content"
printf '# Status\nold status dump\n' > "$PLAIN/STATUS.md"
printf '# API\nreal docs\n' > "$PLAIN/docs/api.md"
printf -- '---\nauthor: claude\n---\npublished post\n' > "$PLAIN/content/post.md"
touch "$PLAIN/mkdocs.yml" "$PLAIN/astro.config.mjs"
touch -m -t "$OLD_STAMP" "$PLAIN/STATUS.md" "$PLAIN/docs/api.md" "$PLAIN/content/post.md"
node "$CLI" scan "$PLAIN" --json 2> "$SANDBOX/plain-warn.txt" > "$SANDBOX/plain.json"
grep -q 'not a git repository' "$SANDBOX/plain-warn.txt" || die 'non-git warning missing'
PLAIN_JSON="$SANDBOX/plain.json" node --input-type=module - <<'EOF'
import fs from 'node:fs';
const d = JSON.parse(fs.readFileSync(process.env.PLAIN_JSON, 'utf8'));
const paths = d.files.map((f) => f.path);
const ok = (cond, msg) => {
  if (!cond) { console.error(`FAIL: ${msg}`); process.exit(1); }
  console.log(`ok - ${msg}`);
};
ok(paths.includes('STATUS.md'), 'non-git: STATUS.md flagged by name');
ok(d.files.find((f) => f.path === 'STATUS.md').grade === 'orphan', 'non-git: STATUS.md orphan by mtime');
ok(!paths.includes('docs/api.md'), 'docs/ excluded when mkdocs.yml present');
ok(!paths.includes('content/post.md'), 'content/ excluded when astro config present');
EOF

# ------------------------------------------------------------ error paths

if node "$CLI" scan /definitely/not/a/real/path 2> "$SANDBOX/err.txt"; then
  die 'scan of missing path should exit non-zero'
fi
grep -q 'path not found' "$SANDBOX/err.txt" || die 'friendly missing-path error expected'
pass 'missing path fails with friendly error'

echo ''
echo 'ALL SMOKE TESTS PASSED'
