# Changelog

All notable changes to Shep are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases before 0.5.0 are on the [GitHub releases page](https://github.com/craigruks/shep/releases).

## [Unreleased]

## [0.5.0] - 2026-11-02

### Added

- `just shep doctor` (alias `vet`) checks push auth, the HTTPS remote, the noreply email, the labels, the agent CLI and the workspace before the first dispatch, and prints the fix for each failure (#97, #101).
- `just shep ps` reports each running task's current step (hook, agent, verify, ci_wait, ci_fix with its fix round) and a human-readable elapsed time; the orchestrator logs one line per step transition (#99, #100).

### Fixed

- A task that runs out of verify fixes, gives up on CI, or whose agent fails now moves its issue to `shep:failed` and posts a comment with the redacted tail of the failing output. Before, verify and agent failures left the issue at `shep:in-progress` with no comment. Shep found this one while working on its own repo (#98, #102).

### Changed

- Docs: the README's "Where Shep fits" section (#94, #96).
- Dependencies: `req` 0.7.2 → 0.7.5 (#93).
- Dependencies: `dialyxir` 1.4.7 → 1.4.8 (#92).

[Unreleased]: https://github.com/craigruks/shep/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/craigruks/shep/compare/v0.4.2...v0.5.0
