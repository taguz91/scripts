#!/usr/bin/env bash
# tnr-review.sh — Orca Quick Command
#   AI agent ($thermo-nuclear-code-quality-review) on a GitHub PR → approve, or request changes with the
#   critical fixes needed (review body + inline comments on the diff).
#
# Every run clones the PR's repository into the current folder, installs its dependencies with
# pnpm, reviews the PR head and deletes the clone when it finishes. Run it from a blank folder
# dedicated to reviews (e.g. ~/reviews).
#
# Usage (from an Orca "Terminal Command" Quick Command or any terminal):
#   Global install (once):       cp tnr-review.sh ~/.local/bin/tnr-review && chmod +x ~/.local/bin/tnr-review
#   Quick Command (global scope): "$HOME/.local/bin/tnr-review"
#
#   tnr-review [options] [pr-link]
#     pr-link                 GitHub PR link; if omitted in a terminal, it asks for it
#     -a, --agent <name>      AI CLI to use: codex | claude | opencode (default: codex)
#     -m, --model <id>        model for the review; accepts an agent prefix
#                             (e.g. gpt-5.6-luna, claude:sonnet, opencode:anthropic/claude-sonnet-4-5);
#                             without -a, a "provider/model" id selects opencode
#     -e, --effort <level>    reasoning effort (low|medium|high|xhigh) — Codex only
#     -b, --block-on <sev>    lowest severity that requests changes (default: critical)
#         --dry-run           print the review instead of posting it
#         --force             review again even if this commit already has a tnr-review
#     -h, --help
#
#   cd ~/reviews
#   tnr-review https://github.com/org/repo/pull/123
#   tnr-review -a claude -m sonnet --dry-run https://github.com/org/repo/pull/123
#   tnr-review -m opencode:anthropic/claude-sonnet-4-5 --block-on high https://github.com/org/repo/pull/123
#
# Optional variables:
#   MIN_SEVERITY=critical|high|medium|low|info (low)   MIN_CONFIDENCE=0.6   BLOCK_ON=critical
#   REVIEW_LANG=English   TNR_AGENT=   TNR_MODEL=   TNR_EFFORT=   KEEP_CLONE=0
#   (flags take precedence over environment variables)
#
# Requires: git, gh (authenticated), jq, pnpm, and the chosen agent CLI (codex, claude or opencode).
# Every reviewed project must be a pnpm project (package.json at its root).
# Compatible with bash 3.2 (macOS).

set -Eeuo pipefail

SKILL="thermo-nuclear-code-quality-review"
AGENTS="codex claude opencode"
MIN_SEVERITY="${MIN_SEVERITY:-low}"
MIN_CONFIDENCE="${MIN_CONFIDENCE:-0.6}"
BLOCK_ON="${BLOCK_ON:-critical}"
REVIEW_LANG="${REVIEW_LANG:-English}"
DRY_RUN="${DRY_RUN:-0}"
FORCE=0
KEEP_CLONE="${KEEP_CLONE:-0}"
AGENT="${TNR_AGENT:-}"
MODEL="${TNR_MODEL:-}"
EFFORT="${TNR_EFFORT:-}"

# ── Step-by-step output ────────────────────────────────────────────────────────

STEP=0
TOTAL=7
SRC=""   # clone of the PR's repository (deleted on exit)

step() { STEP=$((STEP + 1)); printf '\n\033[1;36m━━ [%d/%d] %s\033[0m\n' "$STEP" "$TOTAL" "$*"; }
info() { printf '  \033[2m•\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*" >&2; }
die()  { printf '\n  \033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "failed at line $LINENO (step $STEP/$TOTAL)"' ERR

# Deletes the clone on any exit (success, error or Ctrl-C)
cleanup() {
  if [[ -n "$SRC" && -d "$SRC" ]]; then
    if [[ "$KEEP_CLONE" == "1" ]]; then info "clone kept (KEEP_CLONE=1): $SRC"
    else rm -rf "$SRC" && ok "clone deleted: $SRC"; fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── Utilities ──────────────────────────────────────────────────────────────────

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
sev_rank() { case "$(lower "$1")" in critical) echo 0 ;; high) echo 1 ;; medium) echo 2 ;; low) echo 3 ;; info) echo 4 ;; *) echo -1 ;; esac; }

# Lines of the PR head that GitHub accepts for inline comments: "file<TAB>line" for every added or
# context line inside a diff hunk (RIGHT side).
diff_right_lines() {
  awk '
    /^diff --git / { hdr = 1; file = ""; ln = 0; next }
    hdr && /^\+\+\+ / { f = substr($0, 5); if (f == "/dev/null") file = ""; else { sub(/^b\//, "", f); file = f }; next }
    hdr && !/^@@/ { next }
    /^@@/ { hdr = 0; match($0, /\+[0-9]+/); ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    file != "" && ln > 0 {
      c = substr($0, 1, 1)
      if (c == "+" || c == " ") { print file "\t" ln; ln++ }
    }
  ' "$1"
}

# ── AI agents ──────────────────────────────────────────────────────────────────

is_agent() { [[ " $AGENTS " == *" $1 "* ]]; }
agent_name() {
  case "$1" in codex) echo Codex ;; claude) echo "Claude Code" ;; opencode) echo opencode ;; esac
}
model_hint() {
  case "$1" in
    codex)    echo "check the id with 'codex' → /model (e.g. gpt-5.6-luna)" ;;
    claude)   echo "use an alias (sonnet, opus, haiku) or a full model id" ;;
    opencode) echo "list ids with 'opencode models' (format provider/model)" ;;
  esac
}

# Extracts a JSON object from free text (stdin): the whole text, a ```json block, or the outermost {…}.
extract_json() {
  local txt; txt="$(cat)"
  if jq -e 'type == "object"' <<< "$txt" >/dev/null 2>&1; then printf '%s\n' "$txt"; return; fi
  local fenced
  fenced="$(awk '/^[ \t]*```/ { if (inb) exit; inb=1; next } inb' <<< "$txt")"
  if jq -e 'type == "object"' <<< "$fenced" >/dev/null 2>&1; then printf '%s\n' "$fenced"; return; fi
  awk '{ s = s $0 "\n" } END {
    i = index(s, "{"); j = 0
    for (k = length(s); k > i; k--) if (substr(s, k, 1) == "}") { j = k; break }
    if (i && j) print substr(s, i, j - i + 1)
  }' <<< "$txt"
}

# Runs the agent read-only (in the current directory) and leaves a JSON object matching the schema in $4.
agent_json() { # $1 agent  $2 model(optional)  $3 schema  $4 output  $5 prompt
  local agent="$1" model="$2" schema="$3" out="$4" prompt="$5"
  local log="$out.log" raw="$out.raw" rc=0
  rm -f "$out"
  case "$agent" in
    codex)
      local args=(exec --sandbox read-only --output-schema "$schema" -o "$out" --color never)
      if [[ -n "$model" ]]; then args+=(-m "$model"); fi
      if [[ -n "$EFFORT" ]]; then args+=(-c "model_reasoning_effort=\"$EFFORT\""); fi
      codex "${args[@]}" "$prompt" </dev/null 2>&1 | tee "$log" || rc=$?
      ;;
    claude)
      local args=(-p --output-format json --json-schema "$(cat "$schema")"
                  --allowedTools "Read,Grep,Glob,Skill"
                  --disallowedTools "Edit,Write,MultiEdit,NotebookEdit,Bash")
      if [[ -n "$model" ]]; then args+=(--model "$model"); fi
      if [[ -n "$SKILL_PATH" ]]; then args+=(--add-dir "$SKILL_PATH"); fi
      info "waiting for Claude Code (output is shown when it finishes)…"
      claude "${args[@]}" "$prompt" </dev/null >"$raw" 2>"$log" || rc=$?
      cat "$raw" >> "$log"
      if (( rc == 0 )); then
        if jq -e '.is_error == true' "$raw" >/dev/null 2>&1; then
          rc=1; jq -r '.result // empty' "$raw" >&2
        elif ! jq -e '.structured_output | objects' "$raw" > "$out" 2>/dev/null; then
          jq -r '.result // empty' "$raw" | extract_json > "$out"
        fi
      else
        cat "$log" >&2
      fi
      ;;
    opencode)
      local args=(run)
      if [[ -n "$model" ]]; then args+=(-m "$model"); fi
      prompt="$prompt

Reply ONLY with a JSON object that validates against this JSON Schema (no prose, no code fences):
$(cat "$schema")"
      OPENCODE_PERMISSION='{"edit":"deny","bash":"deny","webfetch":"deny","external_directory":"allow"}' \
        opencode "${args[@]}" "$prompt" </dev/null 2>"$log" | tee "$raw" || rc=$?
      cat "$raw" >> "$log"
      if (( rc == 0 )); then extract_json < "$raw" > "$out"; else cat "$log" >&2; fi
      ;;
  esac
  if (( rc != 0 )); then
    if grep -qiE 'model.*(not (found|supported|exist|available)|unknown|invalid|does not)|unknown model|ProviderModelNotFound' "$log"; then
      die "$(agent_name "$agent") rejected the model '${model:-default}'. $(model_hint "$agent")."
    fi
    return 1
  fi
  jq -e 'type == "object"' "$out" >/dev/null 2>&1
}

usage() { sed -n '2,40p' "$0" | sed -n '/^#   tnr-review \[/,/^#   (flags take/p' | sed 's/^# \{0,1\}//'; }

# ── Arguments ──────────────────────────────────────────────────────────────────

need() { [[ $2 -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }; }
PR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--agent)      need "$1" $#; AGENT="$2"; shift 2 ;;
    --agent=*)       AGENT="${1#*=}"; shift ;;
    -m|--model)      need "$1" $#; MODEL="$2"; shift 2 ;;
    --model=*)       MODEL="${1#*=}"; shift ;;
    -e|--effort)     need "$1" $#; EFFORT="$2"; shift 2 ;;
    --effort=*)      EFFORT="${1#*=}"; shift ;;
    -b|--block-on)   need "$1" $#; BLOCK_ON="$2"; shift 2 ;;
    --block-on=*)    BLOCK_ON="${1#*=}"; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --force)         FORCE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*)              echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)               [[ -z "$PR" ]] || { echo "only one PR at a time" >&2; exit 2; }; PR="$1"; shift ;;
  esac
done
# The PR link is required: ask for it first when running in a terminal
PR_LINK_RE='^https://github\.com/[^/]+/[^/]+/pull/[0-9]+'
if [[ -z "$PR" && -t 0 ]]; then
  while :; do
    printf '\033[1;36m?\033[0m PR link: '
    read -r PR || exit 2
    PR="$(printf '%s' "$PR" | tr -d '[:space:]')"
    if [[ "$PR" =~ $PR_LINK_RE ]]; then break; fi
    [[ -z "$PR" ]] || printf '  \033[33m⚠\033[0m not a GitHub PR link (https://github.com/<owner>/<repo>/pull/<number>)\n'
  done
fi
if [[ ! "$PR" =~ $PR_LINK_RE ]]; then
  echo "pass the GitHub PR link (e.g. tnr-review https://github.com/org/repo/pull/123)" >&2; exit 2
fi
PR="${BASH_REMATCH[0]}"   # drops suffixes like /files or #discussion_r…
BLOCK_ON="$(lower "$BLOCK_ON")"; MIN_SEVERITY="$(lower "$MIN_SEVERITY")"
[[ "$(sev_rank "$BLOCK_ON")" -ge 0 ]] || { echo "invalid --block-on: $BLOCK_ON (critical|high|medium|low|info)" >&2; exit 2; }
[[ "$(sev_rank "$MIN_SEVERITY")" -ge 0 ]] || { echo "invalid MIN_SEVERITY: $MIN_SEVERITY" >&2; exit 2; }

# "claude:sonnet" → agent claude + model sonnet; bare "claude" → agent claude + default model.
# Only known agent names count as a prefix (opencode ids like "openrouter/x:free" contain ':').
AGENT="$(lower "$AGENT")"
MODEL_AGENT=""
if is_agent "$MODEL"; then MODEL_AGENT="$MODEL"; MODEL=""
elif [[ "$MODEL" == *:* ]] && is_agent "${MODEL%%:*}"; then MODEL_AGENT="${MODEL%%:*}"; MODEL="${MODEL#*:}"; fi
if [[ -n "$AGENT" && -n "$MODEL_AGENT" && "$AGENT" != "$MODEL_AGENT" ]]; then
  echo "--agent '$AGENT' conflicts with the model prefix '$MODEL_AGENT:'" >&2; exit 2
fi
AGENT="${MODEL_AGENT:-$AGENT}"
# No agent given: "provider/model" ids are opencode's format, anything else goes to Codex.
if [[ -z "$AGENT" ]]; then
  if [[ "$MODEL" == */* ]]; then AGENT=opencode; else AGENT=codex; fi
fi
is_agent "$AGENT" || { echo "unknown agent: $AGENT (use: ${AGENTS// /, })" >&2; exit 2; }
# Codex model ids are lowercase ("GPT-5.6-Luna" → "gpt-5.6-luna")
if [[ "$AGENT" == codex ]]; then MODEL="$(lower "$MODEL")"; fi

# ── 1. Requirements and pull request ───────────────────────────────────────────

step "Checking requirements and the pull request"
for bin in git gh jq pnpm "$AGENT"; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is not in the PATH"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
if [[ -n "$EFFORT" && "$AGENT" != codex ]]; then
  warn "--effort only applies to Codex; it is ignored for $(agent_name "$AGENT")."
fi

PR_ERR="$(mktemp)"
PR_JSON="$(gh pr view "$PR" --json number,url,title,state,isDraft,author,headRefName,headRefOid,baseRefName </dev/null 2>"$PR_ERR")" \
  || die "could not find the pull request '$PR': $(head -n1 "$PR_ERR")"
rm -f "$PR_ERR"
pr() { jq -r "$1" <<< "$PR_JSON"; }
NUMBER="$(pr .number)"; PR_URL="$(pr .url)"; TITLE="$(pr .title)"; AUTHOR="$(pr .author.login)"
SHA="$(pr .headRefOid)"; HEAD_REF="$(pr .headRefName)"; BASE_REF="$(pr .baseRefName)"
REPO="$(printf '%s' "$PR_URL" | sed -E 's#^https://[^/]+/([^/]+/[^/]+)/pull/.*#\1#')"
[[ "$(pr .state)" == "OPEN" ]] || die "PR #$NUMBER is $(lower "$(pr .state)"), not open"
if [[ "$(pr .isDraft)" == "true" ]]; then warn "PR #$NUMBER is a draft"; fi
ok "$REPO#$NUMBER: $TITLE"
ok "$HEAD_REF → $BASE_REF · head ${SHA:0:10} · author @$AUTHOR"

MARKER="<!-- tnr-review:$SHA -->"
if (( ! FORCE )); then
  previous="$(gh api --paginate "repos/$REPO/pulls/$NUMBER/reviews" \
    -q ".[] | select(.body | contains(\"$MARKER\")) | .html_url" </dev/null 2>/dev/null | head -n1 || true)"
  if [[ -n "$previous" ]]; then
    ok "commit ${SHA:0:10} was already reviewed: $previous"
    info "push new commits, or re-run with --force to review it again"
    exit 0
  fi
fi

ME="$(gh api user -q .login </dev/null 2>/dev/null || true)"
SELF_REVIEW=0
if [[ -n "$ME" && "$(lower "$ME")" == "$(lower "$AUTHOR")" ]]; then
  SELF_REVIEW=1
  warn "you are the PR author: GitHub doesn't allow approving or requesting changes on your own PR, so the verdict will be posted as a comment"
fi

RUN_ID="pr-$NUMBER-$(printf '%s|%s|%s' "$SHA" "$AGENT" "$MODEL" | git hash-object --stdin | cut -c1-10)"
# Everything lives in the current (reviews) folder: the clone is deleted at the end, while the
# review artifacts (findings, review body, logs) stay in .tnr-review/ to resume or debug.
REVIEWS_DIR="$PWD"
if git -C "$REVIEWS_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  warn "the current folder is inside a git repository; better run tnr-review from a blank folder dedicated to reviews"
fi
WORK="$REVIEWS_DIR/.tnr-review/${REPO//\//__}/$RUN_ID"
mkdir -p "$WORK"
ok "review: $(agent_name "$AGENT") (${MODEL:-default model})${EFFORT:+ · effort $EFFORT} · blocks on ≥ $BLOCK_ON"
ok "artifacts: .tnr-review/${REPO//\//__}/$RUN_ID"

# ── 2. Clone ───────────────────────────────────────────────────────────────────

step "Cloning $REPO and checking out the PR head"
DIFF="$WORK/pr.diff"
gh pr diff "$PR_URL" </dev/null > "$DIFF" || die "could not download the diff of PR #$NUMBER"
diff_right_lines "$DIFF" > "$WORK/diff-lines.tsv"
ok "$(grep -c '^diff --git ' "$DIFF" || true) files changed"

FINDINGS="$WORK/findings.json"
if jq -e '.findings' "$FINDINGS" >/dev/null 2>&1; then
  ok "previous review found; no clone needed"
else
  # Shallow clone of the base repository + the PR head (refs/pull/N/head also covers PRs from forks)
  SRC="$REVIEWS_DIR/${REPO//\//__}-pr-$NUMBER"
  if [[ -e "$SRC" ]]; then warn "removing a leftover clone: $SRC"; rm -rf "$SRC"; fi
  info "cloning into ${SRC#"$REVIEWS_DIR"/}…"
  gh repo clone "$REPO" "$SRC" -- --quiet --depth=1 --no-checkout --no-tags </dev/null \
    || die "could not clone $REPO"
  git -C "$SRC" fetch --quiet --depth=1 origin "refs/pull/$NUMBER/head" </dev/null \
    || die "could not fetch the head of PR #$NUMBER"
  FETCHED="$(git -C "$SRC" rev-parse FETCH_HEAD)"
  [[ "$FETCHED" == "$SHA" ]] || die "PR #$NUMBER was updated while starting (head is now ${FETCHED:0:10}); run it again"
  git -C "$SRC" checkout --quiet --detach FETCH_HEAD || die "could not check out ${SHA:0:10}"
  cp "$DIFF" "$SRC/.tnr-review.diff"   # inside the clone so every agent can read it
  ok "PR head ${SHA:0:10} checked out in ${SRC#"$REVIEWS_DIR"/}$([[ "$KEEP_CLONE" == "1" ]] && echo " (kept after the run)" || true)"

  SKILL_PATH=""
  for d in "$SRC/.agents/skills" "$SRC/.codex/skills" "$SRC/.claude/skills" "$SRC/.opencode/skill" "$SRC/.opencode/skills" \
           "${CODEX_HOME:-$HOME/.codex}/skills" "$HOME/.claude/skills" "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skill" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" "$HOME/.agents/skills"; do
    if [[ -f "$d/$SKILL/SKILL.md" ]]; then SKILL_PATH="$d/$SKILL"; break; fi
  done
  if [[ -n "$SKILL_PATH" ]]; then ok "skill: $SKILL_PATH"; else warn "could not find $SKILL in known paths; the agent may not load it"; fi

  # How to invoke the skill: Codex uses $name; other agents get the path to SKILL.md as a fallback.
  if [[ "$AGENT" == codex ]]; then SKILL_REF="the skill \$$SKILL"
  else SKILL_REF="the \`$SKILL\` skill"; fi
  if [[ -n "$SKILL_PATH" ]]; then
    SKILL_REF="$SKILL_REF (its instructions are in '$SKILL_PATH/SKILL.md'; read them first if the skill is not loaded automatically)"
  fi
fi

# ── 3. Dependencies ────────────────────────────────────────────────────────────

step "Installing dependencies with pnpm"
INSTALL_NOTE=""
if [[ -z "$SRC" ]]; then
  ok "previous review found; nothing to install"
else
  [[ -f "$SRC/package.json" ]] || die "$REPO has no package.json at its root; tnr-review only reviews pnpm projects"
  [[ -f "$SRC/pnpm-lock.yaml" ]] || warn "no pnpm-lock.yaml in the PR head; installing without a lockfile"
  if ( cd "$SRC" && pnpm install </dev/null 2>&1 | tee "$WORK/pnpm-install.log" ); then
    ok "dependencies installed"
  else
    warn "pnpm install failed (see $WORK/pnpm-install.log); reviewing anyway"
    INSTALL_NOTE="
Note: 'pnpm install' FAILED on the PR head, so node_modules may be missing or incomplete. Last lines of its output:
$(tail -n 15 "$WORK/pnpm-install.log")
If the failure is caused by this PR (e.g. an outdated pnpm-lock.yaml or a broken dependency), report it as a finding."
  fi
fi

# ── 4. Review ──────────────────────────────────────────────────────────────────

step "Reviewing PR #$NUMBER with $(agent_name "$AGENT") (read-only)"
if jq -e '.findings' "$FINDINGS" >/dev/null 2>&1; then
  ok "reusing previous review ($(jq '.findings | length' "$FINDINGS") findings)"
else
  cat > "$WORK/findings.schema.json" <<'JSON'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["summary", "findings"],
  "properties": {
    "summary": { "type": "string" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["title", "severity", "category", "file", "startLine", "endLine", "problem",
                     "impact", "recommendation", "confidence"],
        "properties": {
          "title": { "type": "string" },
          "severity": { "type": "string", "enum": ["critical", "high", "medium", "low", "info"] },
          "category": { "type": "string" },
          "file": { "type": "string" },
          "startLine": { "type": "integer" },
          "endLine": { "type": "integer" },
          "problem": { "type": "string" },
          "impact": { "type": "string" },
          "recommendation": { "type": "string" },
          "confidence": { "type": "number" }
        }
      }
    }
  }
}
JSON
  REVIEW_PROMPT="Run $SKILL_REF as a pull request review.

Pull request #$NUMBER: \"$TITLE\" ($HEAD_REF → $BASE_REF).
The working tree is checked out at the PR head. The PR's unified diff is in '.tnr-review.diff' at the repository root; read it first.

Rules:
- Do NOT modify any file; only analyze.
- Review the code added or changed by this PR, and its direct consequences on unchanged code (e.g. broken callers).
  Do NOT report pre-existing problems the PR doesn't touch.
- severity:
  - critical: must be fixed before merging — incorrect behavior, crashes, data loss or corruption, security
    vulnerabilities, broken build or tests, breaking changes without migration.
  - high: serious problem that should be fixed soon but doesn't break anything by itself.
  - medium/low: maintainability, readability, minor inefficiencies.
  - info: suggestions and nitpicks.
  Be strict about 'critical': only use it when merging as-is would cause real harm.
- One finding per distinct problem.
- file: path relative to the repository root as git sees it (no './').
- startLine/endLine: 1-based lines in the PR head version that bound the affected code; 0 and 0 if it is file-level.
- recommendation: the concrete fix needed.
- confidence: 0.0-1.0, how sure you are that it is a real problem.
- summary: overall assessment of the PR in 2-3 sentences.
- If you find nothing, return an empty findings array.
- Dependencies are installed in node_modules; you may read them to check APIs and types, but don't review them.
Write all text in $REVIEW_LANG.$INSTALL_NOTE"
  ( cd "$SRC" && agent_json "$AGENT" "$MODEL" "$WORK/findings.schema.json" "$FINDINGS" "$REVIEW_PROMPT" ) \
    && jq -e '.findings | arrays' "$FINDINGS" >/dev/null 2>&1 \
    || die "$(agent_name "$AGENT") did not return valid JSON (see the output above and $FINDINGS.log)"
  ok "$(jq '.findings | length' "$FINDINGS") findings"
fi
SUMMARY="$(jq -r '.summary' "$FINDINGS")"
info "$SUMMARY"

# ── 5. Verdict ─────────────────────────────────────────────────────────────────

step "Deciding the verdict (blocking: severity ≥ $BLOCK_ON, confidence ≥ $MIN_CONFIDENCE)"
SELECTED="$WORK/selected.json"
jq --arg minsev "$MIN_SEVERITY" --arg block "$BLOCK_ON" --argjson minconf "$MIN_CONFIDENCE" '
  def rank: ({"critical":0,"high":1,"medium":2,"low":3,"info":4}[ascii_downcase] // 4);
  [ .findings[]
    | .file |= ltrimstr("./")
    | .severity |= ascii_downcase
    | select(.confidence >= $minconf)
    | .blocking = ((.severity | rank) <= ($block | rank))
    | select(.blocking or (.severity | rank) <= ($minsev | rank)) ]
  | sort_by([(.severity | rank), -.confidence])
' "$FINDINGS" > "$SELECTED"
BLOCKING="$(jq '[.[] | select(.blocking)] | length' "$SELECTED")"
WARNINGS="$(jq '[.[] | select(.blocking | not)] | length' "$SELECTED")"
if (( BLOCKING > 0 )); then
  VERDICT="REQUEST_CHANGES"
  printf '  \033[1;31m✖ changes requested\033[0m — %s blocking, %s non-blocking\n' "$BLOCKING" "$WARNINGS"
else
  VERDICT="APPROVE"
  printf '  \033[1;32m✔ approved\033[0m — %s non-blocking findings\n' "$WARNINGS"
fi

# ── 6. Compose the review ──────────────────────────────────────────────────────

step "Composing the review"
EVENT="$VERDICT"
SELF_NOTE=""
if (( SELF_REVIEW )); then
  EVENT="COMMENT"
  SELF_NOTE="Posted as a comment because GitHub doesn't allow reviewing your own pull request."
fi
FOOTER="<sub>🤖 tnr-review · $(agent_name "$AGENT")${MODEL:+ ($MODEL)} · skill \`$SKILL\` · commit \`${SHA:0:10}\` · blocks on ≥ $BLOCK_ON</sub>"

jq -r --arg verdict "$VERDICT" --arg repo "$REPO" --arg sha "$SHA" --arg summary "$SUMMARY" \
      --arg note "$SELF_NOTE" --arg footer "$FOOTER" --arg marker "$MARKER" '
  def loc: if .startLine > 0 then (if .endLine > .startLine then " (lines \(.startLine)–\(.endLine))" else " (line \(.startLine))" end) else "" end;
  def anchor: if .startLine > 0 then (if .endLine > .startLine then "#L\(.startLine)-L\(.endLine)" else "#L\(.startLine)" end) else "" end;
  def where: "[`\(.file)`\(loc)](https://github.com/\($repo)/blob/\($sha)/\(.file)\(anchor))";
  map(select(.blocking)) as $b | map(select(.blocking | not)) as $w |
  [ (if $verdict == "REQUEST_CHANGES" then "## ❌ Changes requested" else "## ✅ Approved" end),
    "",
    $summary,
    (if $note != "" then ("", "> " + $note) else empty end),
    (if ($b | length) > 0 then
       ("", "### 🚫 Critical fixes needed (\($b | length))", "",
        ($b | to_entries[] | .key as $k | .value |
          ("#### \($k + 1). \(.title)", "",
           "\(where) · **\(.severity)** · \(.category) · confidence \(.confidence)", "",
           "**Problem:** \(.problem)", "",
           "**Impact:** \(.impact)", "",
           "**Required fix:** \(.recommendation)", "")))
     else empty end),
    (if ($w | length) > 0 then
       ("", "<details><summary>⚠️ Non-blocking findings (\($w | length))</summary>", "",
        ($w[] | "- **\(.severity)** · \(where) — **\(.title)**: \(.problem) _Suggestion:_ \(.recommendation)"),
        "", "</details>")
     elif ($b | length) == 0 then ("", "No issues found.")
     else empty end),
    "", "---", $footer, $marker ] | .[]
' "$SELECTED" > "$WORK/review.md"

# Inline comments for blocking findings whose lines are part of the diff
jq --rawfile lines "$WORK/diff-lines.tsv" '
  (reduce ($lines | split("\n") | map(select(length > 0)))[] as $l ({}; .[$l] = true)) as $ok |
  def valid($f; $n): $n > 0 and ($ok["\($f)\t\($n)"] // false);
  [ .[] | select(.blocking) | . as $x
    | (if valid($x.file; $x.endLine) then $x.endLine elif valid($x.file; $x.startLine) then $x.startLine else 0 end) as $line
    | select($line > 0)
    | { path: $x.file, line: $line, side: "RIGHT",
        body: "**🚫 \($x.severity): \($x.title)**\n\n\($x.problem)\n\n**Required fix:** \($x.recommendation)" }
      + (if $x.startLine > 0 and $x.startLine < $line and valid($x.file; $x.startLine)
         then { start_line: $x.startLine, start_side: "RIGHT" } else {} end) ]
' "$SELECTED" > "$WORK/comments.json"
INLINE="$(jq length "$WORK/comments.json")"
ok "review body: $WORK/review.md · $INLINE inline comments"

if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
  printf '\n\033[1;33mDRY_RUN:\033[0m would post a %s review on %s\n\n' "$EVENT" "$PR_URL"
  cat "$WORK/review.md"
  if (( INLINE > 0 )); then
    printf '\n\033[2mInline comments:\033[0m\n'
    jq -r '.[] | "  \(.path):\(.start_line // .line)\(if .start_line then "-\(.line)" else "" end)  \(.body | split("\n")[0])"' "$WORK/comments.json"
  fi
  exit 0
fi

# ── 7. Post the review ─────────────────────────────────────────────────────────

step "Posting the review on PR #$NUMBER"
# Tries the full review first, then without inline comments, then as a plain comment.
post_review() { # $1 event  $2 comments file
  jq -n --arg event "$1" --arg sha "$SHA" --rawfile body "$WORK/review.md" --slurpfile c "$2" \
    '{ event: $event, commit_id: $sha, body: $body, comments: $c[0] }' > "$WORK/payload.json"
  gh api -X POST "repos/$REPO/pulls/$NUMBER/reviews" --input "$WORK/payload.json" -q .html_url </dev/null 2>"$WORK/gh.err"
}
echo '[]' > "$WORK/no-comments.json"
if url="$(post_review "$EVENT" "$WORK/comments.json")"; then :
elif (( INLINE > 0 )) && { warn "inline comments rejected ($(head -n1 "$WORK/gh.err")); posting without them"; \
                           url="$(post_review "$EVENT" "$WORK/no-comments.json")"; }; then :
elif [[ "$EVENT" != "COMMENT" ]] && { warn "could not post a $EVENT review ($(head -n1 "$WORK/gh.err")); posting as a comment"; \
                                      url="$(post_review COMMENT "$WORK/no-comments.json")"; }; then EVENT="COMMENT"
else
  die "could not post the review: $(head -n1 "$WORK/gh.err")"
fi
ok "$EVENT → $url"
