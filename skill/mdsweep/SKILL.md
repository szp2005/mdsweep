---
name: mdsweep
description: Audit and clean up stale agent-generated markdown artifacts (SUMMARY.md, PLAN.md, HANDOFF.md, scratch notes) in a repository. Use when a repo is cluttered with old agent output, when stale plans or reports risk being read as current context, before a repo handoff, or when the user asks to clean up markdown sprawl.
---

# mdsweep

mdsweep finds markdown artifacts left behind by agent sessions, grades them
(`active` / `stale` / `orphan`), and can move orphans into a reversible
quarantine. It never deletes files.

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

   If mdsweep is not installed: `npx mdsweep scan [path] --json`.

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

3. **Before quarantining, show the user the exact list.** Present every
   orphan (path, size, age) and get explicit confirmation. Never run
   `--apply` without the user approving the specific file list in this
   conversation. When in doubt, run the dry-run and show its output:

   ```sh
   mdsweep quarantine [path]        # dry-run, prints what would move
   ```

4. **Quarantine only after approval.**

   ```sh
   mdsweep quarantine [path] --apply
   ```

   Files move to `.mdsweep/trash/<timestamp>/` with a manifest; nothing is
   deleted. Suggest adding `.mdsweep/` to `.gitignore`.

5. **If anything was moved by mistake:**

   ```sh
   mdsweep undo [path]
   ```

   restores the most recent batch byte-identical.

## Hard rules

- Never quarantine without showing the list and getting user confirmation.
- Never quarantine `stale` or `active` files by hand; only mdsweep-graded
  orphans, only via mdsweep (so undo works).
- Never delete files from `.mdsweep/trash/` — that is the user's decision.
