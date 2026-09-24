#!/usr/bin/env bash
# create-release — updates the changelog, bumps the version and opens the release PR
set -euo pipefail

BRANCH=docs/changelog
FILE=CHANGELOG.md
PR_BASE=${RELEASE_PR_BASE:-develop}
PR_LABEL=${RELEASE_PR_LABEL:-documentation}
PR_ASSIGNEE=${RELEASE_PR_ASSIGNEE:-@me}
RETURN_TO=develop

usage() {
  cat <<EOF
Usage: create-release [--major|--minor|--patch] [-b branch] [model]

  1. Updates [Unreleased] with the new commits from develop (via update-changelog,
     which also resolves merge conflicts with the model if the merge needs it)
  2. Computes the version (SemVer) from the changelog, or the one you force with a flag
  3. Moves [Unreleased] to [X.Y.Z] - $(date +%F) and updates package.json
  4. Creates release/vX.Y.Z, pushes it and opens the PR against $PR_BASE
     (assigned to $PR_ASSIGNEE, label "$PR_LABEL")

  Automatic bump: Removed/BREAKING → major, Added → minor, otherwise → patch
  The model is forwarded to update-changelog: only one is tried, defaulting to
  grok via opencode. Accepts a full opencode model ID or a fragment (mimo,
  ling, grok-code-fast-1 ...), or a claude:<model>/codex:<model> prefix to run
  via the Claude Code or Codex CLI instead of opencode.

  -b, --back <branch> Branch to return to when done (default: develop)
  -l, --list          List available free opencode models
  -h, --help          Show this help

Examples:
  create-release
  create-release --patch
  create-release --minor mimo
  create-release claude:haiku
  create-release --patch codex:gpt-5-codex
  create-release -b main --minor
EOF
}

BUMP=""
MODEL=""
while (( $# )); do
  case "$1" in
    --major|--minor|--patch) BUMP=${1#--} ;;
    -b|--back) [[ -n "${2:-}" ]] || { echo "Missing branch for $1" >&2; exit 1; }
               RETURN_TO="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    -l|--list) exec update-changelog --list ;;
    *) [[ -z "$MODEL" ]] || { echo "Only one model is supported" >&2; exit 1; }
       MODEL="$1" ;;
  esac
  shift
done

back_to_base() {
  git switch "$RETURN_TO" 2>/dev/null \
    || echo "Couldn't switch back to $RETURN_TO (open in another worktree?). Staying on $(git branch --show-current)."
}

command -v gh >/dev/null || { echo "Missing gh (GitHub CLI)."; exit 1; }
[[ -f package.json ]]    || { echo "No package.json in $(pwd)."; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "You have uncommitted changes."; exit 1; }

# 1. Syncs docs/changelog with develop and updates [Unreleased] (left staged).
#    update-changelog handles conflict resolution with the model on its own if needed.
update-changelog --no-commit ${MODEL:+"$MODEL"}

UNRELEASED=$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/||/^\[.*\]: /{f=0} f' "$FILE")
grep -qE '^[-*] ' <<<"$UNRELEASED" || { echo "[Unreleased] is empty, nothing to release."; back_to_base; exit 1; }

# 2. Version
if [[ -z "$BUMP" ]]; then
  if   grep -qiE 'BREAKING|^### Removed' <<<"$UNRELEASED"; then BUMP=major
  elif grep -q  '^### Added'             <<<"$UNRELEASED"; then BUMP=minor
  else BUMP=patch; fi
fi
CURRENT=$(node -p "require('./package.json').version")
IFS=. read -r MA MI PA <<<"${CURRENT%%-*}"
case $BUMP in
  major) VERSION="$((MA+1)).0.0" ;;
  minor) VERSION="$MA.$((MI+1)).0" ;;
  patch) VERSION="$MA.$MI.$((PA+1))" ;;
esac
DATE=$(date +%F)
RELEASE="release/v$VERSION"

git ls-remote --exit-code --heads origin "$RELEASE" >/dev/null 2>&1 \
  && { echo "Branch $RELEASE already exists on origin."; exit 1; }

# 3. Changelog: [Unreleased] → [X.Y.Z] - date, and comparison links if present
awk -v v="$VERSION" -v d="$DATE" '
  /^## \[Unreleased\]/ && !done { print; print ""; print "## [" v "] - " d; done=1; next }
  { print }' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"

if grep -qE '^\[Unreleased\]: .*/compare/.*\.\.\.HEAD' "$FILE"; then
  awk -v v="$VERSION" '
    /^\[Unreleased\]: .*\/compare\// {
      url = $2; sub(/\/compare\/.*/, "", url)
      prev = $2; sub(/.*\/compare\//, "", prev); sub(/\.\.\.HEAD$/, "", prev)
      print "[Unreleased]: " url "/compare/v" v "...HEAD"
      print "[" v "]: " url "/compare/" prev "...v" v
      next
    }
    { print }' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
fi

npm version "$VERSION" --no-git-tag-version >/dev/null

git add "$FILE" package.json
[[ -f package-lock.json ]] && git add package-lock.json

echo
echo "Release v$VERSION ($BUMP, from $CURRENT) → PR against $PR_BASE"
echo "$UNRELEASED"
echo
git --no-pager diff --cached --stat
read -rp "Create the release? [y/N] " answer || answer=""
if [[ "$answer" != [yY] ]]; then
  echo "Cancelled. Changes remain staged on $BRANCH."; exit 0
fi

# 4. Commit, branch and PR
git commit -m "chore(release): v$VERSION"
git push origin "$BRANCH"

git switch -c "$RELEASE"
git push -u origin "$RELEASE"
# Creates the label if the repo doesn't have it yet (a no-op if it already exists)
gh label create "$PR_LABEL" --color 0075ca --description "Improvements or additions to documentation" >/dev/null 2>&1 || true

gh pr create --base "$PR_BASE" --head "$RELEASE" \
  --assignee "$PR_ASSIGNEE" \
  --label "$PR_LABEL" \
  --title "Release v$VERSION" \
  --body "## [$VERSION] - $DATE
$UNRELEASED"

git switch "$BRANCH"
git branch -D "$RELEASE"
back_to_base
