# update-changelog

Summarizes the new commits merged from `develop` into the `## [Unreleased]`
section of `CHANGELOG.md`, following the [Keep a Changelog](https://keepachangelog.com)
format, using an LLM CLI to write the entries.

## What it does

1. Fetches `origin` and switches to the `docs/changelog` branch, creating it
   (locally and/or from `origin/develop`) if it doesn't exist yet, locally or
   remotely.
2. Merges `origin/develop` into it. If that merge has conflicts, the model
   is called (only then) to resolve them — see [Conflict resolution](#conflict-resolution)
   below.
3. Collects the non-merge commits that came in with that merge (excluding
   `CHANGELOG.md` itself).
4. If there's nothing new, deletes the local `docs/changelog` branch and exits.
5. Otherwise, asks the given model to edit `CHANGELOG.md`'s `[Unreleased]`
   section based on those commits. Only that one model is tried — there's no
   fallback list.
6. If the model fails to produce a change, deletes the local
   `docs/changelog` branch and exits with an error, telling you to re-run
   with a different model.
7. Commits and pushes the update to `docs/changelog` (unless `--no-commit`),
   then returns to the starting branch.

## Conflict resolution

The `develop` merge normally applies cleanly, so the model is not involved.
It's only invoked when `git merge` reports conflicts:

1. The script lists the conflicted files (`git diff --name-only --diff-filter=U`).
2. It asks the model to resolve the conflict markers (`<<<<<<<`, `=======`,
   `>>>>>>>`) in just those files, reconciling both sides' intent.
3. If any conflict markers remain afterward, the merge is aborted
   (`git merge --abort`), the local `docs/changelog` branch is deleted, and
   the script exits with an error — re-run once the underlying conflict is
   easier to resolve (e.g. after `develop` settles down), optionally with a
   different model.
4. Otherwise, the resolved files are staged and the merge commit is
   finalized (`git commit --no-edit`), and the script continues as usual.
   If staging or committing itself fails (e.g. a pre-commit hook rejects
   it), the same abort-and-delete cleanup runs.

## Usage

```
update-changelog [model]
```

With no arguments, it uses the default model: `opencode/grok-code-fast-1`.

With an argument, it uses that model instead. Only one model is tried per
run — the argument can be:

- A full opencode model ID or a fragment of one (e.g. `mimo`, `ling`,
  `grok-code-fast-1`) — resolved against `opencode models opencode`.
- `claude:<model>` — runs that step via the Claude Code CLI instead of
  opencode (e.g. `claude:haiku`, `claude:sonnet`).
- `codex:<model>` or bare `codex` — runs that step via the Codex CLI instead
  of opencode (e.g. `codex:gpt-5-codex`; bare `codex` uses its default model).

### Options

| Flag | Description |
| --- | --- |
| `-l`, `--list` | List the free opencode models available |
| `-b`, `--back <branch>` | Branch to return to when done (default: `develop`) |
| `-i`, `--interactive` | Ask for confirmation before commit and push |
| `--no-commit` | Only update and stage `CHANGELOG.md`, without committing (used by `create-release`) |
| `-h`, `--help` | Show usage help |

### Examples

```
update-changelog
update-changelog mimo
update-changelog claude:haiku
update-changelog codex:gpt-5-codex
update-changelog -b main mimo
```

## Notes

- The script never checks out `develop` directly; it merges
  `origin/develop` into `docs/changelog`, so it's safe to run from a worktree
  that has `develop` checked out elsewhere.
- When a model is run via opencode, it's restricted to editing files only
  (`OPENCODE_PERMISSION` denies `bash` and `webfetch`); Claude Code is
  similarly limited (`--allowedTools "Read,Edit"`). Codex has no equivalent
  fine-grained permission — `codex exec --full-auto` grants a
  workspace-write sandbox that can still run shell commands in the repo, so
  a `codex:` run is not confined to file edits the way the other two are.
- Only one model is attempted per run; passing more than one positional
  argument is an error.
- The local `docs/changelog` branch is treated as disposable: if a run
  produces no changelog content (no new commits, the model couldn't
  write anything, or a merge conflict couldn't be resolved), it's deleted
  automatically rather than left around empty. On a failed attempt, re-run
  the command with a different model.
