# tnr-issues

Runs the `thermo-nuclear-code-quality-review` skill over a repository with an
AI agent CLI (Codex, Claude Code or opencode), writes one Markdown issue file
per finding, and opens them as GitHub issues assigned to the right owners.
Designed to run as an Orca Quick Command,
but works from any terminal inside a git worktree.

## What it does

1. **Checks requirements and context** — verifies `git`, `gh` (authenticated),
   `jq` and the chosen agent CLI are available, then detects the repo, the
   current branch and commit, and whether they're published on the remote.
   Creates a working directory at `.tnr-issues/<RUN_ID>/` (added to
   `.git/info/exclude` so it never gets committed).
2. **Reviews the code** — runs the skill with the agent, **read-only**, over
   the requested scope. The agent returns structured JSON findings
   (title, severity, category, file, line range, problem, evidence, impact,
   recommendation, acceptance criteria, confidence).
3. **Filters and prioritizes** — keeps findings with severity ≥
   `MIN_SEVERITY` and confidence ≥ `MIN_CONFIDENCE`, sorts them by severity
   then confidence, keeps at most `MAX_ISSUES`, and numbers them `F-001`,
   `F-002`, …
4. **Drafts one issue file per finding** — asks the agent (optionally a
   different model, see `--draft-model`) to write a title and body, then
   saves `.tnr-issues/<RUN_ID>/issues/F-XXX.md` with front matter (title,
   labels, assignees, fingerprint), a location header with a GitHub link to
   the exact lines, and a footer with the metadata.
5. **Ensures labels exist** — creates any missing labels (`code-quality`,
   `severity:*`, `category:*`, plus `EXTRA_LABELS`) with fixed colors.
6. **Creates the issues** — one `gh issue create` per `.md` file, with its
   labels and assignees. If assignment fails (e.g. the user isn't a
   collaborator), the issue is created unassigned instead.
7. **Prints a summary** — how many issues were created vs. already existed,
   with their URLs.

With `--dry-run`, it stops after step 4 so you can review and edit the `.md`
files before anything is published.

## Usage

```
tnr-issues [options] [scope...]
```

`scope` is free text passed to the agent describing what to review — a path,
several paths, or a description. Defaults to `the entire repository`.

### Options

| Flag | Description |
| --- | --- |
| `-a`, `--agent <name>` | AI CLI to use: `codex`, `claude` or `opencode` (default: `codex`) |
| `-m`, `--model <id>` | Model for the review and drafting. Accepts an agent prefix (see [Agents and models](#agents-and-models)) |
| `--draft-model <id>` | Different model only for drafting the issues (default: `--model`). Also accepts an agent prefix |
| `-e`, `--effort <level>` | Reasoning effort: `low`, `medium`, `high`, `xhigh`. **Codex only** — ignored with a warning for other agents |
| `--dry-run` | Stop after generating the `.md` files |
| `-h`, `--help` | Show usage help |

### Examples

```
tnr-issues                                            # Codex, default model, whole repo
tnr-issues -m gpt-5.6-luna "the entire repository"
tnr-issues -a claude -m sonnet src/search
tnr-issues -m claude:opus --draft-model claude:haiku src/api
tnr-issues -m codex:gpt-5.6-luna --draft-model claude:haiku
tnr-issues -m anthropic/claude-sonnet-4-5 src/search  # provider/model → opencode
tnr-issues -m gpt-5.6-luna -e high src/core
```

## Agents and models

| Agent | CLI | Model format | How it runs read-only |
| --- | --- | --- | --- |
| Codex | `codex` | Codex model id, lowercased automatically (e.g. `gpt-5.6-luna`) | `codex exec --sandbox read-only --output-schema …` |
| Claude Code | `claude` | Alias (`sonnet`, `opus`, `haiku`) or a full model id | `claude -p --output-format json --json-schema …`, only `Read`, `Grep`, `Glob` and `Skill` tools allowed |
| opencode | `opencode` | `provider/model` (e.g. `anthropic/claude-sonnet-4-5`) | `opencode run -m …` with `edit`, `bash` and `webfetch` denied; the JSON schema is included in the prompt |

How the agent is chosen:

- `-a claude` selects the agent explicitly.
- `-m claude:sonnet` selects agent and model at once. The prefixes are
  `codex:`, `claude:` and `opencode:`; a bare `-m claude` means that agent
  with its default model.
- Without `-a` or a prefix, a model id containing `/` selects opencode;
  anything else selects Codex.
- `-a` and a conflicting prefix (e.g. `-a claude -m codex:gpt-5`) is an error.
- `--draft-model` without a prefix uses the same agent as the review.
- With no model, each CLI uses its own configured default
  (`~/.codex/config.toml`, Claude Code settings, opencode config).

If the agent rejects the model id, the script stops with a hint on how to
list valid ids for that agent.

### Skill lookup

The script looks for `thermo-nuclear-code-quality-review/SKILL.md` in, in
order:

- Project: `.agents/skills`, `.codex/skills`, `.claude/skills`,
  `.opencode/skill`, `.opencode/skills`
- User: `$CODEX_HOME/skills` (`~/.codex/skills`), `~/.claude/skills`,
  `~/.config/opencode/skill`, `~/.config/opencode/skills`, `~/.agents/skills`

Codex invokes it as `$thermo-nuclear-code-quality-review`. Claude Code and
opencode are also given the path to `SKILL.md` so they can read it if the
skill isn't loaded automatically. If the skill isn't found anywhere, the
script warns and continues.

## Environment variables

Flags take precedence over environment variables.

| Variable | Default | Purpose |
| --- | --- | --- |
| `TNR_AGENT` | `codex` | Agent to use (same as `--agent`) |
| `TNR_MODEL` | — | Model (same as `--model`) |
| `TNR_DRAFT_MODEL` | `TNR_MODEL` | Drafting model (same as `--draft-model`) |
| `TNR_EFFORT` | — | Codex reasoning effort (same as `--effort`) |
| `MIN_SEVERITY` | `low` | Lowest severity to keep: `critical`, `high`, `medium`, `low`, `info` |
| `MIN_CONFIDENCE` | `0.6` | Lowest agent confidence (0.0–1.0) to keep |
| `MAX_ISSUES` | `20` | Maximum number of issues per run |
| `ISSUE_LANG` | `English` | Language of the findings and issues (e.g. `español`) |
| `EXTRA_LABELS` | — | Comma-separated labels added to every issue (e.g. `tech-debt,q4`) |
| `ASSIGNEES_FILE` | see [Assignees](#assignees) | Path to the assignment rules file |
| `RUN_ID` | hash of HEAD + scope | Resume a specific run |
| `DRY_RUN` | `0` | `1`/`true` is the same as `--dry-run` |

`CODEX_MODEL`, `CODEX_DRAFT_MODEL` and `CODEX_EFFORT` are still accepted as
fallbacks for the `TNR_*` equivalents.

## Assignees

Each issue's assignees are resolved from the file path of its finding:

1. **Custom rules** — the first matching rule in the assignees file wins. The
   file is `ASSIGNEES_FILE` if set, else `.orca/issue-assignees.properties`
   in the project, else `~/.config/tnr-issues/assignees.properties`.
2. **CODEOWNERS** — if no rule matched and `fallback=codeowners` (the
   default), the last matching line of `.github/CODEOWNERS`, `CODEOWNERS` or
   `docs/CODEOWNERS` wins. Only `@user` owners are used; teams
   (`@org/team`) are skipped.
3. **Default** — the `default=` value from the assignees file, if any.

Assignees file format:

```properties
# glob = users (comma or space separated; leading @ optional; @me allowed)
src/search/** = alice, @bob
src/api/*     = carol
**/*.sql      = dba-lead

# optional settings
fallback = codeowners    # or "none" to skip CODEOWNERS
default  = @me
```

`*` and `**` both match across directories. There's no brace expansion, so use
one line per alternative.

## Resuming and deduplication

- Each run has a `RUN_ID` (hash of the HEAD commit and the scope). Re-running
  with the same HEAD and scope, or with `RUN_ID=<id>`, **resumes** the run:
  - The review isn't repeated if `findings.json` already exists.
  - Existing `issues/F-XXX.md` files are kept as-is, **including your
    edits**; only missing ones are drafted.
  - Issues already recorded in `created.tsv` are skipped.
- Each issue carries a **fingerprint** (`tnr-<hash>` of file, category and
  finding title) in its footer. Before creating an issue, the script searches
  all issues (open and closed) for that fingerprint and reuses the existing
  one instead of creating a duplicate.

The recommended flow is:

```
tnr-issues -m claude:sonnet --dry-run src/search   # review/edit .tnr-issues/<RUN_ID>/issues/*.md
tnr-issues -m claude:sonnet src/search             # same scope + HEAD → resumes and creates issues
```

To start from scratch, delete `.tnr-issues/<RUN_ID>/` (or the whole
`.tnr-issues/` directory).

## Working directory layout

```
.tnr-issues/<RUN_ID>/
├── findings.schema.json   # JSON schema given to the agent for the review
├── findings.json          # raw findings from the review
├── selected.json          # filtered, sorted findings with F-XXX ids
├── draft.schema.json      # JSON schema for each issue draft
├── drafts/F-XXX.json      # agent drafts (title + body)
├── issues/F-XXX.md        # final issue files — edit these during --dry-run
├── created.tsv            # finding id → issue URL → created|reused
└── *.log, *.raw           # agent output, useful for debugging
```

## Orca integration

Install it globally once:

```
cp src/tnr-issues.sh ~/.local/bin/tnr-issues && chmod +x ~/.local/bin/tnr-issues
```

Then add a global Orca Quick Command of type "Terminal Command" running
`"$HOME/.local/bin/tnr-issues"` (with any flags you want). When the `orca`
CLI is available, each step is also posted as a worktree comment
(`tnr-issues: [3/7] …`), so progress shows up in Orca desktop and mobile.

## Requirements

- `git`, `jq`, and the `gh` CLI, authenticated (`gh auth login`).
- The chosen agent CLI(s): `codex`, `claude` and/or `opencode`, already
  logged in.
- The `thermo-nuclear-code-quality-review` skill installed in one of the
  [known paths](#skill-lookup).
- bash 3.2 or newer (works with the stock macOS bash).

## Notes

- The agent never modifies files: Codex runs in a read-only sandbox, Claude
  Code only gets read tools, and opencode has edit and bash denied.
- Claude Code prints nothing until it finishes; the script shows a waiting
  message meanwhile.
- If HEAD isn't pushed, file links point to the default branch instead of the
  commit, so line numbers may not match. If the branch isn't published, the
  issue names it without a link.
- Line ranges are clamped to the file's current length; findings whose file
  doesn't exist are discarded.
- A finding whose draft fails is skipped with a warning. Re-run to retry just
  that one.
