# tnr-review

Reviews a GitHub pull request with the `thermo-nuclear-code-quality-review`
skill and an AI agent CLI (Codex, Claude Code or opencode), then posts the
verdict on the PR:

- **Critical findings** → a **Request changes** review listing the fixes
  needed, with inline comments on the affected lines of the diff.
- **No findings, or only non-critical ones** → an **Approve** review with a
  short summary and, if any, the non-blocking findings as warnings.

It always works from a **PR link**. Every run clones the PR's repository into
the current folder, installs its dependencies with `pnpm install`, reviews the
PR head and **deletes the clone when it finishes**.

**Recommended setup:** run it from a blank folder dedicated to reviews, e.g.:

```
mkdir -p ~/reviews && cd ~/reviews
tnr-review https://github.com/org/repo/pull/123
```

A sibling of [tnr-issues](tnr-issues.md), which turns findings on a whole
repository into GitHub issues instead.

## What it does

1. **Checks requirements and the PR** — verifies `git`, `gh`
   (authenticated), `jq`, `pnpm` and the agent CLI, resolves the PR link and
   checks the PR is open. If this exact head commit already has a tnr-review, it stops (see
   [Re-running](#re-running)).
2. **Clones the repository** — downloads the PR diff, then makes a shallow
   clone of the PR's repository (`gh repo clone … --depth=1`) into
   `./<owner>__<repo>-pr-<n>/` and checks out the PR head from
   `refs/pull/<n>/head` (PRs from forks work too).
3. **Installs dependencies** — runs `pnpm install` in the clone, so the
   agent can check the APIs and types of the dependencies the PR uses (see
   [Dependencies](#dependencies)).
4. **Reviews** — runs the skill with the agent, **read-only**, inside that
   clone. The agent reads the diff (`.tnr-review.diff`) plus whatever code
   it needs, and returns structured findings. It's told to report only
   problems the PR introduces or affects, not pre-existing ones.
5. **Decides the verdict** — drops findings under `MIN_CONFIDENCE`. Any
   remaining finding with severity ≥ `--block-on` (default `critical`) is
   **blocking**: one or more means *Request changes*, none means *Approve*.
6. **Composes the review** — builds the Markdown body (verdict, summary,
   the critical fixes needed, and the warnings) and the inline comments.
7. **Posts it** — one GitHub review via
   `POST /repos/{owner}/{repo}/pulls/{number}/reviews`, pinned to the
   reviewed commit.

The clone (including `node_modules`) is deleted when the script exits: after
posting, on errors, and on Ctrl-C. Set `KEEP_CLONE=1` to keep it for
debugging.

## Usage

```
tnr-review [options] [pr-link]
```

`pr-link` is the GitHub PR link (`https://github.com/<owner>/<repo>/pull/<n>`).
Suffixes such as `/files` or `#discussion_r…` are ignored, so you can paste
the link from any tab of the PR.

With no argument in an interactive terminal, the first thing the script does
is ask for the link, and it keeps asking until it gets a valid one:

```
$ tnr-review
? PR link: https://github.com/org/repo/pull/123
```

When it isn't running in a terminal (CI, pipes), it doesn't ask: pass the
link as an argument.

### Options

| Flag | Description |
| --- | --- |
| `-a`, `--agent <name>` | AI CLI to use: `codex`, `claude` or `opencode` (default: `codex`) |
| `-m`, `--model <id>` | Model for the review. Accepts an agent prefix (see [Agents and models](#agents-and-models)) |
| `-e`, `--effort <level>` | Reasoning effort: `low`, `medium`, `high`, `xhigh`. **Codex only** — ignored with a warning for other agents |
| `-b`, `--block-on <sev>` | Lowest severity that requests changes: `critical` (default), `high`, `medium`, `low`, `info` |
| `--dry-run` | Print the review and inline comments instead of posting them |
| `--force` | Review again even if this head commit already has a tnr-review |
| `-h`, `--help` | Show usage help |

### Examples

```
cd ~/reviews
tnr-review                                               # asks for the PR link
tnr-review https://github.com/org/repo/pull/123
tnr-review -a claude -m sonnet --dry-run https://github.com/org/repo/pull/123   # preview only
tnr-review -m claude:opus https://github.com/org/repo/pull/123
tnr-review -m anthropic/claude-sonnet-4-5 https://github.com/org/repo/pull/123  # → opencode
tnr-review -m gpt-5.6-luna -e high --block-on high https://github.com/org/repo/pull/123
```

## Agents and models

Agents and models work the same way as in `tnr-issues` (see
[its Agents and models section](tnr-issues.md#agents-and-models)):

| Agent | CLI | Model format |
| --- | --- | --- |
| Codex | `codex` | Codex model id, lowercased automatically (e.g. `gpt-5.6-luna`) |
| Claude Code | `claude` | Alias (`sonnet`, `opus`, `haiku`) or a full model id |
| opencode | `opencode` | `provider/model` (e.g. `anthropic/claude-sonnet-4-5`) |

- `-a claude` selects the agent; `-m claude:sonnet` selects agent and model at
  once (`codex:`, `claude:`, `opencode:` prefixes); a bare `-m claude` means
  that agent with its default model.
- Without `-a` or a prefix, a model id containing `/` selects opencode;
  anything else selects Codex.
- All agents run read-only: Codex in a read-only sandbox, Claude Code with
  only read tools, opencode with edit, bash and webfetch denied.

The skill is looked up in the same paths as `tnr-issues` (see
[Skill lookup](tnr-issues.md#skill-lookup)).

## Dependencies

All reviewed projects must be **pnpm projects**: the script stops if the
repository has no `package.json` at its root, and warns if there's no
`pnpm-lock.yaml`.

Before the review it runs `pnpm install` in the clone, with the output shown
and saved to `pnpm-install.log`. With dependencies installed, the agent can
read `node_modules` to check the APIs and types the PR uses; it's told not to
review the dependencies themselves.

If `pnpm install` fails (e.g. the PR has an outdated `pnpm-lock.yaml`), the
review still runs. The agent gets the last lines of the install output and is
asked to report the failure as a finding if the PR caused it.

`pnpm install` runs the project's install scripts (`postinstall`, etc.) with
your user's permissions. Only review PRs whose code you're willing to run,
especially PRs from forks.

## Severity and the verdict

The agent is asked to reserve **critical** for problems that would cause real
harm if merged as-is:

- incorrect behavior, crashes, data loss or corruption
- security vulnerabilities
- a broken build or broken tests
- breaking changes without a migration

With the default `--block-on critical`, only those request changes.
Everything else (high, medium, low) goes in the review as non-blocking
warnings and the PR is approved. Use `--block-on high` for a stricter gate.

`info` findings are left out of the review unless you lower `MIN_SEVERITY`
to `info`.

## What gets posted

**Request changes:**

```markdown
## ❌ Changes requested

<summary of the PR>

### 🚫 Critical fixes needed (2)

#### 1. <title>

[`src/db.ts` (lines 40–52)](<link to those lines at the PR head>) · **critical** · security · confidence 0.9

**Problem:** …
**Impact:** …
**Required fix:** …

<details><summary>⚠️ Non-blocking findings (3)</summary> … </details>
```

Each blocking finding whose lines are **inside the diff** also gets an
inline comment on those lines. GitHub only allows inline comments on lines
that appear in the diff, so findings elsewhere (e.g. a broken caller in an
unchanged file) are only in the review body.

**Approve:**

```markdown
## ✅ Approved

<summary of the PR>

<details><summary>⚠️ Non-blocking findings (3)</summary> … </details>
```

or `No issues found.` when there are no findings at all.

Every review ends with a footer naming the agent, model, skill, reviewed
commit and blocking threshold, plus a hidden `<!-- tnr-review:<sha> -->`
marker.

### Fallbacks

If GitHub rejects the review, the script retries:

1. without the inline comments (e.g. a line GitHub doesn't accept), then
2. as a plain **Comment** review with the same body (e.g. no permission to
   approve).

**Your own PRs:** GitHub doesn't allow approving or requesting changes on
your own pull request, so the script detects that upfront and posts the
verdict as a comment, with a note explaining why.

## Re-running

- **Same head commit:** the script finds its marker in the existing reviews
  and stops without spending tokens. Use `--force` to review again.
- **New commits pushed:** the head commit changes, so a new review runs.
- **After a failed post or a `--dry-run`:** the agent's findings are cached in
  the [artifacts folder](#folder-layout), keyed by PR, head commit, agent
  and model. Re-running from the same reviews folder with the same values
  reuses them and skips the clone, the install and the review. Delete that
  folder to force a fresh review.

## Environment variables

Flags take precedence over environment variables.

| Variable | Default | Purpose |
| --- | --- | --- |
| `TNR_AGENT` | `codex` | Agent to use (same as `--agent`) |
| `TNR_MODEL` | — | Model (same as `--model`) |
| `TNR_EFFORT` | — | Codex reasoning effort (same as `--effort`) |
| `BLOCK_ON` | `critical` | Lowest blocking severity (same as `--block-on`) |
| `MIN_SEVERITY` | `low` | Lowest severity listed as a non-blocking warning |
| `MIN_CONFIDENCE` | `0.6` | Findings below this confidence (0.0–1.0) are ignored, including critical ones |
| `REVIEW_LANG` | `English` | Language of the review (e.g. `español`) |
| `DRY_RUN` | `0` | `1`/`true` is the same as `--dry-run` |
| `KEEP_CLONE` | `0` | `1` keeps the clone (with `node_modules`) after the run, for debugging |

## Folder layout

Everything goes inside the folder you run it from:

```
~/reviews/
├── <owner>__<repo>-pr-<n>/        # the clone at the PR head (+ node_modules), deleted on exit
└── .tnr-review/<owner>__<repo>/pr-<n>-<hash>/
    ├── pr.diff                # the PR diff (gh pr diff)
    ├── diff-lines.tsv         # file/line pairs that accept inline comments
    ├── pnpm-install.log       # output of pnpm install
    ├── findings.schema.json   # JSON schema given to the agent
    ├── findings.json          # raw findings from the agent
    ├── selected.json          # findings kept, with a blocking flag
    ├── review.md              # the review body
    ├── comments.json          # inline comments
    ├── payload.json           # what was sent to GitHub
    └── *.log, *.raw           # agent output, useful for debugging
```

The artifacts in `.tnr-review/` are small text files. They stay after the run
so they can be reused and debugged. If the folder you run it from is inside a
git repository, the script warns you, since a dedicated reviews folder is the
intended setup.

## Orca integration

Install it globally once:

```
cp src/tnr-review.sh ~/.local/bin/tnr-review && chmod +x ~/.local/bin/tnr-review
```

Then add a global Orca Quick Command of type "Terminal Command" running
`cd ~/reviews && "$HOME/.local/bin/tnr-review"`. It asks for the PR link
first.

## Requirements

- `git`, `jq`, `pnpm`, and the `gh` CLI, authenticated, with permission to clone the
  repository and review its pull requests.
- The chosen agent CLI: `codex`, `claude` or `opencode`, already logged in.
- The `thermo-nuclear-code-quality-review` skill installed in one of the
  [known paths](tnr-issues.md#skill-lookup).
- Reviewed projects must use pnpm (`package.json` at the root, ideally with
  `pnpm-lock.yaml`).
- bash 3.2 or newer (works with the stock macOS bash).

## Notes

- The script always exits `0` once the review is posted, whatever the
  verdict, so it doesn't fail a Quick Command or CI step because of a
  *Request changes* result.
- Links in the review point to the reviewed commit, so line numbers stay
  correct after later pushes.
- The clone is shallow (`--depth=1`), so the agent sees the code at the PR
  head but not the git history. The PR diff is copied into the clone as
  `.tnr-review.diff`.
- Claude Code prints nothing until it finishes; the script shows a waiting
  message meanwhile.
