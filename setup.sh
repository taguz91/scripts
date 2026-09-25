#!/usr/bin/env bash
# setup.sh — installs the scripts from src/ into ~/.local/bin (without the .sh extension)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src"
BIN_DIR="$HOME/.local/bin"

usage() {
  cat <<EOF
Usage: ./setup.sh [-y] [-h]

Checks which scripts from src/ are already installed in $BIN_DIR, lists the
missing (or outdated) ones, and copies the ones you pick after confirming.

Options:
  -y, --yes    Install every missing/outdated script without asking
  -h, --help   Show this help
EOF
}

ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# 1. Check what's installed
PENDING=()
echo "Scripts in $SRC_DIR → $BIN_DIR"
echo
for src in "$SRC_DIR"/*.sh; do
  name="$(basename "$src" .sh)"
  dest="$BIN_DIR/$name"
  if [[ ! -e "$dest" ]]; then
    printf '  %-20s missing\n' "$name"
    PENDING+=("$name")
  elif ! cmp -s "$src" "$dest"; then
    printf '  %-20s outdated\n' "$name"
    PENDING+=("$name")
  else
    printf '  %-20s installed\n' "$name"
  fi
done
echo

if [[ ${#PENDING[@]} -eq 0 ]]; then
  echo "Everything is installed and up to date."
  exit 0
fi

# 2. Pick which ones to install
SELECTED=()
if [[ $ASSUME_YES -eq 1 ]]; then
  SELECTED=("${PENDING[@]}")
else
  echo "Available to install:"
  for i in "${!PENDING[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${PENDING[$i]}"
  done
  echo "  a) all"
  echo
  read -r -p "Choose (numbers separated by spaces, 'a' for all, empty to cancel): " choice
  [[ -z "$choice" ]] && { echo "Cancelled."; exit 0; }
  if [[ "$choice" == "a" || "$choice" == "A" ]]; then
    SELECTED=("${PENDING[@]}")
  else
    for n in $choice; do
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#PENDING[@]} )); then
        SELECTED+=("${PENDING[$((n - 1))]}")
      else
        echo "Invalid option: $n" >&2; exit 1
      fi
    done
  fi

  # 3. Confirm
  echo
  echo "Will copy to $BIN_DIR: ${SELECTED[*]}"
  read -r -p "Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[yY]$ ]] || { echo "Cancelled."; exit 0; }
fi

# 4. Copy
mkdir -p "$BIN_DIR"
for name in "${SELECTED[@]}"; do
  install -m 755 "$SRC_DIR/$name.sh" "$BIN_DIR/$name"
  echo "  ✓ $name → $BIN_DIR/$name"
done

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "Note: $BIN_DIR is not in your PATH. Some scripts call each other by name"
    echo "(e.g. create-release runs update-changelog), so add it to your shell profile:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac
