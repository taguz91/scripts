# Documentation

Usage docs for the scripts in [`src/`](../src/).

- [update-changelog](update-changelog.md) — summarizes new commits from `develop` into `CHANGELOG.md`'s `[Unreleased]` section.
- [create-release](create-release.md) — bumps the version, finalizes the changelog, and opens the release PR.
- [tnr-issues](tnr-issues.md) — runs an AI code quality review (Codex, Claude Code or opencode) and turns the findings into assigned GitHub issues.
- [tnr-review](tnr-review.md) — reviews a GitHub PR from its link (clone + `pnpm install` + AI review with Codex, Claude Code or opencode): requests changes with the critical fixes needed, or approves it.
