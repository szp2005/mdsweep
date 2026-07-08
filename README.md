# mdsweep 🧹

Sweep up the markdown your coding agents leave behind.

If you run Claude Code (or any coding agent) daily, your repos accumulate
`SUMMARY.md`, `PLAN.md`, `HANDOFF.md`, `FINDINGS_V2.md` — session artifacts that
were useful for exactly one task. The problem isn't disk space. It's that
future agent sessions read those stale files as if they were current project
truth, and the noise compounds: yesterday's abandoned plan becomes tomorrow's
context. This is a known pain point in agent workflows (see
anthropics/claude-code#6648).

mdsweep finds these artifacts, grades them by risk, and — only if you ask —
moves the dead ones into a reversible quarantine. It does one thing, in one
file, with zero dependencies.

<!-- DOGFOOD_NUMBERS -->

## Install

```sh
npm install -g mdsweep     # or: npx mdsweep
```

Or just clone and run — it's a single file with no dependencies:

```sh
node bin/mdsweep.mjs scan ~/code/my-repo
```

Requires Node 18+. Git is optional but recommended (better signals).

## Usage

```sh
mdsweep scan [path]          # find and grade artifacts (read-only, default)
mdsweep quarantine [path]    # dry-run: show what would be moved
mdsweep quarantine --apply   # move orphans into .mdsweep/trash/<timestamp>/
mdsweep undo                 # put everything back
```

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

<!-- DEMO_GIF -->

## How files are graded

| Grade | Meaning | Quarantine candidate? |
|---|---|---|
| `active` | committed or modified within the last N days | never |
| `stale` | older than N days, but another file in the repo still references it | never |
| `orphan` | older than N days, zero inbound references | yes (opt-in) |

An inbound reference means some tracked text file in the repo mentions the
artifact's filename (Obsidian-style `[[wikilinks]]` count too). A stale plan
that `CLAUDE.md` still points at is a problem you should resolve by editing,
not by deleting — mdsweep will show it but won't touch it.

## How artifacts are detected

Three signals, any one is enough; every hit records which signals fired:

1. **Filename patterns** — `SUMMARY*`, `PLAN*`, `HANDOFF*`, `*_REPORT.md`,
   `DRAFT*`, `SCRATCH*`, `*_V2.md`, and ~20 more (only `.md`/`.txt`/`.scratch`
   files are ever considered).
2. **Git signals** — the file's history contains a
   `Co-Authored-By: Claude` trailer, or the file is untracked.
3. **Frontmatter** — YAML frontmatter marks it generated
   (`generated_by: claude-code`, `author: agent`, ...).

Never flagged, regardless of signals: `README.md`, `CHANGELOG.md`,
`LICENSE*`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`,
`CLAUDE.md`, `AGENTS.md`, `SKILL.md`, `MEMORY.md`, `llms.txt`, plus anything
under `docs/` when a docs-site config (mkdocs, Docusaurus, Sphinx, VitePress)
is present. `node_modules`, build output, hidden directories, and nested git
repos are skipped.

## Safety guarantees

1. **Read-only by default.** `scan` writes nothing. `quarantine` without
   `--apply` is a dry-run.
2. **Never deletes.** Quarantine *moves* files into
   `.mdsweep/trash/<timestamp>/`, preserving relative paths, with a manifest.
   Only `orphan`-graded files are ever moved.
3. **One-command undo.** `mdsweep undo` restores the most recent batch
   byte-identical. Files whose original location is now occupied are left
   safely in the trash.

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

- `days` — active threshold (CLI `--days` wins).
- `patterns.add` / `patterns.remove` — adjust the filename globs.
- `exclude` — path globs that are never flagged.

## Claude Code skill

`skill/mdsweep/SKILL.md` teaches Claude Code when to run mdsweep and to
always show you the file list before any quarantine. Copy it into your
project or personal skills directory:

```sh
mkdir -p .claude/skills/mdsweep && cp skill/mdsweep/SKILL.md .claude/skills/mdsweep/
```

## License

MIT
