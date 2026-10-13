#!/usr/bin/env bash
# Build/install the local fork without modifying the upstream package itself.
set -euo pipefail

script=${BASH_SOURCE[0]:-}
repo=$(cd -- "$(dirname -- "${script:-.}")/.." && pwd)
state=${CODEX_FORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/codex-fork}
[[ "$state" = /* ]] || { echo "CODEX_FORK_HOME must be absolute." >&2; exit 1; }
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$repo/codex-rs/target}

usage() {
    cat <<'HELP'
Usage: fork.sh [install|update|uninstall|status|build|install-built|source-install|sync]

Default/update: download the static Linux release, verify checksum, install.
Requires bash, curl, tar, and coreutils. No compiler or checkout needed.
uninstall: restore the previous upstream launcher. status: show installed revision.

Developers: source-install builds and installs; install-built uses an existing build.
sync: clean checkout required; fetch/rebase upstream/main. Resolve conflicts normally.
Then scripts/fork-release.sh builds and publishes using gh. Push rebased main separately.

Uses the same login/config, disables upstream auto-update, and runs its own backend.
If npm/bun replaces the launcher, rerun this installer. Without an existing codex,
add ~/.local/bin to PATH. Existing launcher directory must be writable.
Overrides: CODEX_FORK_BIN, CODEX_FORK_HOME, CARGO_TARGET_DIR, CARGO_BUILD_JOBS (auto).
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
        python3 - <<'PY'
import hashlib
import os
import subprocess
from codex_package.targets import TARGET_SPECS
from codex_package.v8 import resolve_codex_v8_cargo_env

host = next(line.split(": ", 1)[1] for line in subprocess.check_output(
    ["rustc", "-vV"], text=True).splitlines() if line.startswith("host: "))
env = dict(os.environ, CARGO_PROFILE_RELEASE_LTO="false", CARGO_PROFILE_RELEASE_DEBUG="0",
           CARGO_PROFILE_RELEASE_STRIP="symbols")
target = os.environ.get("CODEX_FORK_TARGET", host)
env.update(resolve_codex_v8_cargo_env(TARGET_SPECS[target]))
available_kib = int(next(line.split()[1] for line in open("/proc/meminfo") if line.startswith("MemAvailable:")))
jobs = os.environ.get("CARGO_BUILD_JOBS", str(max(1, min(os.cpu_count() or 1, available_kib // (4 * 1024 * 1024)))))
cmd = ["cargo", "build", "--locked", "--release", "--jobs", jobs]
target_dir = target if "CODEX_FORK_TARGET" in os.environ else ""
if target_dir:
    cmd += ["--target", target]
print(f"Building {target} with {jobs} Cargo jobs", flush=True)
subprocess.run(cmd + ["--bin", "bwrap"], env=env, check=True)
env["CODEX_BWRAP_SHA256"] = hashlib.sha256(open(
    os.path.join(env["CARGO_TARGET_DIR"], target_dir, "release", "bwrap"), "rb").read()).hexdigest()
subprocess.run(cmd + ["--bin", "codex", "--bin", "codex-code-mode-host"], env=env, check=True)
PY
    )
}

install_fork() {
    local launcher staging=${1:-}
    if [[ -f "$state/launcher-path" ]]; then
        launcher=$(cat "$state/launcher-path")
    else
        launcher=${CODEX_FORK_BIN:-$(command -v codex || true)}
        launcher=${launcher:-$HOME/.local/bin/codex}
    fi
    [[ "$launcher" = /* ]] || { echo "Launcher must be an absolute path: $launcher" >&2; exit 1; }
    mkdir -p -- "$(dirname -- "$launcher")" "$state/releases"
    [[ -w "$(dirname -- "$launcher")" ]] || { echo "Launcher directory is not writable: $launcher" >&2; exit 1; }
    if [[ -z "$staging" ]]; then
        staging=$(mktemp -d "$state/releases/build.XXXXXXXX")
        mkdir -p "$staging/bin" "$staging/codex-resources" "$staging/codex-path"
        install -m 755 "$CARGO_TARGET_DIR/release/codex" "$CARGO_TARGET_DIR/release/codex-code-mode-host" "$staging/bin/"
        install -m 755 "$CARGO_TARGET_DIR/release/bwrap" "$staging/codex-resources/bwrap"
        install -m 755 "$(command -v rg)" "$staging/codex-path/rg"
        # Discover helpers using upstream's package layout; source builds skip its updater.
        echo '{"layoutVersion":1,"version":"0.0.0","entrypoint":"bin/codex"}' > "$staging/codex-package.json"
        git -C "$repo" rev-parse HEAD > "$staging/revision"
        install -m 755 "$script" "$staging/fork.sh"
    fi
    "$staging/bin/codex" --version
    ln -s "$staging" "$state/current.new"
    mv -Tf "$state/current.new" "$state/current"
    install -m 755 "$staging/fork.sh" "$state/fork.sh"
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
    echo "Update/restore: $state/fork.sh update / uninstall"
}

download_fork() {
    local architecture latest tag asset downloads staging
    architecture=$(uname -m)
    [[ "$architecture" = x86_64 && "$(uname -s)" = Linux ]] || {
        echo "Prebuilt releases currently support x86-64 Linux." >&2; exit 1;
    }
    latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/redthing1/codex/releases/latest)
    tag=${latest##*/}
    [[ "$tag" = fork-* ]] || { echo "No fork release is published yet." >&2; exit 1; }
    asset="codex-fork-x86_64-unknown-linux-musl.tar.gz"
    downloads=$(mktemp -d)
    curl -fL --retry 3 "https://github.com/redthing1/codex/releases/download/$tag/$asset" -o "$downloads/$asset"
    curl -fsSL --retry 3 "https://github.com/redthing1/codex/releases/download/$tag/$asset.sha256" -o "$downloads/$asset.sha256"
    (cd "$downloads" && sha256sum -c "$asset.sha256")
    mkdir -p "$state/releases"
    staging=$(mktemp -d "$state/releases/release.XXXXXXXX")
    tar -xzf "$downloads/$asset" -C "$staging"
    install_fork "$staging"
    rm -rf -- "$downloads"
}

case "${1:-install}" in
    build) build ;;
    install|update) download_fork ;;
    source-install) build; install_fork ;;
    install-built) install_fork ;;
    sync)
        [[ -z "$(git -C "$repo" status --porcelain)" ]] || {
            echo "Commit or stash local changes before updating." >&2; exit 1;
        }
        if ! git -C "$repo" remote get-url upstream >/dev/null 2>&1; then
            git -C "$repo" remote add upstream https://github.com/openai/codex
        fi
        git -C "$repo" fetch upstream main
        git -C "$repo" rebase upstream/main
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
