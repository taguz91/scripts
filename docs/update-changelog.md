# update-changelog

Summarizes the new commits merged from `develop` into the `## [Unreleased]`
section of `CHANGELOG.md`, following the [Keep a Changelog](https://keepachangelog.com)
format, using an LLM CLI to write the entries.

## What it does

1. Fetches `origin` and switches to the `docs/changelog` branch, creating it
   (locally and/or from `origin/develop`) if it doesn't exist yet, locally or
   remotely.
2. Merges `origin/develop` into it.
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
  (`OPENCODE_PERMISSION` denies `bash` and `webfetch`); the Claude Code and
  Codex CLI invocations are similarly limited to file edits.
- Only one model is attempted per run; passing more than one positional
  argument is an error.
- The local `docs/changelog` branch is treated as disposable: if a run
  produces no changelog content (no new commits, or the model couldn't
  write anything), it's deleted automatically rather than left around
  empty. On a failed model attempt, re-run the command with a different
  model.
