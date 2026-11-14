---
name: mdsweep
description: Audit and clean up stale agent-generated markdown artifacts (SUMMARY.md, PLAN.md, HANDOFF.md, scratch notes) in a repository. Use when a repo is cluttered with old agent output, when stale plans or reports risk being read as current context, before a repo handoff, or when the user asks to clean up markdown sprawl.
---

# mdsweep

mdsweep finds markdown artifacts left behind by agent sessions, grades them
(`active` / `stale` / `orphan`), and can move orphans into a reversible
quarantine. It never deletes files.

**`archive` is new and is not part of npm `mdsweep@0.1.0`.** `npx mdsweep`
and `npm install -g mdsweep` install 0.1.0 (`scan`, `quarantine`, `undo`
only). Run `archive` from a checkout of main:

```sh
node bin/mdsweep.mjs archive [path]
```

## When to run it

- The repo root or subdirectories contain accumulating `SUMMARY.md`,
  `PLAN_*.md`, `*_REPORT.md`, `HANDOFF*.md`, draft or scratch files.
- You are about to rely on an existing plan/summary file and want to know
  whether it is current or abandoned.
- The user asks to tidy the repo, reduce context noise, or prepare a handoff.

## Steps

1. **Scan first, always.** Read-only:

   ```sh
   mdsweep scan [path] --json
   ```

   If mdsweep is not installed: `npx mdsweep scan [path] --json` runs npm
   `mdsweep@0.1.0`, which has no `archive` command.

2. **Interpret the grades.**
   - `active` — touched in the last 14 days (`--days` to adjust). Leave alone.
   - `stale` — old but still referenced by other files (`refs` > 0). Do not
     quarantine; if a reference in CLAUDE.md/README points at an abandoned
     plan, propose updating the referencing file instead.
   - `orphan` — old, zero inbound references. These are the only quarantine
     candidates.
   - `signals` explains why each file was flagged (filename pattern, Claude
     co-authored commit, untracked, generated frontmatter). Mention this when
     summarizing.

3. **Archive is optional, new, and not in npm 0.1.0.** Use it only when the
   user wants completed artifacts put away, and only via a checkout of main
   (`node bin/mdsweep.mjs`). A file is completed when YAML frontmatter
   `status` is `done`, `completed`, `archived`, or `closed` (any case). It
   must already be an agent artifact from the scan, and it must be an orphan
   (older than `--days`, zero inbound references). A `STATUS*` filename or
   the word "done" in body text is not a status. Protected names
   (`README.md`, `CLAUDE.md`, `SKILL.md`, and the rest of the protected set)
   are never archived. Referenced files are shown and not moved.

   Show the dry-run and get explicit confirmation before `--apply`. Never
   archive a file the user has not seen in the list.

   ```sh
   node bin/mdsweep.mjs archive [path]          # dry-run; writes nothing
   node bin/mdsweep.mjs archive [path] --apply  # moves completed orphans
   ```

   Files move to `.mdsweep/archive/<timestamp>/` with a manifest. Nothing is
   deleted.

4. **Before quarantining, show the user the exact list.** Present every
   orphan (path, size, age) and get explicit confirmation. Never run
   `--apply` without the user approving the specific file list in this
   conversation. When in doubt, run the dry-run and show its output:

   ```sh
   mdsweep quarantine [path]        # dry-run, prints what would move
   ```

5. **Quarantine only after approval.**

   ```sh
   mdsweep quarantine [path] --apply
   ```

   Files move to `.mdsweep/trash/<timestamp>/` with a manifest; nothing is
   deleted. Suggest adding `.mdsweep/` to `.gitignore`. Quarantine behavior
   is unchanged: it still moves every orphan, not only completed files.

6. **If anything was moved by mistake:**

   ```sh
   mdsweep undo [path]
   ```

   restores the most recent batch byte-identical, whether that batch was a
   quarantine or an archive.

## Hard rules

- Never quarantine or archive without showing the list and getting user confirmation.
- Never quarantine or archive `stale` or `active` files by hand; only
  mdsweep-graded orphans, only via mdsweep (so undo works).
- Never treat a status tag as a reason to quarantine. `archive` is the only
  command that reads `status`, and it still refuses referenced files.
- Never delete files from `.mdsweep/trash/` or `.mdsweep/archive/` — that is
  the user's decision.
- Do not tell the user that `npx mdsweep` can archive. That package is 0.1.0.
