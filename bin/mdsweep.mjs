#!/usr/bin/env node
/**
 * mdsweep — find, grade, and safely quarantine agent-generated markdown
 * artifacts (SUMMARY.md, PLAN.md, scratch notes...) cluttering a repo.
 *
 * Single file, zero dependencies, Node >= 18.
 * Read-only by default. Never deletes. `mdsweep undo` reverses quarantine.
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const VERSION = '0.1.0';
const DEFAULT_DAYS = 14;
const ELIGIBLE = /\.(md|markdown|txt|scratch)$/i;
const MAX_REF_SOURCE_BYTES = 2 * 1024 * 1024;

// Filename patterns agents habitually produce. Case-insensitive globs,
// matched against the basename. Extend or trim via .mdsweep.json.
const DEFAULT_PATTERNS = [
  'SUMMARY*', 'PLAN*', '*_PLAN.md', 'NOTES*', 'FINDINGS*', 'ANALYSIS*',
  '*_REPORT.md', 'REPORT_*', 'HANDOFF*', 'SCRATCH*', '*.scratch.md',
  'TODO_*', 'DRAFT*', 'draft-*', 'REVIEW-*', '*_REVIEW.md', '*_V2.md',
  '*_V3.md', 'FINAL_*', 'IMPLEMENTATION*', 'VERIFICATION*', 'DEBUG_*',
  'FIX_*', 'CHANGES_*', 'IDEAS*', 'BRAINSTORM*', 'PROGRESS*', 'STATUS*',
  'CHECKLIST*',
];

// Never flagged, regardless of signals.
const PROTECTED_BASENAMES = new Set([
  'readme.md', 'changelog.md', 'contributing.md', 'code_of_conduct.md',
  'security.md', 'claude.md', 'claude.local.md', 'agents.md', 'skill.md',
  'memory.md', 'llms.txt', 'robots.txt', 'ads.txt', 'app-ads.txt',
]);

const SKIP_DIRS = new Set([
  'node_modules', 'dist', 'build', 'out', 'vendor', 'venv', 'coverage',
  'target', '__pycache__', 'third_party', 'Pods', 'DerivedData',
]);

// Files that mention filenames without meaning them.
const NON_REF_SOURCES = new Set([
  '.gitignore', '.npmignore', '.dockerignore', '.eslintignore',
  '.prettierignore', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml',
  'bun.lockb', 'composer.lock', 'cargo.lock', 'poetry.lock',
]);

const GRADE_ORDER = { orphan: 0, stale: 1, active: 2 };

// ---------------------------------------------------------------- utilities

function fail(msg) {
  console.error(`mdsweep: ${msg}`);
  process.exit(1);
}

function fmtSize(n) {
  if (n < 1024) return `${n}B`;
  const units = ['K', 'M', 'G'];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return (v >= 10 ? Math.round(v).toString() : v.toFixed(1)) + units[i];
}

function fmtAge(days) {
  if (days < 1) return 'today';
  if (days < 60) return `${Math.round(days)}d`;
  if (days < 365) return `${Math.round(days / 30)}mo`;
  return `${(days / 365).toFixed(1)}y`;
}

function truncatePath(p, max = 68) {
  if (p.length <= max) return p;
  return `${p.slice(0, Math.floor(max / 2) - 1)}…${p.slice(-(max - Math.floor(max / 2)))}`;
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Basename globs by default; matchPath treats `/` as a separator and
// supports `**` (used for .mdsweep.json exclude globs).
function globToRegExp(glob, { matchPath = false } = {}) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (matchPath && glob[i + 1] === '*') { re += '.*'; i++; }
      else re += matchPath ? '[^/]*' : '.*';
    } else if (c === '?') {
      re += matchPath ? '[^/]' : '.';
    } else {
      re += escapeRe(c);
    }
  }
  return new RegExp(`^${re}$`, 'i');
}

// ------------------------------------------------------------------- config

function loadConfig(root) {
  const cfg = { days: null, patterns: [...DEFAULT_PATTERNS], exclude: [] };
  const file = path.join(root, '.mdsweep.json');
  if (!fs.existsSync(file)) return cfg;
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    fail(`could not parse ${file}: ${err.message}`);
  }
  if (raw.days != null) {
    if (typeof raw.days !== 'number' || raw.days < 0) fail(`"days" in .mdsweep.json must be a non-negative number`);
    cfg.days = raw.days;
  }
  const p = raw.patterns ?? {};
  if (Array.isArray(p.add)) cfg.patterns.push(...p.add);
  if (Array.isArray(p.remove)) {
    const remove = new Set(p.remove.map((x) => x.toLowerCase()));
    cfg.patterns = cfg.patterns.filter((x) => !remove.has(x.toLowerCase()));
  }
  if (Array.isArray(raw.exclude)) cfg.exclude = raw.exclude;
  return cfg;
}

// ---------------------------------------------------------------------- git

function gitRun(root, args) {
  try {
    return execFileSync('git', ['-c', 'core.quotepath=false', '-C', root, ...args], {
      encoding: 'utf8',
      maxBuffer: 1 << 30,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch {
    return null;
  }
}

function collectGit(root) {
  const none = { isRepo: false, tracked: new Set(), lastCommit: new Map(), claude: new Set() };
  const top = gitRun(root, ['rev-parse', '--show-toplevel']);
  if (top == null) return none;

  const toplevel = top.trim();
  let real = root;
  try { real = fs.realpathSync(root); } catch { /* keep as-is */ }
  const prefix = path.relative(toplevel, real);
  // git log prints toplevel-relative paths; we work root-relative.
  const strip = (p) => {
    if (!prefix) return p;
    return p.startsWith(`${prefix}/`) ? p.slice(prefix.length + 1) : null;
  };

  const tracked = new Set();
  const ls = gitRun(root, ['ls-files', '-z']);
  if (ls != null) for (const p of ls.split('\0')) if (p) tracked.add(p);

  // One pass over history: newest-first, first sighting of a path is its
  // last commit time. Much faster than `git log --follow` per file.
  const lastCommit = new Map();
  const log = gitRun(root, ['log', '--name-only', '--format=%x01%ct', '--', '.']);
  if (log != null) {
    let ts = 0;
    for (const line of log.split('\n')) {
      if (!line) continue;
      if (line.charCodeAt(0) === 1) { ts = Number(line.slice(1)) * 1000; continue; }
      const rel = strip(line);
      if (rel && !lastCommit.has(rel)) lastCommit.set(rel, ts);
    }
  }

  // Files ever touched by a commit with a Claude co-author trailer.
  const claude = new Set();
  const clog = gitRun(root, [
    'log', '--regexp-ignore-case', '--grep=co-authored-by:.*claude',
    '--name-only', '--format=%x01', '--', '.',
  ]);
  if (clog != null) {
    for (const line of clog.split('\n')) {
      if (!line || line.charCodeAt(0) === 1) continue;
      const rel = strip(line);
      if (rel) claude.add(rel);
    }
  }

  return { isRepo: true, toplevel, tracked, lastCommit, claude };
}

// --------------------------------------------------------------------- walk

function walkTree(root) {
  const files = [];
  const nestedRepos = [];
  const warnings = [];
  const stack = [''];
  while (stack.length) {
    const rel = stack.pop();
    const abs = rel ? path.join(root, rel) : root;
    let entries;
    try {
      entries = fs.readdirSync(abs, { withFileTypes: true });
    } catch (err) {
      warnings.push(`skipped ${rel || '.'} (${err.code || err.message})`);
      continue;
    }
    // A nested .git means a separate repo — scan it separately instead.
    if (rel && entries.some((e) => e.name === '.git')) {
      nestedRepos.push(rel);
      continue;
    }
    for (const e of entries) {
      if (e.isSymbolicLink()) continue;
      const childRel = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) {
        if (e.name.startsWith('.') || SKIP_DIRS.has(e.name)) continue;
        stack.push(childRel);
      } else if (e.isFile()) {
        files.push(childRel);
      }
    }
  }
  return { files, nestedRepos, warnings };
}

function inSkippedDir(rel) {
  return rel.split('/').some((seg) => SKIP_DIRS.has(seg) || seg === '.mdsweep');
}

// Directories owned by a site generator hold published product, not
// session artifacts — leave them alone when the generator's config exists.
function generatorOwnedDirs(root) {
  const owned = [];
  const has = (...files) => files.some((f) => fs.existsSync(path.join(root, f)));
  if (has('mkdocs.yml', 'mkdocs.yaml', 'docusaurus.config.js', 'docusaurus.config.ts',
    'docusaurus.config.mjs', 'docs/conf.py', 'docs/source/conf.py', 'docs/.vitepress')) {
    owned.push('docs/');
  }
  if (has('astro.config.mjs', 'astro.config.ts', 'astro.config.js', 'hugo.toml',
    'hugo.yaml', 'config.toml', 'gatsby-config.js', 'gatsby-config.ts',
    '.eleventy.js', 'eleventy.config.js')) {
    owned.push('content/');
  }
  if (has('_config.yml')) owned.push('_posts/');
  return owned;
}

// -------------------------------------------------------------- frontmatter

const FM_KEY = /^(generated|generator|generated[-_]?by|created[-_]?by|author|tool|source|producer)\s*:\s*(.+)$/i;
const FM_VAL = /claude|agent|assistant|copilot|gpt|llm|\bai\b|generated|true/i;

function frontmatterGenerated(abs) {
  let fd;
  let head;
  try {
    fd = fs.openSync(abs, 'r');
    const buf = Buffer.alloc(4096);
    const n = fs.readSync(fd, buf, 0, 4096, 0);
    head = buf.subarray(0, n).toString('utf8');
  } catch {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
  if (!head.startsWith('---')) return false;
  const end = head.indexOf('\n---', 3);
  if (end === -1) return false;
  for (const line of head.slice(3, end).split('\n')) {
    const m = FM_KEY.exec(line.trim());
    if (m && FM_VAL.test(m[2])) return true;
  }
  return false;
}

// --------------------------------------------------------------------- scan

function runScan(root, opts) {
  const cfg = loadConfig(root);
  const days = opts.days ?? cfg.days ?? DEFAULT_DAYS;
  const git = collectGit(root);
  const { files, nestedRepos, warnings } = walkTree(root);
  const patterns = cfg.patterns.map((p) => [p, globToRegExp(p)]);
  const excludes = cfg.exclude.map((g) => globToRegExp(g, { matchPath: true }));
  const ownedDirs = generatorOwnedDirs(root);
  const now = Date.now();

  let scanned = 0;
  const hits = [];
  for (const rel of files) {
    if (!ELIGIBLE.test(rel)) continue;
    scanned++;
    const base = path.basename(rel);
    const baseLower = base.toLowerCase();
    if (PROTECTED_BASENAMES.has(baseLower) || baseLower.startsWith('license')) continue;
    if (ownedDirs.some((d) => rel.startsWith(d))) continue;
    if (excludes.some((re) => re.test(rel))) continue;

    const abs = path.join(root, rel);
    let st;
    try { st = fs.statSync(abs); } catch { continue; }

    const signals = [];
    for (const [name, re] of patterns) {
      if (re.test(base)) { signals.push(`name:${name}`); break; }
    }
    if (git.isRepo) {
      if (!git.tracked.has(rel)) signals.push('git:untracked');
      if (git.claude.has(rel)) signals.push('git:claude-coauthor');
    }
    if (frontmatterGenerated(abs)) signals.push('frontmatter');
    if (!signals.length) continue;

    const lastTouched = Math.max(st.mtimeMs, git.lastCommit.get(rel) ?? 0);
    hits.push({
      rel,
      base,
      size: st.size,
      lastTouched,
      ageDays: Math.max(0, (now - lastTouched) / 86400000),
      signals,
      refs: 0,
    });
  }

  countInboundRefs(root, hits, git, files);
  for (const h of hits) {
    h.grade = h.ageDays <= days ? 'active' : h.refs > 0 ? 'stale' : 'orphan';
  }
  hits.sort((a, b) => GRADE_ORDER[a.grade] - GRADE_ORDER[b.grade] || b.ageDays - a.ageDays);

  return { root, days, git, scanned, hits, nestedRepos, warnings };
}

// Inbound reference = another text file in the repo mentions this file's
// basename (or its stem as an Obsidian [[wikilink]]).
function countInboundRefs(root, hits, git, walkedFiles) {
  if (!hits.length) return;

  const byBase = new Map();
  for (const h of hits) {
    const key = h.base.toLowerCase();
    if (!byBase.has(key)) byBase.set(key, []);
    byBase.get(key).push(h);
  }

  const names = [...byBase.keys()];
  const nameRes = [];
  for (let i = 0; i < names.length; i += 300) {
    const chunk = names.slice(i, i + 300).map(escapeRe).join('|');
    nameRes.push(new RegExp(`(?<![A-Za-z0-9_.-])(${chunk})(?![A-Za-z0-9])`, 'gi'));
  }

  const stemToNames = new Map();
  for (const n of names) {
    const stem = n.replace(ELIGIBLE, '').toLowerCase();
    if (!stem) continue;
    if (!stemToNames.has(stem)) stemToNames.set(stem, []);
    stemToNames.get(stem).push(n);
  }
  const stems = [...stemToNames.keys()];
  const wikiRes = [];
  for (let i = 0; i < stems.length; i += 300) {
    const chunk = stems.slice(i, i + 300).map(escapeRe).join('|');
    wikiRes.push(new RegExp(`\\[\\[\\s*(${chunk})\\s*[#|\\]]`, 'gi'));
  }

  // In a git repo only tracked files vouch for a hit; elsewhere, any file.
  const sources = git.isRepo ? [...git.tracked] : walkedFiles;
  for (const src of sources) {
    if (NON_REF_SOURCES.has(path.basename(src).toLowerCase()) || inSkippedDir(src)) continue;
    const abs = path.join(root, src);
    let st;
    try { st = fs.statSync(abs); } catch { continue; }
    if (!st.isFile() || st.size === 0 || st.size > MAX_REF_SOURCE_BYTES) continue;
    let buf;
    try { buf = fs.readFileSync(abs); } catch { continue; }
    if (buf.subarray(0, 8192).includes(0)) continue; // binary

    const text = buf.toString('utf8');
    const matched = new Set();
    for (const re of nameRes) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(text)) !== null) matched.add(m[1].toLowerCase());
    }
    for (const re of wikiRes) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(text)) !== null) {
        for (const n of stemToNames.get(m[1].toLowerCase()) ?? []) matched.add(n);
      }
    }
    for (const name of matched) {
      for (const h of byBase.get(name) ?? []) if (h.rel !== src) h.refs++;
    }
  }
}

// ------------------------------------------------------------------- output

function shortSignals(signals) {
  return signals
    .map((s) => {
      if (s.startsWith('name:')) return 'name';
      if (s === 'git:untracked') return 'untracked';
      if (s === 'git:claude-coauthor') return 'claude';
      return 'fm';
    })
    .join('+');
}

function printTable(hits) {
  const headers = ['FILE', 'SIZE', 'AGE', 'GRADE', 'REFS', 'SIGNALS'];
  const rows = hits.map((h) => [
    truncatePath(h.rel), fmtSize(h.size), fmtAge(h.ageDays), h.grade, String(h.refs), shortSignals(h.signals),
  ]);
  const widths = headers.map((hd, i) => Math.max(hd.length, ...rows.map((r) => r[i].length)));
  const line = (cols) => cols.map((c, i) => c.padEnd(widths[i])).join('  ').trimEnd();
  console.log(line(headers));
  console.log(widths.map((w) => '-'.repeat(w)).join('  '));
  for (const r of rows) console.log(line(r));
}

function summarize(hits) {
  const s = { active: 0, stale: 0, orphan: 0, orphanBytes: 0 };
  for (const h of hits) {
    s[h.grade]++;
    if (h.grade === 'orphan') s.orphanBytes += h.size;
  }
  return s;
}

function printNotes(result, toStderr = false) {
  const out = toStderr ? console.error : console.log;
  if (!result.git.isRepo) {
    out('note: not a git repository — git signals disabled, grading by mtime only');
  }
  if (result.nestedRepos.length) {
    out(`note: skipped ${result.nestedRepos.length} nested git repo(s): ${result.nestedRepos.slice(0, 5).join(', ')}${result.nestedRepos.length > 5 ? ', …' : ''} (scan them separately)`);
  }
  for (const w of result.warnings.slice(0, 5)) out(`warning: ${w}`);
  if (result.warnings.length > 5) out(`warning: …and ${result.warnings.length - 5} more`);
}

function cmdScan(root, opts) {
  const result = runScan(root, opts);
  const summary = summarize(result.hits);

  if (opts.json) {
    printNotes(result, true);
    console.log(JSON.stringify({
      version: VERSION,
      root,
      git: result.git.isRepo,
      days: result.days,
      scanned: result.scanned,
      flagged: result.hits.length,
      summary,
      files: result.hits.map((h) => ({
        path: h.rel,
        size: h.size,
        lastTouched: new Date(h.lastTouched).toISOString(),
        ageDays: Math.floor(h.ageDays),
        grade: h.grade,
        refs: h.refs,
        signals: h.signals,
      })),
    }, null, 2));
    return;
  }

  printNotes(result);
  if (result.scanned === 0) {
    console.log(`No markdown/text files found in ${root}`);
    return;
  }
  if (!result.hits.length) {
    console.log(`Scanned ${result.scanned} markdown/text files in ${root} — nothing flagged.`);
    return;
  }
  printTable(result.hits);
  console.log('');
  console.log(`Scanned ${result.scanned} markdown/text files in ${root}`);
  console.log(`Flagged ${result.hits.length}: ${summary.orphan} orphan (${fmtSize(summary.orphanBytes)}) · ${summary.stale} stale · ${summary.active} active`);
  if (summary.orphan > 0) {
    console.log(`Orphans are >${result.days} days old with zero inbound references.`);
    console.log('Preview cleanup (moves nothing yet): mdsweep quarantine');
  }
}

// --------------------------------------------------------------- quarantine

function cmdQuarantine(root, opts) {
  const result = runScan(root, opts);
  printNotes(result);
  const orphans = result.hits.filter((h) => h.grade === 'orphan');
  if (!orphans.length) {
    console.log('Nothing to quarantine — no orphaned artifacts found.');
    return;
  }

  printTable(orphans);
  const total = orphans.reduce((n, h) => n + h.size, 0);
  console.log('');

  if (!opts.apply) {
    console.log(`DRY RUN — nothing was moved.`);
    console.log(`Would move ${orphans.length} orphaned file(s) (${fmtSize(total)}) into .mdsweep/trash/`);
    console.log(`Re-run with --apply to move them. Restore any time with: mdsweep undo`);
    return;
  }

  const stamp = new Date().toISOString().replace(/:/g, '-').replace(/\.\d+Z$/, 'Z');
  const trashDir = path.join(root, '.mdsweep', 'trash', stamp);
  const moved = [];
  for (const h of orphans) {
    const dest = path.join(trashDir, h.rel);
    try {
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.renameSync(path.join(root, h.rel), dest);
      moved.push({ path: h.rel, size: h.size, signals: h.signals, ageDays: Math.floor(h.ageDays) });
    } catch (err) {
      console.error(`warning: could not move ${h.rel}: ${err.code || err.message}`);
    }
  }
  if (!moved.length) {
    try { fs.rmSync(trashDir, { recursive: true, force: true }); } catch { /* best effort */ }
    fail('no files could be moved');
  }
  const manifest = { version: 1, createdAt: new Date().toISOString(), root, days: result.days, files: moved };
  fs.writeFileSync(path.join(trashDir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`Moved ${moved.length} file(s) (${fmtSize(total)}) to ${path.relative(process.cwd(), trashDir) || trashDir}`);
  console.log('Nothing was deleted. Restore everything with: mdsweep undo');
  const gi = path.join(root, '.gitignore');
  let giHasEntry = false;
  try { giHasEntry = fs.readFileSync(gi, 'utf8').includes('.mdsweep'); } catch { /* no .gitignore */ }
  if (!giHasEntry) console.log('Tip: add ".mdsweep/" to your .gitignore');
}

// --------------------------------------------------------------------- undo

function cmdUndo(root) {
  const trashRoot = path.join(root, '.mdsweep', 'trash');
  let entries = [];
  try {
    entries = fs.readdirSync(trashRoot).sort().reverse();
  } catch {
    fail(`nothing to undo — no quarantine history at ${trashRoot}`);
  }

  let batchDir = null;
  let manifest = null;
  for (const e of entries) {
    const m = path.join(trashRoot, e, 'manifest.json');
    if (fs.existsSync(m)) {
      try {
        manifest = JSON.parse(fs.readFileSync(m, 'utf8'));
        batchDir = path.join(trashRoot, e);
        break;
      } catch (err) {
        fail(`corrupt manifest at ${m}: ${err.message}`);
      }
    }
  }
  if (!manifest) fail('nothing to undo — no manifest found in .mdsweep/trash/');

  const remaining = [];
  let restored = 0;
  for (const f of manifest.files) {
    const src = path.join(batchDir, f.path);
    const dest = path.join(root, f.path);
    if (!fs.existsSync(src)) {
      console.error(`warning: missing from trash, skipped: ${f.path}`);
      continue;
    }
    if (fs.existsSync(dest)) {
      console.error(`warning: ${f.path} already exists in repo, left in trash`);
      remaining.push(f);
      continue;
    }
    try {
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.renameSync(src, dest);
      restored++;
    } catch (err) {
      console.error(`warning: could not restore ${f.path}: ${err.code || err.message}`);
      remaining.push(f);
    }
  }

  if (remaining.length) {
    manifest.files = remaining;
    fs.writeFileSync(path.join(batchDir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
    console.log(`Restored ${restored} file(s); ${remaining.length} left in ${batchDir}`);
  } else {
    fs.rmSync(batchDir, { recursive: true, force: true });
    console.log(`Restored ${restored} file(s) from ${path.basename(batchDir)} — quarantine fully undone.`);
  }
}

// --------------------------------------------------------------------- main

function printHelp() {
  console.log(`mdsweep v${VERSION} — sweep up agent-generated markdown artifacts

Usage:
  mdsweep [scan] [path] [--days N] [--json]
  mdsweep quarantine [path] [--days N] [--apply]
  mdsweep undo [path]

Commands:
  scan        Find and grade artifacts (default; read-only)
  quarantine  Move orphaned artifacts into .mdsweep/trash/ (dry-run unless --apply)
  undo        Restore the most recent quarantine batch

Options:
  --days N    "Active" threshold in days (default ${DEFAULT_DAYS})
  --json      Machine-readable scan output
  --apply     Actually move files (quarantine only)
  --version   Print version
  -h, --help  Show this help

Grades:
  active   touched in the last N days — left alone
  stale    old, but another file in the repo still references it
  orphan   old and unreferenced — the only quarantine candidates

mdsweep never deletes anything. Quarantine moves files (paths preserved)
into .mdsweep/trash/<timestamp>/ with a manifest; undo puts them back.
Configuration lives in .mdsweep.json — see the README.`);
}

function main() {
  const argv = process.argv.slice(2);
  const positional = [];
  const opts = { days: null, json: false, apply: false };

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--days' || a.startsWith('--days=')) {
      const v = a.includes('=') ? a.split('=')[1] : argv[++i];
      const n = Number(v);
      if (!Number.isFinite(n) || n < 0) fail('--days expects a non-negative number');
      opts.days = n;
    } else if (a === '--json') {
      opts.json = true;
    } else if (a === '--apply') {
      opts.apply = true;
    } else if (a === '-h' || a === '--help') {
      printHelp();
      return;
    } else if (a === '--version') {
      console.log(VERSION);
      return;
    } else if (a.startsWith('-')) {
      fail(`unknown option: ${a} (try mdsweep --help)`);
    } else {
      positional.push(a);
    }
  }

  let cmd = 'scan';
  if (positional.length && ['scan', 'quarantine', 'undo', 'help'].includes(positional[0])) {
    cmd = positional.shift();
  }
  if (cmd === 'help') {
    printHelp();
    return;
  }
  if (positional.length > 1) fail(`unexpected argument: ${positional[1]}`);

  const root = path.resolve(positional[0] ?? '.');
  let st;
  try { st = fs.statSync(root); } catch { fail(`path not found: ${root}`); }
  if (!st.isDirectory()) fail(`not a directory: ${root}`);

  if (cmd === 'scan') cmdScan(root, opts);
  else if (cmd === 'quarantine') cmdQuarantine(root, opts);
  else cmdUndo(root);
}

main();
