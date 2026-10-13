# Fork rules

- Read [FORK.md](FORK.md) for maintenance, release, and installation commands.
- Keep changes minimal and close to upstream; remove patches once upstream fixes the behavior.
- Preserve the selected model and bounded retry limits. Buffering must leave the composer available.
- Keep upstream files and README edits small; put fork maintenance details in `FORK.md`.
- Build releases through `scripts/fork-release.sh`; preserve compatibility versioning, static packaging, and privacy checks.
- Run relevant runtime tests for runtime changes and `scripts/fork_test.sh` for installer/release changes.
