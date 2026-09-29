#!/usr/bin/env bash
# Lints the installer and every script it writes. The generated ones
# live as heredocs, which shellcheck sees only as text, so they are rendered first.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for t in RUN ADV WD CLI; do
  bash tests/render.sh "$t" > "$tmp/$t.sh"
done
shellcheck -S warning -s bash psiphon_install.sh tests/lint.sh tests/render.sh "$tmp"/*.sh
# helpers.bash sets variables the .bats file reads, which shellcheck cannot see.
shellcheck -S warning -s bash -e SC2030,SC2031,SC2034 tests/helpers.bash
echo "shellcheck: clean"
