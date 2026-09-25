# scripts

A shared collection of shell scripts.

## Table of Contents

- [Summary](#summary)
- [Project Structure](#project-structure)
- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)

## Summary

This repository is a shared home for reusable shell (`.sh`) scripts. The goal is
to keep common utility and automation scripts in one place so they can be
versioned, reviewed, and reused across projects.

## Project Structure

```
scripts/
├── setup.sh  # Installs the scripts into ~/.local/bin
├── src/      # Shell scripts
└── docs/     # Documentation for how to use the scripts
```

## Installation

From the repository root, run:

```
./setup.sh
```

The setup script:

1. Checks which scripts from `src/` are already in `~/.local/bin` and shows
   each one as `installed`, `missing` or `outdated` (differs from `src/`).
2. Lists the missing/outdated ones so you can pick which to install (numbers
   separated by spaces, or `a` for all).
3. Asks for confirmation, then copies them to `~/.local/bin` without the
   `.sh` extension (e.g. `src/create-release.sh` → `~/.local/bin/create-release`)
   and makes them executable.

Use `./setup.sh -y` to install every missing/outdated script without prompts.
Re-run it after pulling changes to update the installed copies.

Some scripts call others by name (e.g. `create-release` runs
`update-changelog`), so `~/.local/bin` should be in your `PATH`. If it isn't,
add this to your shell profile (`~/.zshrc`, `~/.bashrc`):

```
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

Run an installed script by its full path using `$HOME`:

```
"$HOME/.local/bin/create-release" claude:haiku
```

Or, with `~/.local/bin` in your `PATH`, just by name:

```
create-release claude:haiku
```

Every script accepts `-h`/`--help`. See [docs/](docs/) for each script's
options.

## Documentation

See [docs/](docs/) for details on how to use the scripts in this repository.
