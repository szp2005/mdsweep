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
for (const f of m.files) {
  if (f.refs !== 0) {
    console.error(`FAIL: ${f.path} records refs ${f.refs}, want 0 (an orphan has no inbound reference)`);
    process.exit(1);
  }
  if (!Array.isArray(f.signals) || typeof f.ageDays !== 'number') {
    console.error(`FAIL: ${f.path} is missing the signals/ageDays that explain why it moved`);
    process.exit(1);
  }
}
console.log('ok - each entry records why it moved (refs, ageDays, signals)');
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

node "$CLI" --help > "$SANDBOX/help.txt"
grep -q 'mdsweep archive' "$SANDBOX/help.txt" || die 'help should document archive'
pass 'help documents archive'

# ------------------------------------------------------------------- archive
# Separate repo so the quarantine cases above stay a pure before/after.

ARCH="$SANDBOX/archive-repo"
mkdir -p "$ARCH/docs"
cd "$ARCH"
git init -q -b main
git config user.email "smoke@example.com"
git config user.name "Smoke Test"
git config commit.gpgsign false

cat > README.md <<'EOF'
---
status: done
generated_by: claude-code
---
# Fixture project
Human readme. Must never be archived.
EOF
cat > CLAUDE.md <<'EOF'
# Project instructions
Keep human docs in the README.
EOF
# Status alone is not an agent signal: tracked, plain name, human commit.
cat > finished.md <<'EOF'
---
status: done
---
# Finished
Status without an agent signal is not an artifact.
EOF
printf -- '---\nstatus: done\n---\n# Handoff\nOld completed handoff. Unreferenced.\n' > docs/HANDOFF.md
printf -- '---\nstatus: "completed"\n---\n# Scratch\nQuoted completed status.\n' > SCRATCH.md
printf -- '---\nstatus: archived\n---\n# Analysis\nArchived status value.\n' > ANALYSIS.md
printf -- '---\nstatus: Closed\n---\n# Debug\nClosed, any case.\n' > DEBUG_session.md
printf -- '---\nstatus: in-progress\n---\n# Final notes\nNot a completed status.\n' > FINAL_notes.md
printf '# Findings\nOrphan with no status tag.\n' > FINDINGS.md
printf '# Status\nEverything is done.\nstatus: done\n' > STATUS.md
printf '# Report\n\nThis work is done.\nSomeone wrote status: done in the body.\n' > REPORT_done.md
printf -- '---\nstatus: done\n---\n# Draft\nFresh completed draft.\n' > DRAFT_fresh.md

git add README.md CLAUDE.md finished.md docs/HANDOFF.md SCRATCH.md ANALYSIS.md \
  DEBUG_session.md FINAL_notes.md
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" git commit -qm 'old project files'

# Untracked on purpose (that signal flags them). DRAFT_fresh stays new.
touch -m -t "$OLD_STAMP" README.md CLAUDE.md finished.md docs/HANDOFF.md \
  SCRATCH.md ANALYSIS.md DEBUG_session.md FINAL_notes.md \
  FINDINGS.md STATUS.md REPORT_done.md

# (e) a wide active window writes nothing, then a normal dry-run writes nothing.
node "$CLI" archive "$ARCH" --days 100000 > "$SANDBOX/archive-days.txt"
[ -f "$ARCH/docs/HANDOFF.md" ] || die 'wide --days must not move files'
[ ! -d "$ARCH/.mdsweep" ] || die 'wide --days must not create .mdsweep'
grep -q 'Nothing to archive' "$SANDBOX/archive-days.txt" || die 'wide --days should archive nothing'
pass 'archive --days leaves files inside the active window'

node "$CLI" archive "$ARCH" > "$SANDBOX/archive-dry.txt"
grep -q 'DRY RUN' "$SANDBOX/archive-dry.txt" || die 'archive dry-run banner missing'
grep -q 'docs/HANDOFF.md' "$SANDBOX/archive-dry.txt" || die 'dry-run should list the completed file'
[ -f "$ARCH/docs/HANDOFF.md" ] || die 'archive dry-run must not move files'
[ -f "$ARCH/FINDINGS.md" ] || die 'archive dry-run must not move a status-less orphan'
[ -f "$ARCH/README.md" ] || die 'archive dry-run must not move a protected file'
[ ! -d "$ARCH/.mdsweep" ] || die 'archive without --apply must not create .mdsweep'
pass 'archive defaults to dry-run and creates no .mdsweep'

node "$CLI" scan "$ARCH" --json > "$SANDBOX/archive-scan.json"
ARCHIVE_SCAN="$SANDBOX/archive-scan.json" node --input-type=module - <<'EOF'
import fs from 'node:fs';
const d = JSON.parse(fs.readFileSync(process.env.ARCHIVE_SCAN, 'utf8'));
const by = Object.fromEntries(d.files.map((f) => [f.path, f]));
const ok = (cond, msg) => {
  if (!cond) { console.error(`FAIL: ${msg}`); process.exit(1); }
  console.log(`ok - ${msg}`);
};
ok(by['docs/HANDOFF.md']?.grade === 'orphan', 'completed HANDOFF graded orphan when unreferenced');
ok(!by['docs/HANDOFF.md'].signals.some((s) => s === 'status' || s.startsWith('status:')), 'status is not a detection signal');
ok(!by['README.md'] && !by['CLAUDE.md'], 'protected files stay unflagged with status: done');
ok(!by['finished.md'], 'status alone does not flag a tracked file');
ok(by['FINDINGS.md']?.grade === 'orphan', 'status-less FINDINGS stays an orphan');
ok(by['STATUS.md']?.grade === 'orphan', 'STATUS filename is not a completed tag');
ok(by['REPORT_done.md']?.grade === 'orphan', 'body text "done" is not a completed tag');
ok(by['FINAL_notes.md']?.grade === 'orphan', 'status: in-progress is not completed');
ok(by['DRAFT_fresh.md']?.grade === 'active', 'fresh completed draft stays active');
ok(by['SCRATCH.md']?.grade === 'orphan', 'quoted completed status still flagged by name');
EOF

( cd "$ARCH" && shasum README.md docs/HANDOFF.md SCRATCH.md ANALYSIS.md DEBUG_session.md \
  FINDINGS.md STATUS.md REPORT_done.md FINAL_notes.md finished.md DRAFT_fresh.md \
  > "$SANDBOX/archive-sums.txt" )

# (a) --apply moves the unreferenced completed file; (d) protected stays;
# (c) the status-less orphan stays.
node "$CLI" archive "$ARCH" --apply > "$SANDBOX/archive-apply.txt"
[ ! -f "$ARCH/docs/HANDOFF.md" ] || die 'unreferenced status: done file should be archived'
[ ! -f "$ARCH/SCRATCH.md" ] || die 'status: completed should be archived'
[ ! -f "$ARCH/ANALYSIS.md" ] || die 'status: archived should be archived'
[ ! -f "$ARCH/DEBUG_session.md" ] || die 'status: Closed should be archived'
[ -f "$ARCH/FINDINGS.md" ] || die 'orphan with no status tag must not be archived'
[ -f "$ARCH/STATUS.md" ] || die 'STATUS filename must not be archived'
[ -f "$ARCH/REPORT_done.md" ] || die 'body text done must not be archived'
[ -f "$ARCH/FINAL_notes.md" ] || die 'status: in-progress must not be archived'
[ -f "$ARCH/README.md" ] || die 'protected file with status: done must not be archived'
[ -f "$ARCH/finished.md" ] || die 'status without an agent signal must not be archived'
[ -f "$ARCH/DRAFT_fresh.md" ] || die 'fresh completed file must not be archived'
[ -f "$ARCH/CLAUDE.md" ] || die 'CLAUDE.md must not be archived'

ARCH_BATCH="$(find "$ARCH/.mdsweep/archive" -mindepth 1 -maxdepth 1 -type d)"
[ -f "$ARCH_BATCH/docs/HANDOFF.md" ] || die 'relative path not preserved in archive'
[ -f "$ARCH_BATCH/manifest.json" ] || die 'archive manifest.json missing'
MANIFEST="$ARCH_BATCH/manifest.json" node --input-type=module - <<'EOF'
import fs from 'node:fs';
const m = JSON.parse(fs.readFileSync(process.env.MANIFEST, 'utf8'));
const by = Object.fromEntries(m.files.map((f) => [f.path, f]));
const paths = Object.keys(by).sort();
const want = ['ANALYSIS.md', 'DEBUG_session.md', 'SCRATCH.md', 'docs/HANDOFF.md'];
const ok = (cond, msg) => {
  if (!cond) { console.error(`FAIL: ${msg}`); process.exit(1); }
  console.log(`ok - ${msg}`);
};
ok(m.action === 'archive', 'archive manifest records action');
ok(JSON.stringify(paths) === JSON.stringify(want), `manifest lists ${JSON.stringify(paths)}`);
ok(by['docs/HANDOFF.md'].status === 'done', 'HANDOFF records status done');
ok(by['SCRATCH.md'].status === 'completed', 'quoted status normalizes to completed');
ok(by['ANALYSIS.md'].status === 'archived', 'archived status recorded');
ok(by['DEBUG_session.md'].status === 'closed', 'Closed normalizes to closed');
for (const f of m.files) {
  ok(f.refs === 0, `${f.path} archived with refs 0`);
  ok(Array.isArray(f.signals) && typeof f.ageDays === 'number', `${f.path} records signals and ageDays`);
}
EOF
pass 'archive --apply moved only completed unreferenced artifacts'

# (a) undo puts the archive batch back byte-identical.
node "$CLI" undo "$ARCH" > "$SANDBOX/archive-undo.txt"
grep -q 'archive fully undone' "$SANDBOX/archive-undo.txt" || die 'undo should report the archive batch'
( cd "$ARCH" && shasum -c "$SANDBOX/archive-sums.txt" > /dev/null ) || die 'archive undo is not byte-identical'
FOUND_ARCH_MANIFESTS="$(find "$ARCH/.mdsweep" -name manifest.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$FOUND_ARCH_MANIFESTS" = "0" ] || die 'archive manifest should be consumed after full undo'
pass 'undo restored the archive batch byte-identical'

# (b) the same HANDOFF.md, once CLAUDE.md references it, is shown and not moved.
printf '\nThe finished handoff is HANDOFF.md.\n' >> "$ARCH/CLAUDE.md"
node "$CLI" archive "$ARCH" > "$SANDBOX/archive-ref-dry.txt"
grep -q 'Referenced, left in place' "$SANDBOX/archive-ref-dry.txt" || die 'referenced completed file should be shown'
grep -q 'docs/HANDOFF.md' "$SANDBOX/archive-ref-dry.txt" || die 'dry-run should name the referenced file'
FOUND_ARCH_MANIFESTS="$(find "$ARCH/.mdsweep" -name manifest.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$FOUND_ARCH_MANIFESTS" = "0" ] || die 'archive dry-run must not write a manifest'
[ -f "$ARCH/docs/HANDOFF.md" ] || die 'dry-run moved the referenced file'
node "$CLI" archive "$ARCH" --apply > "$SANDBOX/archive-ref-apply.txt"
[ -f "$ARCH/docs/HANDOFF.md" ] || die 'referenced status: done file must not be archived'
[ -f "$ARCH/FINDINGS.md" ] || die 'archive --apply moved a status-less orphan'
[ -f "$ARCH/README.md" ] || die 'archive --apply moved a protected file'
[ ! -f "$ARCH/SCRATCH.md" ] || die 'unreferenced completed file should still be archived'
grep -q 'docs/HANDOFF.md' "$SANDBOX/archive-ref-apply.txt" || die 'apply output should show the referenced file'
REF_MANIFEST="$(find "$ARCH/.mdsweep/archive" -name manifest.json)"
REF_MANIFEST="$REF_MANIFEST" node --input-type=module - <<'EOF'
import fs from 'node:fs';
const m = JSON.parse(fs.readFileSync(process.env.REF_MANIFEST, 'utf8'));
const paths = m.files.map((f) => f.path);
const ok = (cond, msg) => {
  if (!cond) { console.error(`FAIL: ${msg}`); process.exit(1); }
  console.log(`ok - ${msg}`);
};
ok(!paths.includes('docs/HANDOFF.md'), 'referenced HANDOFF is not in the archive manifest');
ok(paths.includes('SCRATCH.md') && paths.includes('ANALYSIS.md') && paths.includes('DEBUG_session.md'),
  'other completed orphans were archived');
EOF
pass 'referenced completed file is shown and not archived'

# (c) quarantine --apply is unchanged: it still moves the status-less orphan
# and still leaves the referenced file, the protected file, and the active file.
sleep 1
node "$CLI" quarantine "$ARCH" --apply > "$SANDBOX/archive-quarantine.txt"
[ ! -f "$ARCH/FINDINGS.md" ] || die 'quarantine should still move a status-less orphan'
[ ! -f "$ARCH/STATUS.md" ] || die 'quarantine should still move STATUS.md (name signal, no status tag)'
[ ! -f "$ARCH/REPORT_done.md" ] || die 'quarantine should still move a body-only "done" file'
[ ! -f "$ARCH/FINAL_notes.md" ] || die 'quarantine should still move status: in-progress orphans'
[ -f "$ARCH/docs/HANDOFF.md" ] || die 'quarantine must not move a referenced file'
[ -f "$ARCH/README.md" ] || die 'quarantine must not move a protected file'
[ -f "$ARCH/DRAFT_fresh.md" ] || die 'quarantine must not move an active file'
[ -f "$ARCH/finished.md" ] || die 'quarantine must not move an unflagged file'
[ ! -f "$ARCH/SCRATCH.md" ] || die 'quarantine ran against a file archive already moved'
pass 'quarantine --apply still moves only orphans'

# The quarantine batch is newer, so the first undo restores it and leaves
# the archive batch in place. The second undo restores the archive.
node "$CLI" undo "$ARCH" > "$SANDBOX/undo-newest.txt"
grep -q 'quarantine fully undone' "$SANDBOX/undo-newest.txt" || die 'newest batch should be the quarantine'
[ -f "$ARCH/FINDINGS.md" ] || die 'first undo should restore the quarantined orphan'
[ ! -f "$ARCH/SCRATCH.md" ] || die 'first undo should not restore the older archive batch'
node "$CLI" undo "$ARCH" > "$SANDBOX/undo-archive.txt"
grep -q 'archive fully undone' "$SANDBOX/undo-archive.txt" || die 'second undo should restore the archive batch'
[ -f "$ARCH/SCRATCH.md" ] || die 'second undo should restore the archived file'
( cd "$ARCH" && shasum -c "$SANDBOX/archive-sums.txt" > /dev/null ) || die 'restored archive/quarantine files differ from originals'
pass 'undo restores the newest quarantine or archive batch, byte-identical'

echo ''
echo 'ALL SMOKE TESTS PASSED'
