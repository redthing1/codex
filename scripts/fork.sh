#!/usr/bin/env bash
# Build/install the local fork without modifying the upstream package itself.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
state=${CODEX_FORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/codex-fork}
[[ "$state" = /* ]] || { echo "CODEX_FORK_HOME must be absolute." >&2; exit 1; }
export CARGO_TARGET_DIR
CARGO_TARGET_DIR=$(realpath -m -- "${CARGO_TARGET_DIR:-$repo/codex-rs/target}")

usage() {
    cat <<'HELP'
Usage: scripts/fork.sh [install|update|build|install-built|uninstall|status]

Default: build and replace the current codex launcher; preserve upstream for uninstall.
Requires Rust/rustup, Python 3.11+, ripgrep, a C compiler, pkg-config, libcap, OpenSSL.
Debian/Ubuntu: sudo apt install build-essential pkg-config libcap-dev libssl-dev ripgrep
First build is substantial; later builds reuse Cargo's cache.

update: clean checkout required; fetch/rebase upstream/main, rebuild, reinstall.
Conflicts stop the update. Resolve and `git rebase --continue`, then run install.
Push your rebased fork separately with git push --force-with-lease.
uninstall: restore upstream's launcher/updater; keep build caches for reinstalls.
install-built: reinstall existing build without compiling.

Uses the same login/config, disables upstream auto-update, and runs its own backend.
If npm/bun replaces the launcher, rerun install-built. Without an existing codex,
add ~/.local/bin to PATH. Existing launcher directory must be writable.
Overrides: CODEX_FORK_BIN, CODEX_FORK_HOME, CARGO_TARGET_DIR, CARGO_BUILD_JOBS (8).
HELP
}

build() {
    command -v cargo >/dev/null || { echo "Install Rust with https://rustup.rs" >&2; exit 1; }
    command -v rg >/dev/null || { echo "Install ripgrep." >&2; exit 1; }
    pkg-config --exists libcap openssl || {
        echo "On Debian/Ubuntu: sudo apt install build-essential pkg-config libcap-dev libssl-dev" >&2
        exit 1
    }
    # Avoid release LTO/debug-symbol costs; retain optimized runtime performance.
    (cd "$repo/codex-rs" && CODEX_REPO_ROOT="$repo" PYTHONPATH="$repo/scripts" \
        python3 - "${CARGO_BUILD_JOBS:-8}" <<'PY'
import os
import subprocess
import sys
from codex_package.targets import TARGET_SPECS
from codex_package.v8 import resolve_codex_v8_cargo_env

host = next(line.split(": ", 1)[1] for line in subprocess.check_output(
    ["rustc", "-vV"], text=True).splitlines() if line.startswith("host: "))
env = dict(os.environ, CARGO_PROFILE_RELEASE_LTO="false", CARGO_PROFILE_RELEASE_DEBUG="0",
           CARGO_PROFILE_RELEASE_STRIP="symbols")
env.update(resolve_codex_v8_cargo_env(TARGET_SPECS[host]))
subprocess.run(["cargo", "build", "--locked", "--release", "--jobs", sys.argv[1],
                "--bin", "codex", "--bin", "codex-code-mode-host", "--bin", "bwrap"],
               env=env, check=True)
PY
    )
}

install_fork() {
    local launcher staging
    if [[ -f "$state/launcher-path" ]]; then
        launcher=$(cat "$state/launcher-path")
    else
        launcher=${CODEX_FORK_BIN:-$(command -v codex || true)}
        launcher=${launcher:-$HOME/.local/bin/codex}
    fi
    [[ "$launcher" = /* ]] || { echo "Launcher must be an absolute path: $launcher" >&2; exit 1; }
    mkdir -p -- "$(dirname -- "$launcher")" "$state/releases"
    [[ -w "$(dirname -- "$launcher")" ]] || { echo "Launcher directory is not writable: $launcher" >&2; exit 1; }
    staging=$(mktemp -d "$state/releases/build.XXXXXXXX")
    mkdir -p "$staging/bin" "$staging/codex-resources" "$staging/codex-path"
    install -m 755 "$CARGO_TARGET_DIR/release/codex" "$CARGO_TARGET_DIR/release/codex-code-mode-host" "$staging/bin/"
    install -m 755 "$CARGO_TARGET_DIR/release/bwrap" "$staging/codex-resources/bwrap"
    install -m 755 "$(command -v rg)" "$staging/codex-path/rg"
    # Discover helpers using upstream's package layout; source builds skip its updater.
    echo '{"layoutVersion":1,"version":"0.0.0","entrypoint":"bin/codex"}' > "$staging/codex-package.json"
    git -C "$repo" rev-parse HEAD > "$staging/revision"
    "$staging/bin/codex" --version
    ln -s "$staging" "$state/current.new"
    mv -Tf "$state/current.new" "$state/current"
    cat > "$state/launch.new" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
state=$(dirname -- "$(readlink -f -- "$0")")
unset CODEX_MANAGED_BY_NPM CODEX_MANAGED_BY_BUN CODEX_MANAGED_BY_PNPM CODEX_MANAGED_BY_VITE_PLUS CODEX_MANAGED_PACKAGE_ROOT
# Use the patched backend instead of an already-running upstream daemon.
exec "$state/current/bin/codex" --no-daemon -c check_for_update_on_startup=false "$@"
LAUNCH
    chmod 755 "$state/launch.new"
    mv -f "$state/launch.new" "$state/launch"
    if [[ "$(readlink -- "$launcher" || true)" != "$state/launch" ]]; then
        if [[ -e "$launcher" || -L "$launcher" ]]; then
            # Refresh the backup if a package-manager update replaced our launcher.
            cp -P -- "$launcher" "$launcher.codex-upstream.new"
            mv -Tf "$launcher.codex-upstream.new" "$launcher.codex-upstream"
        fi
        ln -s "$state/launch" "$launcher.codex-fork.new"
        mv -Tf "$launcher.codex-fork.new" "$launcher"
    fi
    printf '%s\n' "$launcher" > "$state/launcher-path"
    echo "Installed fork at $launcher"
    echo "Restore upstream: $repo/scripts/fork.sh uninstall"
}

case "${1:-install}" in
    build) build ;;
    install) build; install_fork ;;
    install-built) install_fork ;;
    update)
        [[ -z "$(git -C "$repo" status --porcelain)" ]] || {
            echo "Commit or stash local changes before updating." >&2; exit 1;
        }
        if ! git -C "$repo" remote get-url upstream >/dev/null 2>&1; then
            git -C "$repo" remote add upstream https://github.com/openai/codex
        fi
        git -C "$repo" fetch upstream main
        git -C "$repo" rebase upstream/main
        build
        install_fork
        ;;
    uninstall)
        if [[ ! -f "$state/launcher-path" ]]; then echo "Fork is not installed."; exit 0; fi
        launcher=$(cat "$state/launcher-path")
        if [[ "$(readlink -- "$launcher" || true)" = "$state/launch" ]]; then
            if [[ -e "$launcher.codex-upstream" || -L "$launcher.codex-upstream" ]]; then
                mv -Tf "$launcher.codex-upstream" "$launcher"
            else
                rm -- "$launcher"
            fi
        else
            echo "Launcher was replaced externally; leaving it in place."
            rm -f -- "$launcher.codex-upstream"
        fi
        rm -f "$state/launcher-path"
        echo "Upstream restored; fork binaries and Cargo cache retained for fast reinstalls."
        ;;
    status)
        if [[ -f "$state/launcher-path" ]]; then
            launcher=$(cat "$state/launcher-path")
            echo "Launcher: $launcher -> $(readlink -- "$launcher" || true)"
            echo "Build: $(cat "$state/current/revision")"
            "$state/current/bin/codex" --version
        else echo "Fork is not installed."; fi
        ;;
    -h|--help) usage ;;
    *) usage >&2; exit 1 ;;
esac
