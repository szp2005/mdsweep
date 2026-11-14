# mdsweep 🧹

Sweep up the markdown your coding agents leave behind.

> Built to keep my own repos tidy — one file, zero dependencies, maintained on
> a best-effort basis. Issues and PRs welcome.

If you run Claude Code (or any coding agent) daily, your repos accumulate
`SUMMARY.md`, `PLAN.md`, `HANDOFF.md`, `FINDINGS_V2.md`: session artifacts that
were useful for exactly one task. The real cost is not disk space. Future
agent sessions read those stale files as current project truth, and the noise
compounds: yesterday's abandoned plan becomes tomorrow's context. This is a
known pain point in agent workflows (see anthropics/claude-code#6648).

mdsweep finds these artifacts, grades them by risk, and moves the dead ones
into a reversible quarantine only when you ask. It does one thing, in one
file, with zero dependencies.

## Numbers from the repos it was built in

First run across the author's own 14 repositories (a one-person company
group running Claude Code agents daily):

- 1,879 markdown/text files scanned, in under 5 seconds
- 317 flagged as agent artifacts
- 170 of those (54%) stale or orphaned
- 115 orphans (~0.9 MB) eligible for reversible quarantine

The conservative side matters just as much: on the hottest repo, 130 of 139
markdown files are agent-written, and mdsweep quarantines none of them,
because they are all in active use.

## Install

One file, zero dependencies. Requires Node 18+. Git is optional but recommended
(better signals).

npm currently installs **0.1.0**, which includes `scan`, `quarantine`, and
`undo` only. **`archive` is new on `main` and is not part of npm `mdsweep@0.1.0`.**
Until a future npm release, run `archive` from a checkout of `main` with
`node bin/mdsweep.mjs`.

```sh
npm install -g mdsweep
mdsweep scan ~/code/my-repo

npx mdsweep scan ~/code/my-repo

git clone https://github.com/szp2005/mdsweep && cd mdsweep
node bin/mdsweep.mjs scan ~/code/my-repo
```

## Usage

```sh
mdsweep scan [path]          # find and grade artifacts (read-only, default)
mdsweep quarantine [path]    # dry-run: show what would be moved
mdsweep quarantine --apply   # move orphans into .mdsweep/trash/<timestamp>/
mdsweep archive [path]       # NEW, not in npm 0.1.0. Dry-run: completed files
mdsweep archive --apply      # move completed orphans into .mdsweep/archive/<timestamp>/
mdsweep undo                 # put the newest quarantine or archive batch back
```

`archive` is **new** and is **not** part of npm `mdsweep@0.1.0`. It is opt-in
and a dry-run unless you pass `--apply`. A file is completed when its YAML
frontmatter `status` is `done`, `completed`, `archived`, or `closed`
(any case). The file must already be flagged as an agent artifact. A
`STATUS*` filename, or the word "done" in body text, is not a status.
Protected names are never archived. A completed file that another file still
references is listed and left in place, same as `stale`. Files inside the
active window (`--days`, default 14) are left in place too. Nothing is
deleted: `--apply` moves files to `.mdsweep/archive/<timestamp>/` with a
manifest, and `mdsweep undo` restores the newest batch whether it came from
quarantine or archive.

Example scan:

```
FILE                        SIZE  AGE   GRADE   REFS  SIGNALS
--------------------------  ----  ----  ------  ----  ---------------
SUMMARY.md                  4.1K  6mo   orphan  0     name+claude
research/FINDINGS_V2.md     12K   4mo   orphan  0     name+untracked
PLAN_auth.md                8.3K  3mo   stale   2     name+claude
NOTES.md                    1.2K  2d    active  0     name+untracked

Scanned 214 markdown/text files in /Users/you/code/my-repo
Flagged 4: 2 orphan (16K) · 1 stale · 1 active
```

`--json` gives the same data machine-readable. `--days N` changes the
"active" window (default 14).

![mdsweep scan, archive, quarantine, and undo on a sample repo](docs/demo.gif)

## How files are graded

| Grade | Meaning | Quarantine candidate? |
|---|---|---|
| `active` | committed or modified within the last N days | never |
| `stale` | older than N days, but another file in the repo still references it | never |
| `orphan` | older than N days, zero inbound references | yes (opt-in) |

An inbound reference means some tracked text file in the repo mentions the
artifact's filename (Obsidian-style `[[wikilinks]]` count too). A stale plan
that `CLAUDE.md` still points at is a problem you should resolve by editing,
not by deleting. mdsweep shows it and leaves it alone.

## How artifacts are detected

Three signals, any one is enough; every hit records which signals fired:

1. **Filename patterns**: `SUMMARY*`, `PLAN*`, `HANDOFF*`, `*_REPORT.md`,
   `DRAFT*`, `SCRATCH*`, `*_V2.md`, and ~20 more (only `.md`/`.txt`/`.scratch`
   files are ever considered).
2. **Git signals**: the file's history contains a
   `Co-Authored-By: Claude` trailer, or the file is untracked.
3. **Frontmatter**: YAML frontmatter marks it generated
   (`generated_by: claude-code`, `author: agent`, ...).

Never flagged, regardless of signals: `README.md`, `CHANGELOG.md`,
`LICENSE*`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`,
`CLAUDE.md`, `AGENTS.md`, `SKILL.md`, `MEMORY.md`, `llms.txt`, `robots.txt`,
`ads.txt`. Directories owned by a site generator are published product, not
session artifacts, so they're skipped too: `docs/` when a mkdocs, Docusaurus,
Sphinx, or VitePress config is present; `content/` for Astro, Hugo, Gatsby,
Eleventy; `_posts/` for Jekyll. `public/` and `static/` are skipped:
web-served assets like search-engine verification tokens live there.
`node_modules`, build output, hidden directories, and nested git repos are
also skipped.

## Safety guarantees

1. **Read-only by default.** `scan` writes nothing. `quarantine` and `archive`
   without `--apply` are dry-runs and do not create `.mdsweep`.
2. **Never deletes.** Quarantine *moves* orphans into
   `.mdsweep/trash/<timestamp>/`. Archive *moves* completed orphans into
   `.mdsweep/archive/<timestamp>/`. Both preserve relative paths and write a
   manifest. Only `orphan`-graded files are ever moved. Each manifest entry
   records where the file came from and why it was moved: its `signals` (what
   marked it as agent output), its `ageDays` against the batch's `days`
   threshold, and its `refs` count. Archive entries also record the frontmatter
   `status`, so a restored file can be judged without re-running the scan.
3. **One-command undo.** `mdsweep undo` restores the most recent batch
   byte-identical, whether that batch was a quarantine or an archive.
   Files whose original location is now occupied stay in the batch.

## How it compares

Most tools in this space either delete finished plans or are skills that live
inside one agent. mdsweep is a standalone CLI that never deletes and only
touches files nothing else references.

| Tool | Form | What happens to old files |
|---|---|---|
| mdsweep | single-file Node CLI + optional Claude Code skill | orphans moved to `.mdsweep/trash/`; optional `archive` moves completed files to `.mdsweep/archive/`; one-command undo |
| [ccplan](https://github.com/sorafujitani/ccplan) | CLI for `.claude/plans/*.md` | deleted by status and age (`--dry-run` available) |
| [doc-cleanup](https://github.com/aka-luan/doc-cleanup) | agent skill | agent audits docs, archives finished content |

References stay the default. Optional status-based archiving (`mdsweep archive`,
new on `main`, not in npm `mdsweep@0.1.0`) still never moves a file another
file references: a stale plan that `CLAUDE.md` still points at is shown but
never moved.

## Configuration

Optional `.mdsweep.json` in the repo root:

```json
{
  "days": 30,
  "patterns": {
    "add": ["MEETING_*", "*.dump.md"],
    "remove": ["STATUS*"]
  },
  "exclude": ["content/**", "research/archive/**"]
}
```

- `days`: active threshold (CLI `--days` wins).
- `patterns.add` / `patterns.remove`: adjust the filename globs.
- `exclude`: path globs that are never flagged.

## Claude Code skill

`skill/mdsweep/SKILL.md` teaches Claude Code when to run mdsweep and to
always show you the file list before any quarantine. Copy it into your
project or personal skills directory:

```sh
mkdir -p .claude/skills/mdsweep && cp skill/mdsweep/SKILL.md .claude/skills/mdsweep/
```

## License

MIT
