#!/usr/bin/env bash
# Exercise installation/restoration in isolation, without compiling Rust.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export CODEX_FORK_HOME="$tmp/state" CARGO_TARGET_DIR="$tmp/target" CODEX_FORK_BIN="$tmp/bin/codex"
mkdir -p "$tmp/bin" "$tmp/target/release"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/cargo"
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$tmp/target/release/codex"
cp "$tmp/bin/cargo" "$tmp/target/release/codex-code-mode-host"
cp "$tmp/bin/cargo" "$tmp/target/release/bwrap"
printf '#!/bin/sh\necho upstream\n' > "$tmp/bin/upstream"
chmod +x "$tmp/bin/cargo" "$tmp/bin/upstream" "$tmp/target/release/"*
export PATH="$tmp/bin:$PATH"
ln -s upstream "$CODEX_FORK_BIN"

"$repo/scripts/fork.sh" install-built >/dev/null
[[ "$(readlink "$CODEX_FORK_BIN")" = "$CODEX_FORK_HOME/launch" ]]
[[ "$(readlink "$CODEX_FORK_BIN.codex-upstream")" = upstream ]]
args=$("$CODEX_FORK_BIN" exec 'argument with spaces')
[[ "$args" = $'--no-daemon\n-c\ncheck_for_update_on_startup=false\nexec\nargument with spaces' ]]
"$repo/scripts/fork.sh" install-built >/dev/null
[[ "$(readlink "$CODEX_FORK_BIN.codex-upstream")" = upstream ]]
"$repo/scripts/fork.sh" uninstall >/dev/null
[[ "$(readlink "$CODEX_FORK_BIN")" = upstream ]]
[[ "$("$CODEX_FORK_BIN")" = upstream ]]
"$repo/scripts/fork.sh" uninstall >/dev/null

# A package-manager update can replace the entrypoint; uninstall must leave it alone.
"$repo/scripts/fork.sh" install-built >/dev/null
rm "$CODEX_FORK_BIN"
cp "$tmp/bin/upstream" "$CODEX_FORK_BIN"
"$repo/scripts/fork.sh" uninstall >/dev/null
[[ ! -L "$CODEX_FORK_BIN" && "$("$CODEX_FORK_BIN")" = upstream ]]

# Refresh the backup after an external update, then restore the updated entrypoint.
"$repo/scripts/fork.sh" install-built >/dev/null
rm "$CODEX_FORK_BIN"
printf '#!/bin/sh\necho updated-upstream\n' > "$CODEX_FORK_BIN"
chmod +x "$CODEX_FORK_BIN"
"$repo/scripts/fork.sh" install-built >/dev/null
"$repo/scripts/fork.sh" uninstall >/dev/null
[[ "$("$CODEX_FORK_BIN")" = updated-upstream ]]

rm "$CODEX_FORK_BIN"
"$repo/scripts/fork.sh" install-built >/dev/null
"$repo/scripts/fork.sh" uninstall >/dev/null
[[ ! -e "$CODEX_FORK_BIN" && ! -L "$CODEX_FORK_BIN" ]]

# Download installation also works from stdin, without a checkout or compiler.
export FORK_TEST_FIXTURES="$tmp/fixtures"
mkdir -p "$FORK_TEST_FIXTURES/package/bin" "$FORK_TEST_FIXTURES/package/codex-resources" "$FORK_TEST_FIXTURES/package/codex-path"
cp "$tmp/target/release/codex" "$tmp/target/release/codex-code-mode-host" "$FORK_TEST_FIXTURES/package/bin/"
cp "$tmp/target/release/bwrap" "$FORK_TEST_FIXTURES/package/codex-resources/"
cp "$repo/scripts/fork.sh" "$FORK_TEST_FIXTURES/package/fork.sh"
echo prebuilt-test > "$FORK_TEST_FIXTURES/package/revision"
asset=codex-fork-x86_64-unknown-linux-musl.tar.gz
tar -C "$FORK_TEST_FIXTURES/package" -czf "$FORK_TEST_FIXTURES/$asset" .
(cd "$FORK_TEST_FIXTURES" && sha256sum "$asset" > "$asset.sha256")
cat > "$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
    case "$1" in
        -o) destination=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
if [[ "$url" = */releases/latest ]]; then
    echo https://github.com/redthing1/codex/releases/tag/fork-test
else
    cp "$FORK_TEST_FIXTURES/${url##*/}" "$destination"
fi
CURL
chmod +x "$tmp/bin/curl"
ln -s upstream "$CODEX_FORK_BIN"
bash < "$repo/scripts/fork.sh" >/dev/null
[[ "$(cat "$CODEX_FORK_HOME/current/revision")" = prebuilt-test ]]
before=$(readlink "$CODEX_FORK_HOME/current")
printf '%064d  %s\n' 0 "$asset" > "$FORK_TEST_FIXTURES/$asset.sha256"
if "$repo/scripts/fork.sh" update >/dev/null 2>&1; then
    echo "Bad checksum was accepted" >&2; exit 1
fi
[[ "$(readlink "$CODEX_FORK_HOME/current")" = "$before" ]]
"$CODEX_FORK_HOME/fork.sh" uninstall >/dev/null
[[ "$(readlink "$CODEX_FORK_BIN")" = upstream ]]
echo "Fork install/reinstall/update/uninstall tests passed."

# Packaging must refuse stale binaries or an uncommitted checkout before touching them.
mkdir -p "$tmp/repo/scripts" "$CARGO_TARGET_DIR/fork-release"
cp "$repo/scripts/fork-release.sh" "$tmp/repo/scripts/"
git -C "$tmp/repo" init -q
git -C "$tmp/repo" add .
git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
echo stale > "$CARGO_TARGET_DIR/fork-release/build-revision"
if "$tmp/repo/scripts/fork-release.sh" package > "$tmp/error" 2>&1; then exit 1; fi
rg -q 'Release binaries do not match' "$tmp/error"
git -C "$tmp/repo" rev-parse HEAD > "$CARGO_TARGET_DIR/fork-release/build-revision"
touch "$tmp/repo/uncommitted"
if "$tmp/repo/scripts/fork-release.sh" package > "$tmp/error" 2>&1; then exit 1; fi
rg -q 'Release binaries do not match' "$tmp/error"
echo "Release revision guards passed."
