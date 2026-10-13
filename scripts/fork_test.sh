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
echo "Fork install/reinstall/update/uninstall tests passed."
