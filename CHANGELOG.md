# Changelog

All notable changes to Shep are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases before 0.4.3 are on the [GitHub releases page](https://github.com/craigruks/shep/releases).

## [Unreleased]

## [0.4.3] - 2026-10-31

### Added

- `just shep ps` reports each running task's current step (hook, agent, verify, ci_wait, ci_fix with its fix round) and a human-readable elapsed time; the orchestrator logs one line per step transition (#99, #100).

### Changed

- Docs: the README's "Where Shep fits" section (#94, #96).
- Dependencies: `req` 0.7.2 → 0.7.5 (#93).
- Dependencies: `dialyxir` 1.4.7 → 1.4.8 (#92).

[Unreleased]: https://github.com/craigruks/shep/compare/v0.4.3...HEAD
[0.4.3]: https://github.com/craigruks/shep/compare/v0.4.2...v0.4.3
