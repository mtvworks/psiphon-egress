#!/usr/bin/env bash
# Lints the installer and every script it writes. The generated ones
# live as heredocs, which shellcheck sees only as text, so they are extracted first.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for t in RUN ADV WD CLI; do
  awk -v t="$t" '$0 ~ "<<\x27"t"\x27$" {f=1; next} $0==t {f=0} f' psiphon_install.sh > "$tmp/$t.sh"
  [ -s "$tmp/$t.sh" ] || { echo "heredoc $t not found in psiphon_install.sh" >&2; exit 1; }
done
shellcheck -S warning -s bash psiphon_install.sh tests/lint.sh "$tmp"/*.sh
# helpers.bash sets variables the .bats file reads, which shellcheck cannot see.
shellcheck -S warning -s bash -e SC2030,SC2031,SC2034 tests/helpers.bash
echo "shellcheck: clean"
