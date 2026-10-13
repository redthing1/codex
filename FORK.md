# Fork maintenance

- `origin`: [redthing1/codex](https://github.com/redthing1/codex); `upstream`: [openai/codex](https://github.com/openai/codex).
- Keep the runtime patch small: bounded capacity retries in `codex-rs/protocol/src/error.rs`; status-only buffering in `codex-rs/tui/src/chatwidget/safety_buffering.rs`.
- Remove each patch when upstream supplies equivalent behavior. Exhausted retries can still stop a goal.

From a clean `main` checkout:

```sh
./scripts/fork.sh sync
# Resolve any rebase conflicts; run relevant tests for changed runtime code.
./scripts/fork_test.sh
git push --force-with-lease origin main
./scripts/fork-release.sh
```

- Release builds need a Linux x86-64 development host, Rust, Python 3, and authenticated `gh`; the helper installs musl prerequisites. Keep the Cargo cache for fast rebuilds; `CARGO_BUILD_JOBS` overrides automatic sizing.
- The builder temporarily sets the latest official stable workspace version and restores the manifests afterward. `0.0.0` triggers a legacy backend catalog and can reject newer models. `CODEX_FORK_VERSION` can pin compatibility explicitly.
- Releases bundle static CLI/helper binaries, licenses, a commit revision, installer, and checksum. Publishing rejects stale builds, dynamic binaries, and build-home paths. Keep private configuration and credentials out of artifacts.

Install on x86-64 Linux:

```sh
curl -fsSL https://github.com/redthing1/codex/releases/latest/download/fork.sh | bash
```

- Check: `type -a codex`; `~/.local/share/codex-fork/fork.sh status` shows the launcher, fork commit, and compatibility version.
- Update/restore: `~/.local/share/codex-fork/fork.sh update` / `uninstall`. Restart CLI sessions after updating.
- The launcher uses the same login/config, bypasses shared daemons, and disables upstream auto-update. If a package manager replaces it, rerun the installer.
