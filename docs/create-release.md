# create-release

Updates the changelog, bumps the version, and opens the release PR — wraps
[update-changelog](update-changelog.md) plus the SemVer/PR mechanics.

## What it does

1. Runs `update-changelog --no-commit [model]` to sync `docs/changelog` with
   `develop` and update `CHANGELOG.md`'s `[Unreleased]` section (left
   staged, not committed). This step also resolves merge conflicts with the
   model on its own, if the merge needs it — see
   [update-changelog's conflict resolution](update-changelog.md#conflict-resolution).
2. Reads `[Unreleased]`; if it's empty, aborts (nothing to release).
3. Computes the version bump from the changelog content, unless forced with
   `--major`/`--minor`/`--patch`:
   - `BREAKING` mentions or a `### Removed` section → major
   - `### Added` → minor
   - otherwise → patch
4. Moves `[Unreleased]` to `[X.Y.Z] - <date>`, updates the compare links (if
   present), and bumps `package.json` (and `package-lock.json`, if present).
5. Shows a preview (version, diff stat, changelog body) and asks for
   confirmation.
6. Commits and pushes `docs/changelog`, creates `release/vX.Y.Z`, pushes it,
   and opens a PR against `$PR_BASE` (creating the PR label if missing).
7. Cleans up the local `release/vX.Y.Z` branch and returns to the starting
   branch.

## Usage

```
create-release [--major|--minor|--patch] [-b branch] [model]
```

With no model argument, `update-changelog` uses its own default
(`opencode/grok-code-fast-1`). Only one model is tried — the argument can
be:

- A full opencode model ID or a fragment of one (e.g. `mimo`, `ling`,
  `grok-code-fast-1`).
- `claude:<model>` — runs via the Claude Code CLI instead of opencode (e.g.
  `claude:haiku`, `claude:sonnet`).
- `codex:<model>` or bare `codex` — runs via the Codex CLI instead of
  opencode (e.g. `codex:gpt-5-codex`).

### Options

| Flag | Description |
| --- | --- |
| `--major`, `--minor`, `--patch` | Force the version bump instead of inferring it from the changelog |
| `-b`, `--back <branch>` | Branch to return to when done (default: `develop`) |
| `-l`, `--list` | List available free opencode models (delegates to `update-changelog --list`) |
| `-h`, `--help` | Show usage help |

### Examples

```
create-release
create-release --patch
create-release --minor mimo
create-release claude:haiku
create-release --patch codex:gpt-5-codex
create-release -b main --minor
```

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `RELEASE_PR_BASE` | `develop` | Base branch for the release PR |
| `RELEASE_PR_LABEL` | `documentation` | Label applied to the release PR (created if missing) |
| `RELEASE_PR_ASSIGNEE` | `@me` | Assignee for the release PR |

## Requirements

- The `gh` CLI, authenticated, for creating the PR.
- A `package.json` in the current directory (its `version` field is bumped).
- A clean working tree — the script refuses to run with uncommitted changes.

## Notes

- Only one model is attempted per run; passing more than one positional
  argument is an error.
- If `[Unreleased]` ends up empty after `update-changelog` runs (no new
  commits, or the model/conflict-resolution step failed), the script exits
  and returns to `$RETURN_TO` without creating a release.
- The version is never inferred from commit messages directly — only from
  what ends up written under `[Unreleased]` in `CHANGELOG.md`.
