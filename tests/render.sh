#!/usr/bin/env bash
# Prints one generated script (RUN, ADV, WD, CLI) the way the installer writes it: the
# body of its heredoc, with @@SHARED_FUNCS@@ replaced by the installer's own
# definitions, exactly as put_shared_funcs does. Used by lint.sh and the bats tests.
set -euo pipefail
installer="$(cd "$(dirname "$0")/.." && pwd)/psiphon_install.sh"
tag="${1:?usage: render.sh RUN|ADV|WD|CLI}"
# The installer defines them at the top level, one copy each.
eval "$(sed -n '/^cc_list() {/,/^}/p' "$installer")"
eval "$(sed -n '/^img_repo() /,/^}$/p' "$installer")"
SHARED_FUNCS="$(declare -f cc_list img_repo img_tag img_tagged img_digest img_canon)"
export SHARED_FUNCS
body="$(awk -v t="$tag" '$0 ~ "<<\x27"t"\x27$" {f=1; next} $0==t {f=0} f' "$installer")"
[ -n "$body" ] || { echo "heredoc $tag not found in $installer" >&2; exit 1; }
printf '%s\n' "$body" \
  | awk '$0 == "@@SHARED_FUNCS@@" { print ENVIRON["SHARED_FUNCS"]; next } { print }'
