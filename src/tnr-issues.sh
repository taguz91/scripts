#!/usr/bin/env bash
# tnr-issues.sh — Orca Quick Command
#   AI agent ($thermo-nuclear-code-quality-review) → one .md file per finding → assigned GitHub issues.
#
# Usage (from an Orca "Terminal Command" Quick Command or any terminal inside the worktree):
#   Global install (once):       mv tnr-issues.sh ~/.local/bin/tnr-issues && chmod +x ~/.local/bin/tnr-issues
#   Quick Command (global scope): "$HOME/.local/bin/tnr-issues"
#
#   tnr-issues [options] [scope...]
#     -a, --agent <name>      AI CLI to use: codex | claude | opencode (default: codex)
#     -m, --model <id>        model for the review and drafting; accepts an agent prefix
#                             (e.g. gpt-5.6-luna, claude:sonnet, opencode:anthropic/claude-sonnet-4-5);
#                             without -a, a "provider/model" id selects opencode
#         --draft-model <id>  different model only for drafting the issues (default: --model)
#     -e, --effort <level>    reasoning effort (low|medium|high|xhigh) — Codex only
#         --dry-run           stop after generating the .md files
#     -h, --help
#
#   tnr-issues -m gpt-5.6-luna "the entire repository"
#   tnr-issues -a claude -m sonnet src/search
#   tnr-issues -m opencode:anthropic/claude-sonnet-4-5 --dry-run src/search   # review the .md files…
#   tnr-issues -m opencode:anthropic/claude-sonnet-4-5 src/search             # …and re-run: resumes and creates issues
#
# Optional variables:
#   MIN_SEVERITY=critical|high|medium|low|info (low)   MIN_CONFIDENCE=0.6   MAX_ISSUES=20
#   ISSUE_LANG=English   EXTRA_LABELS=tech-debt,q4   TNR_AGENT=   TNR_MODEL=   TNR_DRAFT_MODEL=   TNR_EFFORT=
#   (flags take precedence over environment variables; CODEX_MODEL/CODEX_DRAFT_MODEL/CODEX_EFFORT still work)
#   ASSIGNEES_FILE=.orca/issue-assignees.properties   RUN_ID=<id to resume a specific run>
#
# Requires: git, gh (authenticated), jq, and the chosen agent CLI (codex, claude or opencode).
# Compatible with bash 3.2 (macOS).

set -Eeuo pipefail

SKILL="thermo-nuclear-code-quality-review"
AGENTS="codex claude opencode"
MIN_SEVERITY="${MIN_SEVERITY:-low}"
MIN_CONFIDENCE="${MIN_CONFIDENCE:-0.6}"
MAX_ISSUES="${MAX_ISSUES:-20}"
ISSUE_LANG="${ISSUE_LANG:-English}"
EXTRA_LABELS="${EXTRA_LABELS:-}"
DRY_RUN="${DRY_RUN:-0}"
AGENT="${TNR_AGENT:-}"
MODEL="${TNR_MODEL:-${CODEX_MODEL:-}}"
DRAFT_MODEL="${TNR_DRAFT_MODEL:-${CODEX_DRAFT_MODEL:-}}"
EFFORT="${TNR_EFFORT:-${CODEX_EFFORT:-}}"
ASSIGNEES_FILE="${ASSIGNEES_FILE:-}"   # empty = the project's .orca/issue-assignees.properties or ~/.config/tnr-issues/assignees.properties

# ── Step-by-step output (+ checkpoints visible in Orca desktop/mobile) ─────────

STEP=0
TOTAL=7
ROOT=""

checkpoint() {
  if [[ -n "$ROOT" ]] && command -v orca >/dev/null 2>&1; then
    orca worktree set --worktree "path:$ROOT" --comment "tnr-issues: $*" --json >/dev/null 2>&1 || true
  fi
}
step() { STEP=$((STEP + 1)); printf '\n\033[1;36m━━ [%d/%d] %s\033[0m\n' "$STEP" "$TOTAL" "$*"; checkpoint "[$STEP/$TOTAL] $*"; }
info() { printf '  \033[2m•\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*" >&2; }
die()  { printf '\n  \033[31m✖ %s\033[0m\n' "$*" >&2; checkpoint "✖ $*"; exit 1; }
trap 'die "failed at line $LINENO (step $STEP/$TOTAL)"' ERR

# ── Utilities ──────────────────────────────────────────────────────────────────

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
slug() { lower "$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-50; }

# "a, @b c" → "a,b"  (keeps @me)
norm_owners() {
  local o out=""
  for o in $(printf '%s' "$1" | tr ',' ' '); do
    [[ "$o" == "@me" ]] || o="${o#@}"
    [[ -n "$o" ]] && out="${out:+$out,}$o"
  done
  printf '%s' "$out"
}

# Simple glob: ** and * cross directories. For alternatives use several lines (no braces).
glob_match() { local pat="${1//\*\*/*}"; [[ "$2" == $pat ]]; }

# Approximation of CODEOWNERS semantics (gitignore style).
codeowners_match() {
  local p="$1" f="$2" anchored=0
  if [[ "$p" == /* || "${p%/}" == */* ]]; then anchored=1; fi
  p="${p#/}"
  p="${p//\*\*/*}"
  if [[ "$p" == "*" ]]; then return 0; fi
  if [[ "$p" == */ ]]; then p="${p}*"; fi
  if (( anchored )); then
    [[ "$f" == $p || "$f" == $p/* ]]
  else
    [[ "$f" == $p || "$f" == */$p || "$f" == $p/* || "$f" == */$p/* ]]
  fi
}

# Custom rules (first match wins) → CODEOWNERS (last match wins, @users only) → default.
resolve_assignees() {
  local f="$1" line key val fallback="codeowners" default=""
  if [[ -f "$ASSIGNEES_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      if [[ "$line" != *=* ]]; then continue; fi
      key="$(trim "${line%%=*}")"
      val="$(trim "${line#*=}")"
      case "$key" in
        fallback) fallback="$(lower "$val")" ;;
        default)  default="$val" ;;
        *) if glob_match "$key" "$f"; then norm_owners "$val"; return; fi ;;
      esac
    done < "$ASSIGNEES_FILE"
  fi

  if [[ "$fallback" == "codeowners" ]]; then
    local co="" c pat rest owners="" users="" o
    for c in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
      if [[ -f "$c" ]]; then co="$c"; break; fi
    done
    if [[ -n "$co" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        pat=""; rest=""
        read -r pat rest <<< "$line" || true
        if [[ -z "$pat" ]]; then continue; fi
        if codeowners_match "$pat" "$f"; then owners="$rest"; fi
      done < "$co"
      for o in $owners; do
        if [[ "$o" == @* && "$o" != */* ]]; then users="${users:+$users,}${o#@}"; fi
      done
      if [[ -n "$users" ]]; then printf '%s' "$users"; return; fi
    fi
  fi
  norm_owners "$default"
}

label_color() {
  case "$1" in
    severity:critical) echo b60205 ;;
    severity:high)     echo d93f0b ;;
    severity:medium)   echo fbca04 ;;
    severity:low)      echo 0e8a16 ;;
    category:*)        echo 5319e7 ;;
    *)                 echo c5def5 ;;
  esac
}

# Reads a key from a .md file's front matter
fm() {
  awk -v k="$2" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---"  { exit }
    infm { i=index($0,":"); if (substr($0,1,i-1)==k) { v=substr($0,i+1); sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v); print v; exit } }
  ' "$1"
}
# Body of the .md file (everything after the front matter)
body_of() {
  awk 'NR==1 && $0=="---" { infm=1; next } infm && $0=="---" { infm=0; started=1; next } started' "$1"
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

# Runs the agent read-only and leaves a JSON object matching the schema in $4.
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

usage() { sed -n '2,40p' "$0" | sed -n '/^#   tnr-issues \[/,/^#   (flags take/p' | sed 's/^# \{0,1\}//'; }

# ── Arguments ──────────────────────────────────────────────────────────────────

need() { [[ $2 -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }; }
SCOPE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--agent)      need "$1" $#; AGENT="$2"; shift 2 ;;
    --agent=*)       AGENT="${1#*=}"; shift ;;
    -m|--model)      need "$1" $#; MODEL="$2"; shift 2 ;;
    --model=*)       MODEL="${1#*=}"; shift ;;
    --draft-model)   need "$1" $#; DRAFT_MODEL="$2"; shift 2 ;;
    --draft-model=*) DRAFT_MODEL="${1#*=}"; shift ;;
    -e|--effort)     need "$1" $#; EFFORT="$2"; shift 2 ;;
    --effort=*)      EFFORT="${1#*=}"; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; SCOPE="${SCOPE:+$SCOPE }$*"; break ;;
    -*)              echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)               SCOPE="${SCOPE:+$SCOPE }$1"; shift ;;
  esac
done
SCOPE="${SCOPE:-the entire repository}"

# "claude:sonnet" → agent claude + model sonnet; bare "claude" → agent claude + default model.
# Only known agent names count as a prefix (opencode ids like "openrouter/x:free" contain ':').
split_model() { # $1 value → sets SPLIT_AGENT (empty if no prefix) and SPLIT_MODEL
  SPLIT_AGENT=""; SPLIT_MODEL="$1"
  if is_agent "$1"; then SPLIT_AGENT="$1"; SPLIT_MODEL=""
  elif [[ "$1" == *:* ]] && is_agent "${1%%:*}"; then SPLIT_AGENT="${1%%:*}"; SPLIT_MODEL="${1#*:}"; fi
}
AGENT="$(lower "$AGENT")"
split_model "$MODEL"; MODEL="$SPLIT_MODEL"
if [[ -n "$AGENT" && -n "$SPLIT_AGENT" && "$AGENT" != "$SPLIT_AGENT" ]]; then
  echo "--agent '$AGENT' conflicts with the model prefix '$SPLIT_AGENT:'" >&2; exit 2
fi
AGENT="${SPLIT_AGENT:-$AGENT}"
# No agent given: "provider/model" ids are opencode's format, anything else goes to Codex.
if [[ -z "$AGENT" ]]; then
  if [[ "$MODEL" == */* ]]; then AGENT=opencode; else AGENT=codex; fi
fi
is_agent "$AGENT" || { echo "unknown agent: $AGENT (use: ${AGENTS// /, })" >&2; exit 2; }
if [[ -n "$DRAFT_MODEL" ]]; then
  split_model "$DRAFT_MODEL"; DRAFT_AGENT="${SPLIT_AGENT:-$AGENT}"; DRAFT_MODEL="$SPLIT_MODEL"
else
  DRAFT_AGENT="$AGENT"; DRAFT_MODEL="$MODEL"
fi
# Codex model ids are lowercase ("GPT-5.6-Luna" → "gpt-5.6-luna")
if [[ "$AGENT" == codex ]]; then MODEL="$(lower "$MODEL")"; fi
if [[ "$DRAFT_AGENT" == codex ]]; then DRAFT_MODEL="$(lower "$DRAFT_MODEL")"; fi

# ── 1. Requirements and context ────────────────────────────────────────────────

step "Checking requirements and repository context"
for bin in git gh jq "$AGENT" "$DRAFT_AGENT"; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is not in the PATH"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$ROOT"
if [[ -z "$ASSIGNEES_FILE" ]]; then
  if [[ -f ".orca/issue-assignees.properties" ]]; then ASSIGNEES_FILE=".orca/issue-assignees.properties"
  else ASSIGNEES_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tnr-issues/assignees.properties"; fi
fi
if [[ -n "$EFFORT" && ( "$AGENT" != codex || "$DRAFT_AGENT" != codex ) ]]; then
  warn "--effort only applies to Codex; it is ignored for the other agents."
fi

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner </dev/null)"
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name </dev/null)"
SHA="$(git rev-parse HEAD)"
SHA_PUSHED=0
if [[ -n "$(git branch -r --contains "$SHA" 2>/dev/null || true)" ]]; then
  LINK_REF="$SHA"; SHA_PUSHED=1
else
  LINK_REF="$DEFAULT_BRANCH"
  warn "HEAD ($SHA) is not on the remote: links will point to '$DEFAULT_BRANCH' and line numbers may not match."
fi

# Branch the review originates from (and whether it is published on the remote)
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
BRANCH_URL=""
if [[ -n "$BRANCH" ]]; then
  BRANCH_REMOTE="$(git config "branch.$BRANCH.remote" 2>/dev/null || echo origin)"
  if git ls-remote --exit-code --heads "$BRANCH_REMOTE" "$BRANCH" >/dev/null 2>&1; then
    BRANCH_URL="https://github.com/$REPO/tree/$BRANCH"
  else
    warn "branch '$BRANCH' is not published on '$BRANCH_REMOTE'; the issue will mention it without a link."
  fi
else
  BRANCH="detached HEAD (${SHA:0:10})"
  warn "not on a branch (detached HEAD)."
fi

RUN_ID="${RUN_ID:-$(printf '%s|%s' "$SHA" "$SCOPE" | git hash-object --stdin | cut -c1-10)}"
WORK="$ROOT/.tnr-issues/$RUN_ID"
mkdir -p "$WORK/issues" "$WORK/drafts"
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"   # also works in worktrees
mkdir -p "$(dirname "$EXCLUDE")"
grep -qxF '.tnr-issues/' "$EXCLUDE" 2>/dev/null || echo '.tnr-issues/' >> "$EXCLUDE"

SKILL_PATH=""
for d in "$ROOT/.agents/skills" "$ROOT/.codex/skills" "$ROOT/.claude/skills" "$ROOT/.opencode/skill" "$ROOT/.opencode/skills" \
         "${CODEX_HOME:-$HOME/.codex}/skills" "$HOME/.claude/skills" "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skill" \
         "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" "$HOME/.agents/skills"; do
  if [[ -f "$d/$SKILL/SKILL.md" ]]; then SKILL_PATH="$d/$SKILL"; break; fi
done
if [[ -n "$SKILL_PATH" ]]; then ok "skill: $SKILL_PATH"; else warn "could not find $SKILL in known paths; the agent may not load it"; fi
ok "repo: $REPO · branch: $BRANCH · commit ${SHA:0:10} · scope: $SCOPE"
ok "review: $(agent_name "$AGENT") (${MODEL:-default model}) · drafting: $(agent_name "$DRAFT_AGENT") (${DRAFT_MODEL:-default model})${EFFORT:+ · effort $EFFORT}"
ok "working directory: .tnr-issues/$RUN_ID"
if [[ -f "$ASSIGNEES_FILE" ]]; then ok "assignment rules: $ASSIGNEES_FILE"; else info "no assignment rules; CODEOWNERS will be used if present"; fi

# How to invoke the skill: Codex uses $name; other agents get the path to SKILL.md as a fallback.
if [[ "$AGENT" == codex ]]; then SKILL_REF="the skill \$$SKILL"
else SKILL_REF="the \`$SKILL\` skill"; fi
if [[ -n "$SKILL_PATH" ]]; then
  SKILL_REF="$SKILL_REF (its instructions are in '$SKILL_PATH/SKILL.md'; read them first if the skill is not loaded automatically)"
fi

# ── 2. Review ──────────────────────────────────────────────────────────────────

step "Running \$$SKILL with $(agent_name "$AGENT") (read-only)"
FINDINGS="$WORK/findings.json"
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
                     "evidence", "impact", "recommendation", "acceptanceCriteria", "confidence"],
        "properties": {
          "title": { "type": "string" },
          "severity": { "type": "string", "enum": ["critical", "high", "medium", "low", "info"] },
          "category": { "type": "string" },
          "file": { "type": "string" },
          "startLine": { "type": "integer" },
          "endLine": { "type": "integer" },
          "problem": { "type": "string" },
          "evidence": { "type": "string" },
          "impact": { "type": "string" },
          "recommendation": { "type": "string" },
          "acceptanceCriteria": { "type": "array", "items": { "type": "string" } },
          "confidence": { "type": "number" }
        }
      }
    }
  }
}
JSON
  REVIEW_PROMPT="Run $SKILL_REF on this repository.

Requested scope: $SCOPE

Rules:
- Do NOT modify any file; only analyze.
- One finding per distinct problem. If the same pattern appears in several files, one finding per file.
- file: path relative to the repository root as git sees it (no './').
- startLine/endLine: 1-based lines in the current working tree that bound the affected code; 0 and 0 if it is file-level.
- category: one or two words (complexity, duplication, error-handling, naming, performance, security, testing, architecture...).
- evidence: what in the code proves it, without pasting long blocks.
- acceptanceCriteria: 2 to 5 verifiable conditions to consider the problem resolved.
- confidence: 0.0-1.0, how sure you are that it is a real problem.
- summary: overall state of the code in 2-3 sentences.
Write all text in $ISSUE_LANG."
  agent_json "$AGENT" "$MODEL" "$WORK/findings.schema.json" "$FINDINGS" "$REVIEW_PROMPT" \
    && jq -e '.findings | arrays' "$FINDINGS" >/dev/null 2>&1 \
    || die "$(agent_name "$AGENT") did not return valid JSON (see the output above and $FINDINGS.log)"
  ok "$(jq '.findings | length' "$FINDINGS") findings"
fi
info "$(jq -r '.summary' "$FINDINGS")"

# ── 3. Filtering and prioritization ────────────────────────────────────────────

step "Filtering (severity ≥ $MIN_SEVERITY, confidence ≥ $MIN_CONFIDENCE, max $MAX_ISSUES)"
SELECTED="$WORK/selected.json"
jq --arg minsev "$MIN_SEVERITY" --argjson minconf "$MIN_CONFIDENCE" --argjson max "$MAX_ISSUES" '
  def rank: ({"critical":0,"high":1,"medium":2,"low":3,"info":4}[ascii_downcase] // 4);
  [ .findings[]
    | .file |= ltrimstr("./")
    | .severity |= ascii_downcase
    | select((.severity | rank) <= ($minsev | rank) and .confidence >= $minconf) ]
  | sort_by([(.severity | rank), -.confidence])
  | .[:$max]
  | to_entries
  | map(.value + { id: ("F-" + (("00" + ((.key + 1) | tostring))[-3:])) })
' "$FINDINGS" > "$SELECTED"
ok "$(jq 'length' "$SELECTED") findings selected"

# ── 4. One issue file per finding (drafted by the agent) ───────────────────────

step "Generating issue files with $(agent_name "$DRAFT_AGENT")"
cat > "$WORK/draft.schema.json" <<'JSON'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["title", "body"],
  "properties": { "title": { "type": "string" }, "body": { "type": "string" } }
}
JSON

TOTAL_SEL="$(jq 'length' "$SELECTED")"
i=0
while IFS= read -r row <&3; do
  i=$((i + 1))
  get() { jq -r "$1" <<< "$row"; }
  fid="$(get .id)"; file="$(get .file)"; sev="$(get .severity)"; cat_="$(get .category)"
  conf="$(get .confidence)"; start="$(get .startLine)"; end="$(get .endLine)"
  md="$WORK/issues/$fid.md"
  draft="$WORK/drafts/$fid.json"

  if [[ -f "$md" ]]; then ok "($i/$TOTAL_SEL) $fid already exists, keeping it (including your edits)"; continue; fi
  if [[ ! -f "$file" ]]; then warn "($i/$TOTAL_SEL) $fid discarded: '$file' does not exist"; continue; fi

  # Clamp the lines to the file's actual length
  n="$(wc -l < "$file" | tr -d ' ')"
  if (( start < 0 )); then start=0; fi
  if (( start > n )); then start=$n; fi
  if (( end < start )); then end=$start; fi
  if (( end > n )); then end=$n; fi

  info "($i/$TOTAL_SEL) $fid · $sev · $file — drafting…"
  if [[ ! -f "$draft" ]] || ! jq -e .body "$draft" >/dev/null 2>&1; then
    DRAFT_PROMPT="Write a GitHub issue from this code review finding.
You may read '$file' for context, but do NOT modify anything. Write in $ISSUE_LANG.

title: imperative and specific, at most 72 characters, format '<component>: <action>', no emojis or severity.
body: Markdown with EXACTLY these sections, in this order (translate the headings if not writing in English):
  ## Summary             (1-2 sentences: what happens and why it matters)
  ## Problem             (technical detail, name concrete functions/classes)
  ## Impact              (bugs, maintainability, performance, security)
  ## Proposed solution   (concrete steps; short snippet if it helps)
  ## Acceptance criteria (checklist '- [ ] ...', verifiable)
Do not include location, links to the file, metadata or front matter: the script adds them.

Finding (JSON):
$row"
    agent_json "$DRAFT_AGENT" "$DRAFT_MODEL" "$WORK/draft.schema.json" "$draft" "$DRAFT_PROMPT" \
      && jq -e '(.title | strings) and (.body | strings)' "$draft" >/dev/null 2>&1 \
      || { warn "$fid: $(agent_name "$DRAFT_AGENT") did not return a valid draft; skipping (re-run to retry)"; rm -f "$draft"; continue; }
  fi

  title="$(jq -r .title "$draft" | tr '\n' ' ' | cut -c1-120)"
  title="$(trim "$title")"
  fp="tnr-$(printf '%s|%s|%s' "$file" "$(lower "$cat_")" "$(lower "$(get .title)")" | git hash-object --stdin | cut -c1-12)"
  labels="code-quality,severity:$sev,category:$(slug "$cat_")${EXTRA_LABELS:+,$EXTRA_LABELS}"
  assignees="$(resolve_assignees "$file")"

  if (( start <= 0 )); then range=""; anchor=""
  elif (( end > start )); then range=" (lines ${start}–${end})"; anchor="#L$start-L$end"
  else range=" (line $start)"; anchor="#L$start"; fi
  link="https://github.com/$REPO/blob/$LINK_REF/$file$anchor"
  if [[ -n "$BRANCH_URL" ]]; then branch_md="[\`$BRANCH\`]($BRANCH_URL)"; else branch_md="\`$BRANCH\` (local only, not published)"; fi
  if (( SHA_PUSHED )); then commit_md="[\`${SHA:0:10}\`](https://github.com/$REPO/commit/$SHA)"; else commit_md="\`${SHA:0:10}\` (not published)"; fi

  {
    echo "---"
    echo "finding: $fid"
    echo "title: $title"
    echo "labels: $labels"
    echo "assignees: $assignees"
    echo "fingerprint: $fp"
    echo "branch: $BRANCH"
    echo "---"
    echo
    echo "## 📍 Location"
    echo
    echo "\`$file\`$range"
    echo
    echo "**Branch:** $branch_md · **Commit:** $commit_md"
    echo
    echo "$link"
    echo
    jq -r .body "$draft"
    echo
    echo "---"
    echo "<sub>🤖 Generated by Orca Quick Command + $(agent_name "$AGENT") · skill \`$SKILL\` · branch \`$BRANCH\` · severity **$sev** · category **$cat_** · confidence $conf · \`$fp\`</sub>"
  } > "$md"
  ok "($i/$TOTAL_SEL) .tnr-issues/$RUN_ID/issues/$fid.md → ${assignees:-unassigned}"
done 3< <(jq -c '.[]' "$SELECTED")

if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
  checkpoint "DRY_RUN: drafts ready in .tnr-issues/$RUN_ID/issues"
  printf '\n\033[1;33mDRY_RUN:\033[0m review/edit .tnr-issues/%s/issues/*.md and run again without --dry-run\n' "$RUN_ID"
  printf '(same scope and same HEAD, or with RUN_ID=%s) to create the issues.\n' "$RUN_ID"
  exit 0
fi

# ── 5. Labels ──────────────────────────────────────────────────────────────────

step "Ensuring labels exist on GitHub"
cat "$WORK"/issues/F-*.md 2>/dev/null \
  | awk -F': ' '/^labels: /{ print $2 }' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sort -u \
  | while IFS= read -r l; do
      [[ -z "$l" ]] && continue
      if gh label create "$l" --color "$(label_color "$l")" --description "Automated code quality review" </dev/null >/dev/null 2>&1; then
        ok "created: $l"
      else
        info "already exists: $l"
      fi
    done

# ── 6. Create issues from the files ────────────────────────────────────────────

step "Creating issues with gh"
CREATED="$WORK/created.tsv"
touch "$CREATED"
for md in "$WORK"/issues/F-*.md; do
  [[ -e "$md" ]] || continue
  fid="$(fm "$md" finding)"
  if grep -q "^$fid	" "$CREATED"; then ok "$fid already created: $(grep "^$fid	" "$CREATED" | cut -f2)"; continue; fi

  title="$(fm "$md" title)"; labels="$(fm "$md" labels)"; assignees="$(fm "$md" assignees)"; fp="$(fm "$md" fingerprint)"

  existing="$(gh issue list --state all --search "\"$fp\" in:body" --json url -q '.[0].url' </dev/null 2>/dev/null || true)"
  if [[ "$existing" == http* ]]; then
    printf '%s\t%s\treused\n' "$fid" "$existing" >> "$CREATED"
    ok "$fid already existed on GitHub: $existing"
    continue
  fi

  args=(issue create --title "$title" --body-file -)
  while IFS= read -r l; do
    l="$(trim "$l")"; if [[ -n "$l" ]]; then args+=(--label "$l"); fi
  done <<< "$(printf '%s' "$labels" | tr ',' '\n')"
  with_assignees=("${args[@]}")
  while IFS= read -r a; do
    a="$(trim "$a")"; if [[ -n "$a" ]]; then with_assignees+=(--assignee "$a"); fi
  done <<< "$(printf '%s' "$assignees" | tr ',' '\n')"

  if url="$(body_of "$md" | gh "${with_assignees[@]}" 2>"$WORK/gh.err")"; then
    :
  elif [[ -n "$assignees" ]]; then
    warn "$fid: could not assign to '$assignees' ($(head -n1 "$WORK/gh.err")); creating it unassigned"
    url="$(body_of "$md" | gh "${args[@]}" 2>"$WORK/gh.err")" || die "gh issue create failed for $fid: $(head -n1 "$WORK/gh.err")"
  else
    die "gh issue create failed for $fid: $(head -n1 "$WORK/gh.err")"
  fi
  url="$(printf '%s\n' "$url" | tail -n1)"
  printf '%s\t%s\tcreated\n' "$fid" "$url" >> "$CREATED"
  ok "$fid → $url ${assignees:+(→ $assignees)}"
done

# ── 7. Summary ─────────────────────────────────────────────────────────────────

step "Summary"
NEW="$(grep -c '	created$' "$CREATED" || true)"
REUSED="$(grep -c '	reused$' "$CREATED" || true)"
ok "$NEW new issues · $REUSED already existed"
while IFS=$'\t' read -r fid url kind; do info "$fid  $url"; done < "$CREATED"
checkpoint "✔ $NEW new issues, $REUSED already existed"
