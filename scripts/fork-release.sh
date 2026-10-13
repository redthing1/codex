#!/usr/bin/env bash
# Build portable Linux binaries with upstream's musl/V8 tooling, then publish once.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$repo/codex-rs/target}
export TARGET="$(uname -m)-unknown-linux-musl"
tools="$CARGO_TARGET_DIR/fork-tools"
output="$CARGO_TARGET_DIR/fork-release"
mkdir -p "$tools" "$output"

build_static() {
    local revision
    revision=$(git -C "$repo" rev-parse HEAD)
    [[ -z "$(git -C "$repo" status --porcelain)" ]] || { echo "Commit changes before building a release." >&2; exit 1; }
    rm -f "$output/build-revision"
    [[ "$TARGET" = x86_64-unknown-linux-musl ]] || { echo "Release builder currently supports x86-64 Linux." >&2; exit 1; }
    if [[ ! -x "$tools/zig/zig" ]]; then
        curl -fL --retry 3 https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz -o "$tools/zig.tar.xz"
        echo "473ec26806133cf4d1918caf1a410f8403a13d979726a9045b421b685031a982  $tools/zig.tar.xz" | sha256sum -c -
        mkdir -p "$tools/zig"
        tar -xJf "$tools/zig.tar.xz" --strip-components=1 -C "$tools/zig"
    fi
    export PATH="$tools/zig:$PATH" RUNNER_TEMP="$tools" GITHUB_ENV="$tools/env"
    local setup_hash
    setup_hash=$(sha256sum "$repo/.github/scripts/install-musl-build-tools.sh" "$repo/.github/scripts/install-musl-openssl.sh")
    if [[ ! -f "$tools/setup.sha256" || "$(cat "$tools/setup.sha256")" != "$setup_hash" ]]; then
        : > "$GITHUB_ENV"
        DEBIAN_FRONTEND=noninteractive APT_INSTALL_ARGS='--no-install-recommends pigz' \
            bash "$repo/.github/scripts/install-musl-build-tools.sh"
        printf '%s\n' "$setup_hash" > "$tools/setup.sha256"
    fi
    while IFS= read -r setting; do export "$setting"; done < "$tools/env"
    # OpenSSL records its prefix in runtime strings. Stage a generic prefix rather
    # than embedding this checkout's private build directory in the executable.
    mkdir -p "$tools/portable"
    python3 - "$repo/.github/scripts/install-musl-openssl.sh" "$tools/portable/openssl.sh" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert '"--prefix=${openssl_prefix}"' in text and "make install_dev" in text
text = text.replace('"--prefix=${openssl_prefix}"', '"--prefix=/opt/codex/openssl"')
text = text.replace("make install_dev", '''make DESTDIR="${openssl_root}/stage" install_dev
    mkdir -p "${openssl_prefix}"
    cp -a "${openssl_root}/stage/opt/codex/openssl/." "${openssl_prefix}/"''')
Path(sys.argv[2]).write_text(text)
PY
    : > "$tools/portable/env"
    RUNNER_TEMP="$tools/portable" GITHUB_ENV="$tools/portable/env" OPENSSL_CC="$CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER" \
        bash "$tools/portable/openssl.sh"
    while IFS= read -r setting; do export "$setting"; done < "$tools/portable/env"
    export AWS_LC_SYS_NO_JITTER_ENTROPY=1
    export RUSTFLAGS="--remap-path-prefix=$repo=/src/codex --remap-path-prefix=$HOME=/build/home -C target-feature=+crt-static"
    export CFLAGS="$CFLAGS -ffile-prefix-map=$repo=/src/codex -ffile-prefix-map=$HOME=/build/home"
    export CXXFLAGS="$CXXFLAGS -ffile-prefix-map=$repo=/src/codex -ffile-prefix-map=$HOME=/build/home"
    export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=64
    (cd "$repo/codex-rs" && rustup target add "$TARGET")
    CODEX_FORK_TARGET="$TARGET" "$repo/scripts/fork.sh" build
    [[ -z "$(git -C "$repo" status --porcelain)" && "$(git -C "$repo" rev-parse HEAD)" = "$revision" ]] || {
        echo "Checkout changed during the build; rebuild before packaging." >&2; exit 1;
    }
    printf '%s\n' "$revision" > "$output/build-revision"
}

package_static() {
    [[ -z "$(git -C "$repo" status --porcelain)" && -f "$output/build-revision" \
        && "$(cat "$output/build-revision")" = "$(git -C "$repo" rev-parse HEAD)" ]] || {
        echo "Release binaries do not match this clean checkout; run scripts/fork-release.sh build first." >&2; exit 1;
    }
    local binary version
    version=$("$CARGO_TARGET_DIR/$TARGET/release/codex" --version | awk '{print $2}')
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$version" != 0.0.0 ]] || {
        echo "Release has no upstream compatibility version; rebuild before packaging." >&2; exit 1;
    }
    for binary in codex codex-code-mode-host bwrap; do
        if readelf -l "$CARGO_TARGET_DIR/$TARGET/release/$binary" | rg -q INTERP \
            || readelf -d "$CARGO_TARGET_DIR/$TARGET/release/$binary" | rg -q NEEDED; then
            echo "$binary has a dynamic loader; refusing to publish." >&2; exit 1
        fi
        if strings "$CARGO_TARGET_DIR/$TARGET/release/$binary" | rg -F "$HOME/" > /dev/null; then
            echo "$binary contains a build-home path; refusing to publish." >&2; exit 1
        fi
    done
    CODEX_REPO_ROOT="$repo" python3 "$repo/scripts/build_codex_package.py" \
        --target "$TARGET" --package-dir "$output/package" --force --strip none \
        --package-version "$version" \
        --entrypoint-bin "$CARGO_TARGET_DIR/$TARGET/release/codex" \
        --code-mode-host-bin "$CARGO_TARGET_DIR/$TARGET/release/codex-code-mode-host" \
        --bwrap-bin "$CARGO_TARGET_DIR/$TARGET/release/bwrap"
    install -m 755 "$repo/scripts/fork.sh" "$output/package/fork.sh"
    cp "$repo/LICENSE" "$repo/NOTICE" "$output/package/"
    git -C "$repo" rev-parse HEAD > "$output/package/revision"
    "$output/package/bin/codex" --version
    "$output/package/bin/codex-code-mode-host" --help >/dev/null
    "$output/package/codex-resources/bwrap" --version
    if readelf -l "$output/package/codex-path/rg" | rg -q INTERP; then
        echo "Packaged ripgrep is not static." >&2; exit 1
    fi
    local archive="codex-fork-$TARGET.tar.gz"
    local tar_args=(--sort=name --owner=0 --group=0 --numeric-owner
        "--mtime=@$(git -C "$repo" show -s --format=%ct HEAD)" -C "$output/package" -cf - .)
    if command -v pigz >/dev/null; then
        tar "${tar_args[@]}" | pigz -1 > "$output/$archive"
    else
        tar "${tar_args[@]}" | gzip -1 > "$output/$archive"
    fi
    (cd "$output" && sha256sum "$archive" > "$archive.sha256")
    cp "$repo/scripts/fork.sh" "$output/fork.sh"
}

case "${1:-publish}" in
    build) build_static ;;
    package) package_static ;;
    publish|publish-built)
        [[ -z "$(git -C "$repo" status --porcelain)" ]] || { echo "Commit changes before publishing." >&2; exit 1; }
        gh auth status >/dev/null 2>&1 || { echo "Run gh auth login before publishing." >&2; exit 1; }
        [[ "${1:-publish}" = publish-built ]] || build_static
        package_static
        revision=$(git -C "$repo" rev-parse HEAD)
        cat > "$output/notes.txt" <<'NOTES'
Static x86-64 Linux bundle: CLI, JavaScript host, bubblewrap, and ripgrep.
Capacity errors retry within the active turn; buffering keeps the composer available.
Install: curl -fsSL https://github.com/redthing1/codex/releases/latest/download/fork.sh | bash
Update/uninstall: ~/.local/share/codex-fork/fork.sh update or uninstall.
NOTES
        gh release create "fork-${revision:0:10}" --repo redthing1/codex --target "$revision" \
            --title "Codex fork ${revision:0:10}" --notes-file "$output/notes.txt" --draft \
            "$output/codex-fork-$TARGET.tar.gz" "$output/codex-fork-$TARGET.tar.gz.sha256" "$output/fork.sh"
        gh release edit "fork-${revision:0:10}" --repo redthing1/codex --draft=false --latest
        ;;
    *) echo "Usage: $0 [build|package|publish|publish-built]" >&2; exit 1 ;;
esac
