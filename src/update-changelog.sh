#!/usr/bin/env bash
# update-changelog.sh — resume los cambios nuevos de develop en [Unreleased]
set -euo pipefail

BASE=develop
BRANCH=docs/changelog
FILE=CHANGELOG.md
# Modelo por defecto; se puede cambiar pasando un argumento (ver --help).
# "claude:<modelo>" o "codex:<modelo>" usan Claude Code / Codex CLI en vez de opencode.
DEFAULT_MODEL=opencode/grok-code-fast-1

usage() {
  cat <<EOF
Usage: update-changelog [model]

  With no arguments, uses: $DEFAULT_MODEL
  With an argument, uses that model instead. Only one model is tried per
  run; if it fails to update $FILE, the local $BRANCH branch is deleted and
  you'll need to re-run with a different model.
  Accepts a full ID or a fragment: mimo, ling, grok-code-fast-1 ...
  Prefix with claude: or codex: to run via the Claude Code or Codex CLI instead of opencode
  (e.g. claude:haiku, claude:sonnet, codex:gpt-5-codex, or bare "codex" for its default model).

  -l, --list          List available free opencode models
  -b, --back <branch> Branch to return to when done (default: develop)
  -i, --interactive   Ask for confirmation before commit and push
  --no-commit         Only update and stage CHANGELOG.md (used by create-release)
  -h, --help          Show this help

Examples:
  update-changelog
  update-changelog mimo
  update-changelog claude:haiku
  update-changelog codex:gpt-5-codex
  update-changelog -b main mimo
EOF
}

# Resuelve un fragmento al primer ID que coincida
resolve_model() {
  local q="$1" match
  [[ "$q" == */* || "$q" == claude:* || "$q" == codex:* || "$q" == codex ]] && { echo "$q"; return; }
  match=$(opencode models opencode | grep -i -- "$q" | head -n1 || true)
  [[ -n "$match" ]] || { echo "Modelo no encontrado: $q (usa --list)" >&2; exit 1; }
  echo "$match"
}

NO_COMMIT=false
INTERACTIVE=false
RETURN_TO=$BASE
CUSTOM=false
MODEL=$DEFAULT_MODEL
while (( $# )); do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    -l|--list)   opencode models opencode | grep -i free; exit 0 ;;
    --no-commit) NO_COMMIT=true ;;
    -i|--interactive) INTERACTIVE=true ;;
    -b|--back)   [[ -n "${2:-}" ]] || { echo "Falta la rama para $1" >&2; exit 1; }
                 RETURN_TO="$2"; shift ;;
    *)           $CUSTOM && { echo "Solo se admite un modelo a la vez" >&2; exit 1; }
                 MODEL="$(resolve_model "$1")"; CUSTOM=true ;;
  esac
  shift
done

# Vuelve a RETURN_TO al terminar. Si esa rama está abierta en otro worktree
# (Orca), git no lo permite: en ese caso se queda en docs/changelog.
back_to_base() {
  $NO_COMMIT && return 0
  git switch "$RETURN_TO" 2>/dev/null \
    || echo "No se pudo volver a $RETURN_TO (¿abierta en otro worktree?). Sigues en $BRANCH."
}

# Se usa cuando no se genera nada (sin commits nuevos o ningún modelo respondió):
# vuelve a RETURN_TO (ignorando --no-commit, no queda nada útil en staging) y
# borra la rama local para no dejar $BRANCH huérfana.
delete_and_return() {
  git switch "$RETURN_TO" 2>/dev/null \
    || { echo "No se pudo volver a $RETURN_TO (¿abierta en otro worktree?). Se deja $BRANCH como está."; return; }
  git branch -D "$BRANCH" 2>/dev/null || true
}
echo "Modelo: $MODEL"

# Compatible con worktrees: nunca hace checkout de develop, mergea origin/develop
git fetch origin
if [[ "$(git branch --show-current)" != "$BRANCH" ]]; then
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
  elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git checkout -b "$BRANCH" "origin/$BRANCH"
  else
    echo "La rama $BRANCH no existe (ni local ni remota); se crea desde origin/$BASE."
    git checkout -b "$BRANCH" "origin/$BASE"
  fi
fi
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git pull --ff-only origin "$BRANCH"
fi

# Solo permite editar archivos; nada de bash ni web
export OPENCODE_PERMISSION='{"edit":"allow","bash":"deny","webfetch":"deny"}'

run_model() {
  local m="$1" prompt="$2"
  case "$m" in
    claude:*)
      claude --model "${m#claude:}" --permission-mode acceptEdits --allowedTools "Read,Edit" -p "$prompt"
      ;;
    codex:*)
      codex exec --model "${m#codex:}" --full-auto "$prompt"
      ;;
    codex)
      codex exec --full-auto "$prompt"
      ;;
    *)
      opencode run -m "$m" "$prompt"
      ;;
  esac
}

BEFORE=$(git rev-parse HEAD)
if ! git merge --no-edit "origin/$BASE"; then
  mapfile -t CONFLICT_FILES < <(git diff --name-only --diff-filter=U)
  if (( ${#CONFLICT_FILES[@]} == 0 )); then
    echo "El merge de origin/$BASE falló y no fue por conflictos; revisa manualmente."
    git merge --abort 2>/dev/null || true
    delete_and_return
    exit 1
  fi

  echo "Conflictos de merge en: ${CONFLICT_FILES[*]}. Pidiendo a $MODEL que los resuelva..."
  CONFLICT_PROMPT="Resolve the git merge conflicts in these files (they contain
<<<<<<<, =======, >>>>>>> markers):

$(printf '%s\n' "${CONFLICT_FILES[@]}")

Rules:
- Understand the intent of both sides and merge them coherently; don't just blindly pick one side.
- Remove all conflict markers completely.
- Do not touch any file that isn't listed above. Do not run commands."

  run_model "$MODEL" "$CONFLICT_PROMPT" || echo "  ($MODEL terminó con error resolviendo conflictos, revisando...)"
  if git grep -lI '^<<<<<<<' -- "${CONFLICT_FILES[@]}" >/dev/null 2>&1; then
    echo "$MODEL no pudo resolver los conflictos. Abortando merge."
    git merge --abort 2>/dev/null || true
    delete_and_return
    exit 1
  fi
  if ! { git add -- "${CONFLICT_FILES[@]}" && git commit --no-edit; }; then
    echo "No se pudo finalizar el commit de merge tras resolver los conflictos."
    git merge --abort 2>/dev/null || true
    delete_and_return
    exit 1
  fi
fi

# Solo lo que entró con este merge, sin merges ni commits del propio changelog
COMMITS=$(git log --no-merges --pretty='- %s (%h)' "$BEFORE..HEAD" -- . ":(exclude)$FILE")
if [[ -z "$COMMITS" ]]; then
  echo "No hay cambios nuevos desde el último changelog."; delete_and_return; exit 0
fi

PROMPT="Edit $FILE following Keep a Changelog 1.1.0 (https://keepachangelog.com).
Only modify the '## [Unreleased]' section (create it right below the header if missing).
Summarize these new commits:

$COMMITS

Rules:
- Group under ### Added, Changed, Deprecated, Removed, Fixed, Security. Use only the ones that apply; merge into existing subsections, never duplicate entries.
- One short, user-facing line per change. Combine related commits into a single line. No commit hashes.
- Skip chore, ci, test, build, style, internal refactors and docs unless they affect users.
- Write in the same language and style as the existing entries.
- Do not touch released versions or any other part of the file. Do not run commands."

echo "→ Probando $MODEL"
# No confiamos en el exit code: opencode puede fallar en tareas secundarias
# (p. ej. el título de la sesión) aunque la edición sí se haya hecho.
run_model "$MODEL" "$PROMPT" || echo "  ($MODEL terminó con error, revisando si editó el archivo...)"
if git diff --quiet -- "$FILE"; then
  git checkout -- "$FILE" 2>/dev/null || true
  echo "$MODEL no pudo actualizar $FILE. Prueba con otro modelo (ver --list/--help)."
  delete_and_return
  exit 1
fi

git add "$FILE"
git --no-pager diff --cached -- "$FILE"
$NO_COMMIT && { echo "CHANGELOG.md actualizado en staging (sin commit)."; exit 0; }

if $INTERACTIVE; then
  read -rp "¿Commit y push? [y/N] " answer || answer=""
  if [[ "$answer" != [yY] ]]; then
    echo "Cancelado. Los cambios quedan en staging en $BRANCH."; exit 0
  fi
fi

git commit -m "docs(changelog): update unreleased section"
git push -u origin "$BRANCH"
back_to_base
