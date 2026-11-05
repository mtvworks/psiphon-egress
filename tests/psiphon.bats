#!/usr/bin/env bats
# Run with: bats tests
# Nothing here needs root, docker or systemd: the pieces are pulled out of
# psiphon_install.sh and driven with stubs (see helpers.bash).

load helpers

# `! cmd` in the middle of a bats test does not fail it (bash ignores errexit on a
# negated command), so every negative assertion goes through this instead.
refute() { if "$@"; then echo "expected to fail: $*" >&2; return 1; fi; }

# ------------------------------------------------------------------ syntax --

@test "installer and every generated script parse" {
  bash -n "$INSTALLER"
  for t in RUN ADV GEM WD CLI; do
    body="$(heredoc "$t")"
    [ -n "$body" ]
    bash -n <(printf '%s\n' "$body")
  done
}

# ------------------------------------------------------------------ inputs --

@test "cc_list normalises country lists and refuses anything else" {
  eval "$(installer_fn cc_list)"
  [ "$(cc_list 'de,nl')" = "DE NL" ]
  [ "$(cc_list ' de , FR  ')" = "DE FR" ]
  [ "$(cc_list '')" = "" ]
  for bad in 'd' 'DEU' 'DE;rm -rf /' '*'; do
    run cc_list "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "installer refuses bad input before touching the system" {
  for args in "--region d" "--bind 1.2.3.999" "--bind ::1" "--socks-port 0" \
              "--socks-port 70000" "--memory 1x" "--device-region usa" \
              "--tg-token nope" "--tg-chat x-y" "--metrics-dir relative/path" \
              "--accept DE,xyz" "--probe-urls http://plain.example/" \
              "--probe-urls https://x.example/a'b" "--probe-urls https://x.example/\$(id)"; do
    # shellcheck disable=SC2086
    run bash "$INSTALLER" $args
    [ "$status" -eq 1 ]
    [[ "$output" == *ERROR:* ]]
    # Refused by the input checks, not by preflight further down.
    [[ "$output" != *"run as root"* && "$output" != *"not installed"* && "$output" != *"daemon"* ]]
  done
}

# ------------------------------------------------------ reinstall restores --

@test "reinstall without --region keeps the stored region" {
  eval "$(installer_fn cc_list)"
  block="$(sed -n '/^  if \[ "\$REGION_POOL_SET" = 0 \] && \[ -z "\$EGRESS_REGION" \]; then/,/^  fi$/p' "$INSTALLER")"
  [ -n "$block" ]
  ENVF="$(mktemp)"; printf 'EGRESS_REGION=NL\n' > "$ENVF"
  REGION_POOL_SET=0; EGRESS_REGION="";  eval "$block"; [ "$EGRESS_REGION" = NL ]
  REGION_POOL_SET=1; EGRESS_REGION="";  eval "$block"; [ "$EGRESS_REGION" = "" ]
  REGION_POOL_SET=0; EGRESS_REGION=DE;  eval "$block"; [ "$EGRESS_REGION" = DE ]
  rm -f "$ENVF"
}

@test "reinstall keeps the published address and the container ceilings" {
  say() { :; }
  die() { echo "ERROR: $*"; exit 1; }
  eval "$(installer_fn is_ipv4)"
  eval "$(installer_fn restore_bind)"
  eval "$(installer_fn restore_limits)"
  ENVF="$(mktemp)"
  printf 'BIND=127.0.0.1\nMEM_LIMIT=256m\nPIDS_LIMIT=128\nLOG_MAX_SIZE=5m\nLOG_MAX_FILE=2\n' > "$ENVF"
  # Bare reinstall: the stored address, not the gateway default xray does not dial.
  BIND="";         restore_bind; [ "$BIND" = 127.0.0.1 ]
  # --bind / --bind-loopback (or BIND in the environment) still move it.
  BIND=172.17.0.1; restore_bind; [ "$BIND" = 172.17.0.1 ]
  MEM_LIMIT=512m; PIDS_LIMIT=256; LOG_MAX_SIZE=10m; LOG_MAX_FILE=3
  MEM_LIMIT_SET=0; PIDS_LIMIT_SET=0; LOG_MAX_SIZE_SET=0; LOG_MAX_FILE_SET=0
  restore_limits
  [ "$MEM_LIMIT" = 256m ] && [ "$PIDS_LIMIT" = 128 ]
  [ "$LOG_MAX_SIZE" = 5m ] && [ "$LOG_MAX_FILE" = 2 ]
  # --memory wins over the stored ceiling.
  MEM_LIMIT=1g; MEM_LIMIT_SET=1; restore_limits; [ "$MEM_LIMIT" = 1g ]
  # An env from before BIND was recorded leaves the choice to the default.
  printf 'MEM_LIMIT=256m\n' > "$ENVF"; BIND=""; restore_bind; [ -z "$BIND" ]
  # A stored address that is not one is refused, never carried into docker run.
  printf 'BIND=0.0.0.0;id\n' > "$ENVF"; BIND=""
  run restore_bind
  [ "$status" -eq 1 ] && [[ "$output" == *"not an IPv4 address"* ]]
  rm -f "$ENVF"
}

@test "reinstall keeps PROBE_URLS, an emptied one included; an older env gets the default" {
  block="$(sed -n '/^  if \[ "\$PROBE_URLS_SET" = 0 \] && grep -q/,/^  fi$/p' "$INSTALLER")"
  fallback="$(grep -m1 '^\[ "\$PROBE_URLS_SET" = 1 \] || ' "$INSTALLER")"
  dflt="$(grep -m1 '^PROBE_URLS_DEFAULT=' "$INSTALLER")"
  [ -n "$block" ] && [ -n "$fallback" ] && [ -n "$dflt" ]
  eval "$dflt"
  stored() { sed -n "s/^$1=//p" "$ENVF" | head -1 | tr -d "'"; }
  apply() { PROBE_URLS=""; PROBE_URLS_SET=0; eval "$block"; eval "$fallback"; }
  ENVF="$(mktemp)"
  printf "PROBE_URLS='https://a.example/x'\n" > "$ENVF"; apply; [ "$PROBE_URLS" = https://a.example/x ]
  printf "PROBE_URLS=''\n" > "$ENVF";                   apply; [ "$PROBE_URLS" = "" ]
  printf 'NAME=vps-psiphon\n' > "$ENVF";               apply; [ "$PROBE_URLS" = "$PROBE_URLS_DEFAULT" ]
  rm -f "$ENVF"
}

# ------------------------------------------------------------------ verify --

verify_port() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$FAKE_SS"\n' > "$BATS_TEST_TMPDIR/bin/ss"
  chmod +x "$BATS_TEST_TMPDIR/bin/ss"
  FAKE_SS="$1" PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash -c "rc=0; $(cli_fn check_port); check_port 1080 SOCKS5 1; echo rc=\$rc"
}

@test "verify: private and loopback listeners pass" {
  run verify_port "LISTEN 0 4096 172.17.0.1:1080 0.0.0.0:*"
  [[ "$output" == *"rc=0"* ]]
  run verify_port "LISTEN 0 4096 127.0.0.1:1080 0.0.0.0:*"
  [[ "$output" == *"rc=0"* ]]
}

@test "verify: wildcard, public and a second wildcard listener fail" {
  run verify_port "LISTEN 0 4096 0.0.0.0:1080 0.0.0.0:*"
  [[ "$output" == *"WILDCARD"* && "$output" == *"rc=1"* ]]
  run verify_port "LISTEN 0 4096 [::]:1080 [::]:*"
  [[ "$output" == *"WILDCARD"* && "$output" == *"rc=1"* ]]
  run verify_port "LISTEN 0 4096 203.0.113.5:1080 0.0.0.0:*"
  [[ "$output" == *"PUBLIC ADDRESS"* && "$output" == *"rc=1"* ]]
  run verify_port "LISTEN 0 4096 127.0.0.1:1080 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:1080 0.0.0.0:*"
  [[ "$output" == *"WILDCARD"* && "$output" == *"rc=1"* ]]
}

@test "verify: a different port with the same prefix is not a listener" {
  run verify_port "LISTEN 0 4096 127.0.0.1:10800 0.0.0.0:*"
  [[ "$output" == *"MISSING"* && "$output" == *"rc=1"* ]]
}

# ------------------------------------------------------------------ status --

country_verdict() {
  blk="$(heredoc CLI | awk '/^  denied=0; ok=1$/{f=1} f{print} f && /Google.s own verdict about this exit/{g=1} g && /^  fi$/{exit}')"
  bash -c "gl=$1; acc='$2'; DENY_REGIONS='RU BY CN'; EGRESS_REGION='$3'; $blk"
}

@test "status: deny-list is applied first, in every mode" {
  run country_verdict RU "" "";           [[ "$output" == *DENIED* ]]
  run country_verdict RU any "";          [[ "$output" == *DENIED* ]]
  run country_verdict SG "DE NL US" DE;   [[ "$output" == *"NOT ACCEPTED"* ]]
  run country_verdict US "DE NL US" DE;   [[ "$output" == *"accepted"* && "$output" != *NOT* ]]
}

# ---------------------------------------------------------------- watchdog --

setup()    { case "$BATS_TEST_DESCRIPTION" in watchdog:*|cli:*|gemini:*|launcher:*) setup_root ;; esac; }
teardown() { teardown_root; }

@test "watchdog: healthy check logs throughput and writes metrics" {
  run_watchdog
  [ "$status" -eq 0 ]
  wd_log | grep -q 'throughput 2000 KB/s (country DE)'
  refute grep -q 'check failed' "$WDLOG"
  m="$ROOT/metrics/vps-psiphon.prom"
  grep -qx 'vps_psiphon_up 1' "$m"
  grep -qx 'vps_psiphon_check_ok 1' "$m"
  grep -qx 'vps_psiphon_country_info{gl="DE"} 1' "$m"
  grep -qx 'vps_psiphon_rotations_total 0' "$m"
  # Every sample line is "name{labels} number"; no temporary file is left behind.
  refute grep -vE '^(# (HELP|TYPE) .*|[a-z_]+(\{[a-z]+="[A-Z]+"\})? [0-9.]+)$' "$m"
  [ -z "$(find "$ROOT/metrics" -name '.vps-psiphon.prom.*')" ]
}

@test "watchdog: a timed-out fetch that had its response is not a stall" {
  FAKE_YT_W="1500000 200" FAKE_YT_RC=28 run_watchdog
  refute grep -q stalled "$WDLOG"
  wd_log | grep -q 'throughput 1464 KB/s'
}

@test "watchdog: no HTTP response at all is a stall" {
  FAKE_YT_W="0 000" FAKE_YT_RC=28 FAKE_YT_BODY="" run_watchdog
  wd_log | grep -q 'stalled-tunnel'
}

@test "watchdog: a small response that times out is slow once the tunnel is old" {
  FAKE_YT_W="1000 200" FAKE_YT_RC=28 FAKE_YT_BODY='"GL":"DE"' run_watchdog
  wd_log | grep -q 'slow-tunnel (timed out after 25s'
}

@test "watchdog: ...but not judged while the tunnel is still ramping" {
  FAKE_STARTED="$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%S.000000000Z)" \
  FAKE_YT_W="1000 200" FAKE_YT_RC=28 FAKE_YT_BODY='"GL":"DE"' run_watchdog
  wd_log | grep -q 'still ramping, not judged'
  refute grep -q 'check failed' "$WDLOG"
}

@test "watchdog: denied country alerts once, then rotates and alerts again" {
  export FAKE_YT_BODY='"GL":"RU"'
  run_watchdog
  wd_log | grep -q 'denied-country'
  [ "$(grep -c '^TG .*seen as RU' "$STUB_LOG")" -eq 1 ]
  refute grep -q 'systemctl restart' "$STUB_LOG"

  run_watchdog
  [ "$(grep -c '^TG .*seen as RU' "$STUB_LOG")" -eq 1 ]   # not repeated
  grep -q 'systemctl restart vps-psiphon.service' "$STUB_LOG"
  grep -q '^TG .*rotated 203.0.113.9 -> 203.0.113.9, region DE -> NL (denied-country' "$STUB_LOG"
  grep -q '^EGRESS_REGION=NL$' "$ROOT/etc/default/vps-psiphon"
  grep -qx 'vps_psiphon_rotations_total 1' "$ROOT/metrics/vps-psiphon.prom"
  # The state file stays sourceable with a reason full of quotes and parentheses.
  bash -c ". '$ROOT/var/lib/vps-psiphon-watchdog.state'; [ \"\$rotations\" = 1 ] && [[ \"\$last_reason\" == denied-country* ]]"
}

@test "watchdog: a target that refuses the exit alerts once, then rotates" {
  echo "PROBE_URLS='https://gemini.google.com/app'" >> "$ROOT/etc/default/vps-psiphon"
  export FAKE_PROBE=403
  run_watchdog
  grep -q '^PROBE https://gemini.google.com/app$' "$STUB_LOG"
  wd_log | grep -q 'check failed (refused-by-target (gemini.google.com 403 through this exit)), 1 of'
  [ "$(grep -c '^TG .*gemini.google.com 403 through this exit — rotating' "$STUB_LOG")" -eq 1 ]
  grep -qx 'vps_psiphon_target_refused 1' "$ROOT/metrics/vps-psiphon.prom"
  grep -qx 'vps_psiphon_check_ok 0' "$ROOT/metrics/vps-psiphon.prom"
  refute grep -q 'systemctl restart' "$STUB_LOG"

  run_watchdog
  [ "$(grep -c '^TG .*403 through this exit — rotating' "$STUB_LOG")" -eq 1 ]   # not repeated
  grep -q 'systemctl restart vps-psiphon.service' "$STUB_LOG"
  grep -q '^TG .*rotated 203.0.113.9 -> 203.0.113.9, region DE -> NL (refused-by-target (gemini.google.com 403' "$STUB_LOG"
  # Sourceable, and the once-only alert starts over for the new exit.
  bash -c ". '$ROOT/var/lib/vps-psiphon-watchdog.state'; [ -z \"\$refused_seen\" ] && [[ \"\$last_reason\" == refused-by-target* ]]"
}

@test "watchdog: a target that times out, errors or redirects is not judged" {
  echo "PROBE_URLS='https://gemini.google.com/app https://down.example/'" >> "$ROOT/etc/default/vps-psiphon"
  for c in 000 500 302 429; do FAKE_PROBE=$c run_watchdog; done
  grep -q '^PROBE https://down.example/$' "$STUB_LOG"
  refute grep -q 'check failed' "$WDLOG"
  refute grep -q '^TG ' "$STUB_LOG"
  grep -qx 'vps_psiphon_target_refused 0' "$ROOT/metrics/vps-psiphon.prom"
}

@test "watchdog: only the refusing target is named; PROBE_URLS='' turns the check off" {
  echo "PROBE_URLS='https://down.example/ https://gemini.google.com/app?hl=en'" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_PROBE=451 run_watchdog
  wd_log | grep -q 'refused-by-target (gemini.google.com 451 through this exit)'
  grep -q '^PROBE https://gemini.google.com/app?hl=en$' "$STUB_LOG"

  teardown_root; setup_root
  echo "PROBE_URLS=''" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_PROBE=403 run_watchdog
  refute grep -q '^PROBE ' "$STUB_LOG"
  refute grep -q 'check failed' "$WDLOG"
}

@test "watchdog: skips while another command holds the lock" {
  exec 8>"$ROOT/run/vps-psiphon.lock"
  flock -n 8
  run_watchdog
  [ "$status" -eq 0 ]
  wd_log | grep -q 'skipped'
  [ ! -e "$ROOT/var/lib/vps-psiphon-watchdog.state" ]
  exec 8>&-
}

@test "watchdog: no alerts and no metrics when both are off" {
  sed -i "s/^TG_TOKEN=.*/TG_TOKEN=''/; s#^METRICS_DIR=.*#METRICS_DIR=''#" "$ROOT/etc/default/vps-psiphon"
  FAKE_YT_BODY='"GL":"RU"' run_watchdog
  refute grep -q '^TG ' "$STUB_LOG"
  [ ! -e "$ROOT/metrics/vps-psiphon.prom" ]
}

# --------------------------------------------------------------------- cli --

OLD=sha256:1111111111111111111111111111111111111111111111111111111111111111
NEW=sha256:2222222222222222222222222222222222222222222222222222222222222222

R=swarupsengupta2007/psiphon

@test "cli: update-image reports up to date when the digest has not moved" {
  echo "IMAGE=$R:latest@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="$R@$OLD" run_cli update-image
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
  grep -q "docker pull $R:latest\$" "$STUB_LOG"
  refute grep -q 'systemctl restart' "$STUB_LOG"
}

@test "cli: update-image --check shows the new digest and changes nothing" {
  echo "IMAGE=$R:latest@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="$R@$NEW" run_cli update-image --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"available : $R:latest@$NEW"* ]]
  grep -q "^IMAGE=$R:latest@$OLD\$" "$ROOT/etc/default/vps-psiphon"
  refute grep -q 'systemctl restart' "$STUB_LOG"
}

@test "cli: update-image moves the pin, restarts, drops the old digest" {
  echo "IMAGE=$R:latest@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="other/mirror@$NEW
$R@$NEW" run_cli update-image
  [ "$status" -eq 0 ]
  grep -q "^IMAGE=$R:latest@$NEW\$" "$ROOT/etc/default/vps-psiphon"
  grep -q 'systemctl restart vps-psiphon.service' "$STUB_LOG"
  grep -q "docker image rm $R@$OLD" "$STUB_LOG"
}

@test "cli: update-image rolls back and keeps the old build when the new one carries no traffic" {
  echo "IMAGE=$R:latest@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_204=000 FAKE_DIGESTS="$R@$NEW" run_cli update-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"rolling back"* ]]
  grep -q "^IMAGE=$R:latest@$OLD\$" "$ROOT/etc/default/vps-psiphon"
  [ "$(grep -c 'systemctl restart vps-psiphon.service' "$STUB_LOG")" -eq 2 ]
  refute grep -q "docker image rm $R@$OLD" "$STUB_LOG"
}

@test "cli: switching tag removes the old build with the tag still on it, not a moved tag" {
  echo "IMAGE=$R:v2@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  # :v2 still names the old build → both its digest and :v2 go.
  FAKE_IDS="$R@$OLD=id-old
$R:v2=id-old" FAKE_DIGESTS="$R@$NEW" run_cli update-image "$R:v3"
  [ "$status" -eq 0 ]
  grep -q "docker image rm $R:v2\$" "$STUB_LOG"
  grep -q "docker image rm $R@$OLD" "$STUB_LOG"
  # :v2 has moved on to another build → it is left alone.
  : > "$STUB_LOG"
  sed -i "s|^IMAGE=.*|IMAGE=$R:v2@$OLD|" "$ROOT/etc/default/vps-psiphon"
  FAKE_IDS="$R@$OLD=id-old
$R:v2=id-other" FAKE_DIGESTS="$R@$NEW" run_cli update-image "$R:v3"
  refute grep -q "docker image rm $R:v2\$" "$STUB_LOG"
  grep -q "docker image rm $R@$OLD" "$STUB_LOG"
}

@test "cli: update-image keeps following :v2 across updates, never drifting to :latest" {
  echo "IMAGE=$R:v2@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="$R@$NEW" run_cli update-image
  [ "$status" -eq 0 ]
  grep -q "^IMAGE=$R:v2@$NEW\$" "$ROOT/etc/default/vps-psiphon"
  # and again, from the state the first update left behind
  FAKE_DIGESTS="$R@$NEW" run_cli update-image
  [ "$(grep -c "docker pull $R:v2\$" "$STUB_LOG")" -eq 2 ]
  refute grep -q ':latest' "$STUB_LOG"
}

@test "cli: an old env with an unpinned tag follows that tag" {
  echo "IMAGE=registry.local:5000/psiphon:v1" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="registry.local:5000/psiphon@$NEW" run_cli update-image
  grep -q 'docker pull registry.local:5000/psiphon:v1$' "$STUB_LOG"
  grep -q "^IMAGE=registry.local:5000/psiphon:v1@$NEW\$" "$ROOT/etc/default/vps-psiphon"
}

@test "cli: a registry port with no tag is not mistaken for one" {
  echo "IMAGE=registry.local:5000/psiphon@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="registry.local:5000/psiphon@$NEW" run_cli update-image --check
  grep -q 'docker pull registry.local:5000/psiphon:latest$' "$STUB_LOG"
}

@test "cli: update-image REF with a tag switches the followed tag; --check does not" {
  echo "IMAGE=$R:v2@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="$R@$NEW" run_cli update-image --check "$R:v3"
  grep -q "^IMAGE=$R:v2@$OLD\$" "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="$R@$NEW" run_cli update-image "$R:v3"
  [ "$status" -eq 0 ]
  grep -q "^IMAGE=$R:v3@$NEW\$" "$ROOT/etc/default/vps-psiphon"
}

@test "cli: update-image REF as a bare digest pins it and keeps the followed tag" {
  echo "IMAGE=$R:v2@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  run_cli update-image "$R@$NEW"
  [ "$status" -eq 0 ]
  grep -q "docker pull $R@$NEW" "$STUB_LOG"
  grep -q "^IMAGE=$R:v2@$NEW\$" "$ROOT/etc/default/vps-psiphon"
}

@test "cli: update-image with a bare repo pulls the followed tag, not :latest" {
  echo "IMAGE=$R:v2@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="$R@$NEW" run_cli update-image "$R"
  [ "$status" -eq 0 ]
  grep -q "docker pull $R:v2\$" "$STUB_LOG"
  refute grep -q ':latest' "$STUB_LOG"
  grep -q "^IMAGE=$R:v2@$NEW\$" "$ROOT/etc/default/vps-psiphon"
}

@test "cli: an untagged repo@digest env is not told its tag changed" {
  echo "IMAGE=$R@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="$R@$OLD" run_cli update-image
  [ "$status" -eq 0 ]
  [[ "$output" != *following* ]]
  grep -q "^IMAGE=$R:latest@$OLD\$" "$ROOT/etc/default/vps-psiphon"
}

@test "cli: same build under a newly named tag records the tag without a restart" {
  echo "IMAGE=$R:v2@$OLD" >> "$ROOT/etc/default/vps-psiphon"
  FAKE_DIGESTS="$R@$OLD" run_cli update-image "$R:stable"
  [ "$status" -eq 0 ]
  grep -q "^IMAGE=$R:stable@$OLD\$" "$ROOT/etc/default/vps-psiphon"
  refute grep -q 'systemctl restart' "$STUB_LOG"
}

@test "image helpers parse tags, digests and registry ports" {
  eval "$(sed -n '/^img_repo() /,/^}$/p' "$INSTALLER")"
  [ "$(img_repo host:5000/x:v2@sha256:ab)" = host:5000/x ]
  [ "$(img_tag  host:5000/x:v2@sha256:ab)" = v2 ]
  [ "$(img_tag  host:5000/x@sha256:ab)" = latest ]
  [ "$(img_tag  repo/x)" = latest ]
  [ "$(img_canon repo/x:v2@sha256:ab)" = repo/x@sha256:ab ]
  [ "$(img_canon repo/x:v2)" = repo/x:v2 ]
  img_tagged repo/x:v2@sha256:ab
  refute img_tagged host:5000/x@sha256:ab
}

@test "shared functions exist once, and the generated scripts get exactly those" {
  # One definition each in the installer — no hand-kept copy inside a heredoc.
  for f in cc_list img_repo img_tag img_tagged img_digest img_canon; do
    [ "$(grep -c "^$f() " "$INSTALLER")" -eq 1 ]
  done
  # The placeholder the installer fills is present, and rendering leaves none behind.
  [ "$(grep -c '^@@SHARED_FUNCS@@$' "$INSTALLER")" -eq 2 ]
  for t in RUN CLI; do
    out="$(heredoc "$t")"
    refute grep -q '@@SHARED_FUNCS@@' <<<"$out"
    grep -q '^img_canon ()' <<<"$out"
  done
  # And the installer's own substitution does the same as the tests' rendering.
  f="$(mktemp)"; printf 'a\n@@SHARED_FUNCS@@\nb\n' > "$f"
  bash -c "$(sed -n '/^cc_list() {/,/^}/p' "$INSTALLER")
$(sed -n '/^img_repo() /,/^}$/p' "$INSTALLER")
$(sed -n '/^SHARED_FUNCS=/p; /^put_shared_funcs() {/,/^}/p' "$INSTALLER")
put_shared_funcs '$f'"
  grep -q '^img_tag ()' "$f"
  bash -n "$f"
  rm -f "$f"
}

@test "installer takes the lock before it reads or writes the old settings" {
  lock="$(grep -nE '^flock -w [0-9]+ 9 ' "$INSTALLER" | cut -d: -f1)"
  first_read="$(grep -n '"\$ENVF"' "$INSTALLER" | head -1 | cut -d: -f1)"
  restart="$(grep -n '^systemctl restart vps-psiphon.service' "$INSTALLER" | cut -d: -f1)"
  [ -n "$lock" ] && [ -n "$first_read" ] && [ -n "$restart" ]
  [ "$lock" -lt "$first_read" ]
  [ "$lock" -lt "$restart" ]
  # Nothing releases it before the end of the script.
  refute grep -qE '^(flock -u 9|exec 9>&-)' "$INSTALLER"
}

@test "cli: notify-test sends through the same path as the watchdog" {
  run_cli notify-test
  [ "$status" -eq 0 ]
  [ "$output" = sent ]
  grep -q '^TG .*test message' "$STUB_LOG"
}

@test "cli: notify-test says so when alerts are off" {
  sed -i "s/^TG_TOKEN=.*/TG_TOKEN=''/" "$ROOT/etc/default/vps-psiphon"
  run_cli notify-test
  [ "$status" -eq 1 ]
  [[ "$output" == *"alerts are off"* ]]
}

# ------------------------------------------------------------ gemini check --
# Answers in the shapes Gemini sends: a reply placing the exit, a refusal in the frame
# it uses since 2026-11 and in the bare one before, a reply that is Gemini's own error.
GEM_REFUSED_NEW='[["wrb.fr",null,null,null,null,[3,null,[["type.googleapis.com/assistant.boq.bard.application.BardErrorInfo",[1060,null,"Gemini isn'"'"'t available in your region yet. (1060)"]]]]]]'
GEM_REFUSED_OLD='[["wrb.fr",null,null,null,null,[3,null,[["type.googleapis.com/assistant.boq.bard.application.BardErrorInfo",[1060]]]]]]'
GEM_ERROR_REPLY='[["wrb.fr",null,"[null,[\"c_1\",\"r_1\"],{\"11\":[\"Technical Error Encountered\"],\"44\":true}]"]]'

@test "gemini: a reply that places the exit is ok, sent held open over HTTP/2" {
  run_gem
  [ "$status" -eq 0 ]
  [[ "$output" == "ok — Gemini replies, and places this exit in Berlin, Germany" ]]
  grep -q '^GEMPAGE plain socks$' "$STUB_LOG"
  grep -q '^GEMMSG parallel=1 socks .*bl=boq_gemini-web-uiserver_20261103.01_p0&f.sid=-4242&' "$STUB_LOG"
}

@test "gemini: a reply that names no place is ok too, and quotes its head" {
  # As measured from a US datacenter: a real reply, no SWML_DESCRIPTION anywhere.
  FAKE_GEM_OUT='[["wrb.fr",null,"[null,[\"c_8\",\"r_4\"],null,null,[[\"rc_7dd4df53db4a738d\",[\"Hello! How can I help you today?\"],null]]]"]]' run_gem
  [ "$status" -eq 0 ]
  [[ "$output" == 'ok — Gemini replies ("Hello! How can I help you today?…"), naming no place' ]]
}

@test "gemini: error 1060 is a refusal in the new frame and the old one, and decides first" {
  FAKE_GEM_OUT="$GEM_REFUSED_NEW" run_gem
  [ "$status" -eq 1 ] && [[ "$output" == REFUSED* ]]
  FAKE_GEM_OUT="$GEM_REFUSED_OLD" run_gem
  [ "$status" -eq 1 ]
  # A held answer can open with a frame that is not a reply: 1060 still decides.
  FAKE_GEM_OUT='[["wrb.fr",null,"[null,[\"c_1\",\"r_1\"],null,null,[[\"rc_1\",[\"x\"]]],[\"Paris\",\"SWML_DESCRIPTION\"]]"]]'"$GEM_REFUSED_NEW" run_gem
  [ "$status" -eq 1 ]
}

@test "gemini: anything else is inconclusive and says why" {
  FAKE_GEM_PAGE='<html>no fields</html>' run_gem
  [ "$status" -eq 2 ] && [[ "$output" == *"page answered 200, without the session fields"* ]]
  refute grep -q GEMMSG "$STUB_LOG"
  # Only the conversation's ids and title: not a reply.
  FAKE_GEM_OUT="$GEM_ERROR_REPLY" run_gem
  [ "$status" -eq 2 ] && [[ "$output" == "inconclusive (an answer without a reply)" ]]
  FAKE_GEM_OUT='' run_gem
  [ "$status" -eq 2 ] && [[ "$output" == "inconclusive (no reply)" ]]
  # 1096 trails every logged-out reply and refuses nothing.
  FAKE_GEM_OUT='[["e",4]] BardErrorInfo",[1096]' run_gem
  [ "$status" -eq 2 ] && [[ "$output" == *"error 1096"* ]]
  # Session fields that are not plain tokens are not spliced into a URL.
  FAKE_GEM_PAGE='"FdrFJe":"1&x=y","cfb2h":"boq"' run_gem
  [ "$status" -eq 2 ] && [[ "$output" == *"not in the form this check knows"* ]]
}

@test "gemini: a worded refusal is not counted as served" {
  FAKE_GEM_OUT='[["wrb.fr",null,"[null,[\"c_1\",\"r_1\"],null,null,[[\"rc_ab12\",[\"Gemini is not available in your country.\"]]]]"]]' run_gem
  [ "$status" -eq 2 ]
  [[ "$output" == *"reads like a refusal"* ]]
}

@test "gemini: a keep-alive request that ends before the answer is named" {
  FAKE_KEEPALIVE_EARLY=1 FAKE_GEM_OUT='' run_gem
  [ "$status" -eq 2 ]
  [[ "$output" == *"keep-alive request ended before the answer: HTTP 400 after 0.4s"* ]]
  # In the normal order it ends after the message, and nothing is said.
  run_gem
  [ "$status" -eq 0 ] && [[ "$output" != *keep-alive* ]]
}

@test "gemini: a curl without --parallel sends the message alone and says what that costs" {
  FAKE_CURL_OLD=1 FAKE_GEM_OUT="$GEM_REFUSED_NEW" run_gem
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot hold the answer open"* ]]
  grep -q '^GEMMSG parallel=0 ' "$STUB_LOG"
}

@test "gemini: --direct leaves from this host, not through the tunnel" {
  run_gem --direct
  [ "$status" -eq 0 ]
  grep -q '^GEMPAGE plain direct$' "$STUB_LOG"
  grep -q '^GEMMSG parallel=1 direct ' "$STUB_LOG"
}

@test "gemini: with impersonate the page goes as the newest Chrome, and /sorry is a captcha" {
  echo IMPERSONATE=1 >> "$ROOT/etc/default/vps-psiphon"
  fake_impersonate
  run_gem
  [ "$status" -eq 0 ]
  grep -q '^GEMPAGE chrome152 socks$' "$STUB_LOG"
  : > "$STUB_LOG"
  FAKE_GEM_CODE=302 FAKE_GEM_HEAD=$'HTTP/2 302\r\nlocation: https://www.google.com/sorry/index?continue=x\r\n' run_gem
  [ "$status" -eq 3 ] && [[ "$output" == CAPTCHA* ]]
  refute grep -q GEMMSG "$STUB_LOG"
}

@test "gemini: impersonate on without a build falls back to plain curl and says so" {
  echo IMPERSONATE=1 >> "$ROOT/etc/default/vps-psiphon"
  run_gem
  [ "$status" -eq 0 ]
  [[ "$output" == *"no curl-impersonate build is installed"* ]]
  grep -q '^GEMPAGE plain socks$' "$STUB_LOG"
  # Plain curl sent to /sorry is not a browser captcha: the page settles nothing.
  FAKE_GEM_CODE=302 FAKE_GEM_PAGE='' FAKE_GEM_HEAD=$'location: https://www.google.com/sorry/x\r\n' run_gem
  [ "$status" -eq 2 ]
}

# ------------------------------------------------- watchdog: gemini, tunnels --

@test "watchdog: Gemini's refusal rotates on the first check, and says why" {
  export FAKE_GEM_OUT="$GEM_REFUSED_NEW"
  run_watchdog
  wd_log | grep -q 'gemini: REFUSED'
  wd_log | grep -q 'check failed (gemini-refused (error 1060'
  grep -q 'systemctl restart vps-psiphon.service' "$STUB_LOG"
  grep -q '^TG .*rotated .*(gemini-refused' "$STUB_LOG"
  grep -qx 'vps_psiphon_gemini_result 1' "$ROOT/metrics/vps-psiphon.prom"
}

@test "watchdog: a decisive failure still waits for the cooldown, and logs that it waits" {
  printf 'last_rotate=%s\ntunnel=%s\n' "$(( $(date +%s) - 600 ))" "$FAKE_STARTED" > "$ROOT/var/lib/vps-psiphon-watchdog.state"
  FAKE_GEM_OUT="$GEM_REFUSED_NEW" run_watchdog
  refute grep -q 'systemctl restart' "$STUB_LOG"
  wd_log | grep -qE 'rotation due but held: 1[12][0-9]{2}s of the 1800s cooldown left'
}

@test "watchdog: an inconclusive Gemini check judges nothing, and a stale one alerts once" {
  echo GEMINI_STALE_CHECKS=2 >> "$ROOT/etc/default/vps-psiphon"
  export FAKE_GEM_OUT="$GEM_ERROR_REPLY"
  run_watchdog
  refute grep -q 'check failed' "$WDLOG"
  grep -qx 'vps_psiphon_check_ok 1' "$ROOT/metrics/vps-psiphon.prom"
  grep -qx 'vps_psiphon_gemini_result 2' "$ROOT/metrics/vps-psiphon.prom"
  refute grep -q '^TG .*settled nothing' "$STUB_LOG"
  run_watchdog; run_watchdog
  [ "$(grep -c '^TG .*settled nothing for' "$STUB_LOG")" -eq 1 ]
  grep -qx 'vps_psiphon_gemini_inconclusive_streak 3' "$ROOT/metrics/vps-psiphon.prom"
  unset FAKE_GEM_OUT
  run_watchdog
  wd_log | grep -q 'gemini check settles again'
  grep -qx 'vps_psiphon_gemini_inconclusive_streak 0' "$ROOT/metrics/vps-psiphon.prom"
}

@test "watchdog: GEMINI_CHECK=0 does not ask Gemini" {
  echo GEMINI_CHECK=0 >> "$ROOT/etc/default/vps-psiphon"
  run_watchdog
  refute grep -q GEMPAGE "$STUB_LOG"
  refute grep -q 'gemini:' "$WDLOG"
  refute grep -q vps_psiphon_gemini_result "$ROOT/metrics/vps-psiphon.prom"
}

@test "watchdog: the browser captcha rotates with impersonate; a missing build alerts once" {
  echo IMPERSONATE=1 >> "$ROOT/etc/default/vps-psiphon"
  run_watchdog; run_watchdog
  [ "$(grep -c '^TG .*no curl-impersonate build is installed' "$STUB_LOG")" -eq 1 ]
  fake_impersonate
  FAKE_GEM_CODE=302 FAKE_GEM_HEAD=$'location: https://www.google.com/sorry/index\r\n' run_watchdog
  wd_log | grep -q 'check failed (google-captcha'
  grep -q 'systemctl restart vps-psiphon.service' "$STUB_LOG"
}

@test "watchdog: a new tunnel starts with an empty window" {
  # The old tunnel had one slow check; the new one has one too — not two in a row.
  printf 'window=1\nfails=1\ntunnel=2026-01-01T00:00:00Z\n' > "$ROOT/var/lib/vps-psiphon-watchdog.state"
  FAKE_YT_W="200000 200" run_watchdog
  wd_log | grep -q 'new tunnel (started '
  wd_log | grep -q 'slow-tunnel .*1 of the last 1 checks'
  refute grep -q 'systemctl restart' "$STUB_LOG"
  # Same tunnel on the next check: the window carries on and the second slow one rotates.
  FAKE_YT_W="200000 200" run_watchdog
  grep -q 'systemctl restart vps-psiphon.service' "$STUB_LOG"
}

@test "watchdog: a check during which the tunnel restarted is not judged" {
  seq_f="$ROOT/started.seq"
  printf '2026-11-05T10:00:00Z\n2026-11-05T10:00:00Z\n2026-11-05T10:05:00Z\n' > "$seq_f"
  FAKE_STARTED_SEQ="$seq_f" FAKE_GEM_OUT="$GEM_REFUSED_NEW" run_watchdog
  [ "$status" -eq 0 ]
  wd_log | grep -q 'check not judged: the tunnel restarted during it (it read: gemini-refused'
  refute grep -q 'systemctl restart' "$STUB_LOG"
  # Nothing counted: the window is as it was (empty).
  grep -q '^window=$' "$ROOT/var/lib/vps-psiphon-watchdog.state"
}

@test "watchdog: rotations that keep not helping back off, and a passing check ends it" {
  printf 'futile=2\nlast_rotate=0\ntunnel=%s\n' "$FAKE_STARTED" > "$ROOT/var/lib/vps-psiphon-watchdog.state"
  FAKE_GEM_OUT="$GEM_REFUSED_NEW" run_watchdog
  grep -q 'systemctl restart vps-psiphon.service' "$STUB_LOG"
  [ "$(grep -c '^TG .*3 rotations in a row have not brought a passing check' "$STUB_LOG")" -eq 1 ]
  grep -qx 'vps_psiphon_rotation_cooldown_seconds 3600' "$ROOT/metrics/vps-psiphon.prom"
  # 40 minutes on: past the base cooldown, short of the backed-off one.
  sed -i "s/^last_rotate=.*/last_rotate=$(( $(date +%s) - 2400 ))/" "$ROOT/var/lib/vps-psiphon-watchdog.state"
  : > "$STUB_LOG"
  FAKE_GEM_OUT="$GEM_REFUSED_NEW" run_watchdog
  refute grep -q 'systemctl restart' "$STUB_LOG"
  wd_log | grep -q 'of the 3600s cooldown left (backed off after 3 rotations'
  run_watchdog
  wd_log | grep -q 'a check passes again after 3 rotations: the back-off is over'
  grep -qx 'vps_psiphon_rotation_cooldown_seconds 1800' "$ROOT/metrics/vps-psiphon.prom"
}

@test "watchdog: the back-off stops at ROTATE_COOLDOWN_MAX" {
  echo ROTATE_COOLDOWN_MAX=5000 >> "$ROOT/etc/default/vps-psiphon"
  printf 'futile=9\nbackoff_seen=1\nlast_rotate=%s\ntunnel=%s\n' "$(date +%s)" "$FAKE_STARTED" > "$ROOT/var/lib/vps-psiphon-watchdog.state"
  run_watchdog
  grep -qx 'vps_psiphon_rotation_cooldown_seconds 1800' "$ROOT/metrics/vps-psiphon.prom"   # passed: reset
  printf 'futile=9\nbackoff_seen=1\nlast_rotate=%s\ntunnel=%s\n' "$(date +%s)" "$FAKE_STARTED" > "$ROOT/var/lib/vps-psiphon-watchdog.state"
  FAKE_GEM_OUT="$GEM_REFUSED_NEW" run_watchdog
  grep -qx 'vps_psiphon_rotation_cooldown_seconds 5000' "$ROOT/metrics/vps-psiphon.prom"
}


@test "watchdog: each tunnel the client brings up is logged once, with its protocol" {
  db="$ROOT/config/ca.psiphon.PsiphonTunnel.tunnel-core/datastore"
  mkdir -p "$db"
  now_ts="$(date -u +%Y-%m-%dT%H:%M:%S.123456789Z)"
  printf '\0\1{"LastUsedTimestamp":"%s","Region":"DE","TunnelProtocol":"QUIC-OSSH"}\0{"LastUsedTimestamp":"2020-01-01T00:00:00.1Z","TunnelProtocol":"INPROXY-WEBRTC-OSSH"}' \
    "$now_ts" > "$db/psiphon.boltdb"
  run_watchdog
  [ "$(grep -c 'tunnel up: QUIC-OSSH' "$WDLOG")" -eq 1 ]
  refute grep -q 'INPROXY' "$WDLOG"   # older than the container: not this tunnel's
  run_watchdog
  [ "$(grep -c 'tunnel up: ' "$WDLOG")" -eq 1 ]
}

# ---------------------------------------------------------------- launcher --





@test "watchdog: a config the launcher could not edit is alerted once and exported" {
  echo "$(date +%s) unedited" > "$ROOT/var/lib/vps-psiphon-run.state"
  run_watchdog; run_watchdog
  [ "$(grep -c '^TG .*in-proxy is NOT kept out' "$STUB_LOG")" -eq 1 ]
  grep -qx 'vps_psiphon_inproxy_excluded 0' "$ROOT/metrics/vps-psiphon.prom"
  echo "$(date +%s) no-inproxy" > "$ROOT/var/lib/vps-psiphon-run.state"
  run_watchdog
  grep -qx 'vps_psiphon_inproxy_excluded 1' "$ROOT/metrics/vps-psiphon.prom"
}

@test "watchdog: a check not judged still keeps its once-only alerts sent" {
  echo "$(date +%s) unedited" > "$ROOT/var/lib/vps-psiphon-run.state"
  seq_f="$ROOT/started.seq"
  printf '2026-11-05T10:00:00Z\n2026-11-05T10:00:00Z\n2026-11-05T10:05:00Z\n' > "$seq_f"
  FAKE_STARTED_SEQ="$seq_f" run_watchdog
  wd_log | grep -q 'check not judged'
  # Saved under the tunnel the check began on: the next check sees a new one.
  grep -q "^tunnel=2026-11-05T10:00:00Z$" "$ROOT/var/lib/vps-psiphon-watchdog.state"
  FAKE_STARTED=2026-11-05T10:05:00Z run_watchdog
  [ "$(grep -c '^TG .*in-proxy is NOT kept out' "$STUB_LOG")" -eq 1 ]
}

# ---------------------------------------------------------------- launcher --

launcher_mode() { awk '{print $2}' "$ROOT/var/lib/vps-psiphon-run.state"; }

@test "launcher: seeds the config from the image and turns tactics off, once" {
  t="$ROOT/template.json"; psiphon_template > "$t"
  FAKE_TEMPLATE="$t" run_launcher
  [ "$status" -eq 0 ]
  c="$ROOT/config/psiphon.config"
  grep -q '"LocalSocksProxyPort": 1080' "$c"
  grep -q '"LocalHttpProxyPort": 8080' "$c"
  grep -q '"EgressRegion": "DE"' "$c"
  grep -q '"DeviceRegion": "DE"' "$c"
  [ "$(grep -c '"DisableTactics": true' "$c")" -eq 1 ]
  # No protocol list: it adds nothing to tactics off, and a name the build does not
  # know would stop the client from starting.
  refute grep -q LimitTunnelProtocols "$c"
  jq -e '.DisableTactics == true and .UseIndistinguishableTLS == true' "$c"
  [ "$(launcher_mode)" = no-inproxy ]
  grep -q '^docker run --rm --name vps-psiphon .* repo/psiphon@sha256:0123$' "$STUB_LOG"
  # Every start after: still one line, the file not rewritten.
  before="$(stat -c %i "$c")"
  run_launcher; run_launcher
  [ "$(grep -c '"DisableTactics"' "$c")" -eq 1 ]
  [ "$(stat -c %i "$c")" = "$before" ]
  jq -e . "$c" >/dev/null
}

@test "launcher: auto is seeded as no region, not as the template's SG" {
  t="$ROOT/template.json"; psiphon_template > "$t"
  sed -i 's/^EGRESS_REGION=.*/EGRESS_REGION=/' "$ROOT/etc/default/vps-psiphon"
  FAKE_TEMPLATE="$t" run_launcher
  grep -q '"EgressRegion": ""' "$ROOT/config/psiphon.config"
}

@test "launcher: --inproxy takes its line out and leaves the image's config as it was" {
  psiphon_template > "$ROOT/config/psiphon.config"
  c="$ROOT/config/psiphon.config"
  run_launcher
  grep -q '"DisableTactics"' "$c"
  echo EXCLUDE_INPROXY=0 >> "$ROOT/etc/default/vps-psiphon"
  run_launcher
  [ "$(launcher_mode)" = psiphon-default ]
  diff <(psiphon_template) "$c"
}

@test "launcher: a protocol list in its own (or upstream's) form is removed, a hand-written one is not" {
  c="$ROOT/config/psiphon.config"
  # The form this launcher and upstream's wrote: one line, one space of indent.
  { echo '{'; echo ' "LimitTunnelProtocols": ["SSH", "OSSH"],'; echo ' "DisableTactics": true,'; psiphon_template | sed 1d; } > "$c"
  run_launcher
  refute grep -q LimitTunnelProtocols "$c"
  [ "$(grep -c '"DisableTactics"' "$c")" -eq 1 ]
  jq -e . "$c" >/dev/null
  # Written by hand over several lines: not the launcher's, left whole — the file stays JSON.
  { echo '{'; echo '  "LimitTunnelProtocols": ['; echo '    "OSSH",'; echo '    "QUIC-OSSH"'; echo '  ],'; psiphon_template | sed 1d; } > "$c"
  run_launcher
  jq -e '.LimitTunnelProtocols == ["OSSH", "QUIC-OSSH"] and .DisableTactics == true' "$c"
}

@test "launcher: a config it cannot read, or cannot edit, is left alone and the tunnel still starts" {
  c="$ROOT/config/psiphon.config"
  printf '{"weird": true}\n' > "$c"
  run_launcher
  [ "$status" -eq 0 ]
  [[ "$output" == *"not in the shape this launcher edits"* ]]
  [ "$(cat "$c")" = '{"weird": true}' ]
  [ "$(launcher_mode)" = unedited ]
  grep -q '^docker run --rm --name vps-psiphon ' "$STUB_LOG"
  # A failing edit (here: cp cannot write next to the config) does not stop the start.
  psiphon_template > "$c"
  mkdir -p "$ROOT/bin2"; printf '#!/bin/sh\nexit 1\n' > "$ROOT/bin2/cp"; chmod +x "$ROOT/bin2/cp"
  : > "$STUB_LOG"
  PATH="$ROOT/bin2:$PATH" run_launcher
  [ "$status" -eq 0 ]
  [ "$(launcher_mode)" = unedited ]
  grep -q '^docker run --rm --name vps-psiphon ' "$STUB_LOG"
}

@test "launcher: no template to seed from leaves the setting for the next start" {
  run_launcher
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/config/psiphon.config" ]
  [ "$(launcher_mode)" = pending ]
  grep -q '^docker run --rm --name vps-psiphon ' "$STUB_LOG"
}

# ------------------------------------------------------- installer: switches --

@test "reinstall keeps the Gemini, impersonate and in-proxy switches; flags win" {
  eval "$(installer_fn restore_switches)"
  ENVF="$(mktemp)"
  printf 'GEMINI_CHECK=0\nIMPERSONATE=1\nEXCLUDE_INPROXY=0\n' > "$ENVF"
  GEMINI_CHECK=1; IMPERSONATE=0; EXCLUDE_INPROXY=1
  GEMINI_CHECK_SET=0; IMPERSONATE_SET=0; EXCLUDE_INPROXY_SET=0
  restore_switches
  [ "$GEMINI_CHECK" = 0 ] && [ "$IMPERSONATE" = 1 ] && [ "$EXCLUDE_INPROXY" = 0 ]
  GEMINI_CHECK=1; GEMINI_CHECK_SET=1; IMPERSONATE=0; IMPERSONATE_SET=1
  restore_switches
  [ "$GEMINI_CHECK" = 1 ] && [ "$IMPERSONATE" = 0 ]
  # Anything but 0 or 1 was not written by the installer and is not taken back.
  printf 'GEMINI_CHECK=$(id)\nIMPERSONATE=yes\n' > "$ENVF"
  GEMINI_CHECK=1; GEMINI_CHECK_SET=0; IMPERSONATE=0; IMPERSONATE_SET=0
  restore_switches
  [ "$GEMINI_CHECK" = 1 ] && [ "$IMPERSONATE" = 0 ]
  rm -f "$ENVF"
}

# --------------------------------------------- installer: curl-impersonate --

# A release as GitHub serves it: the redirect to the tag, the asset list with digests,
# the tarball. FAKE_REL_* steer it; downloads are recorded as "GET <asset>".
impersonate_env() {
  W="$BATS_TEST_TMPDIR"; mkdir -p "$W/bin" "$W/rel/x"
  printf '#!/bin/sh\necho "curl-impersonate 8.x"\n' > "$W/rel/x/curl-impersonate"
  printf '#!/bin/sh\nexec "${0%%/*}/curl-impersonate" "$@"\n' > "$W/rel/x/curl_chrome152"
  chmod +x "$W/rel/x/"*
  tar -czf "$W/rel/good.tar.gz" -C "$W/rel/x" .
  rm "$W/rel/x/curl_chrome152"
  tar -czf "$W/rel/nochrome.tar.gz" -C "$W/rel/x" .
  printf '#!/bin/sh\necho x86_64\n' > "$W/bin/uname"
  printf '#!/bin/sh\necho "ldd (GNU libc) 2.39"\n' > "$W/bin/ldd"
  cat > "$W/bin/curl" <<'C'
#!/usr/bin/env bash
out=""; url=""; w=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -w) w="$2"; shift 2 ;; --max-time) shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac
done
case "$url" in
  */releases/latest)
    [ -n "${FAKE_REL_TAG:-}" ] && [ "$w" = '%{redirect_url}' ] \
      && printf 'https://github.com/lexiforest/curl-impersonate/releases/tag/%s' "$FAKE_REL_TAG"
    exit 0 ;;
  */expanded_assets/*)
    [ -n "${FAKE_REL_SUM:-}" ] || exit 22
    printf '<clipboard-copy value="sha256:%s" aria-label="Copy to clipboard digest for curl-impersonate-%s.x86_64-linux-gnu.tar.gz">' \
      "$FAKE_REL_SUM" "$FAKE_REL_TAG" ;;
  */releases/download/*)
    echo "GET ${url##*/}" >> "$W/get.log"
    [ -n "${FAKE_REL_FILE:-}" ] || exit 22
    cp "$FAKE_REL_FILE" "$out" ;;
esac
C
  chmod +x "$W/bin/"*
  export W
  eval "$(sed -n '/^CI_REPO=/p; /^CI_PIN=/p' "$INSTALLER")"
  eval "$(installer_fn ci_pin_sum)"; eval "$(installer_fn ci_fetch)"; eval "$(installer_fn impersonate_install)"
  CI_DIR="$W/opt/curl-impersonate"
  PATH="$W/bin:$PATH"
}

@test "impersonate: the latest release is fetched, checked and installed" {
  impersonate_env
  sum="$(sha256sum "$W/rel/good.tar.gz" | cut -d' ' -f1)"
  FAKE_REL_TAG=v9.9.9 FAKE_REL_SUM="$sum" FAKE_REL_FILE="$W/rel/good.tar.gz" run impersonate_install
  [ "$status" -eq 0 ]
  [[ "$output" == "v9.9.9 (curl-impersonate-v9.9.9.x86_64-linux-gnu.tar.gz, sha256 ${sum:0:12}…)" ]]
  [ -x "$CI_DIR/curl_chrome152" ] && [ "$(cat "$CI_DIR/VERSION")" = v9.9.9 ]
}

@test "impersonate: a bad latest falls back to the pin, and a failure leaves the build in place" {
  impersonate_env
  mkdir -p "$CI_DIR"; echo old > "$CI_DIR/VERSION"
  # Digest mismatch on the latest; the pin is tried and (being a fake) fails its digest too.
  FAKE_REL_TAG=v9.9.9 FAKE_REL_SUM="$(printf '0%.0s' {1..64})" FAKE_REL_FILE="$W/rel/good.tar.gz" run impersonate_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match its sha256; the pinned v2.3.2 failed too: curl-impersonate-v2.3.2.x86_64-linux-gnu.tar.gz does not match its sha256"* ]]
  grep -q 'GET curl-impersonate-v2.3.2.x86_64-linux-gnu.tar.gz' "$W/get.log"
  [ "$(cat "$CI_DIR/VERSION")" = old ]
  # Unreadable release page, or a tag that is not one: straight to the pin.
  : > "$W/get.log"
  FAKE_REL_TAG='v1;rm -rf /' run impersonate_install
  [ "$status" -eq 1 ]
  [[ "$output" == "could not read the latest release or its digest for x86_64-linux-gnu;"* ]]
  [ "$(cat "$W/get.log")" = "GET curl-impersonate-v2.3.2.x86_64-linux-gnu.tar.gz" ]
}

@test "impersonate: a build of the same release is kept without a download" {
  impersonate_env
  mkdir -p "$CI_DIR"; printf '#!/bin/sh\n' > "$CI_DIR/curl-impersonate"; chmod +x "$CI_DIR/curl-impersonate"
  echo v9.9.9 > "$CI_DIR/VERSION"
  FAKE_REL_TAG=v9.9.9 FAKE_REL_SUM=x run impersonate_install
  [ "$status" -eq 0 ] && [ "$output" = "v9.9.9, already installed" ]
  [ ! -e "$W/get.log" ]
  # The latest unknown and the pin installed: kept as well.
  echo v2.3.2 > "$CI_DIR/VERSION"
  run impersonate_install
  [ "$status" -eq 0 ] && [[ "$output" == "v2.3.2, already installed — the pinned release"* ]]
  [ ! -e "$W/get.log" ]
}

@test "impersonate: a release without a Chrome profile is refused" {
  impersonate_env
  sum="$(sha256sum "$W/rel/nochrome.tar.gz" | cut -d' ' -f1)"
  FAKE_REL_TAG=v9.9.9 FAKE_REL_SUM="$sum" FAKE_REL_FILE="$W/rel/nochrome.tar.gz" run impersonate_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds no working curl-impersonate with a Chrome profile"* ]]
  [ ! -e "$CI_DIR" ]
}

@test "impersonate: the build is root's alone, whatever owner and mode the archive carries" {
  impersonate_env
  # As the v2.3.2 assets are: files of uid 1001; and group/other-writable for good measure.
  mkdir -p "$W/rel/y"; tar -xzf "$W/rel/good.tar.gz" -C "$W/rel/y"
  tar --owner=1001 --group=1001 --mode=0777 -czf "$W/rel/foreign.tar.gz" -C "$W/rel/y" .
  sum="$(sha256sum "$W/rel/foreign.tar.gz" | cut -d' ' -f1)"
  FAKE_REL_TAG=v9.9.9 FAKE_REL_SUM="$sum" FAKE_REL_FILE="$W/rel/foreign.tar.gz" run impersonate_install
  [ "$status" -eq 0 ]
  [ -z "$(find "$CI_DIR" -perm /022 -print -quit)" ]
  if [ "$(id -u)" = 0 ]; then [ -z "$(find "$CI_DIR" ! -uid 0 -print -quit)" ]; fi
}

@test "impersonate: an archive carrying a link is refused" {
  impersonate_env
  mkdir -p "$W/rel/l"; tar -xzf "$W/rel/good.tar.gz" -C "$W/rel/l"; ln -s /etc/passwd "$W/rel/l/evil"
  tar -czf "$W/rel/link.tar.gz" -C "$W/rel/l" .
  sum="$(sha256sum "$W/rel/link.tar.gz" | cut -d' ' -f1)"
  FAKE_REL_TAG=v9.9.9 FAKE_REL_SUM="$sum" FAKE_REL_FILE="$W/rel/link.tar.gz" run impersonate_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be unpacked as plain root-owned files"* ]]
}

@test "impersonate: a swap that fails keeps the installed build and says so" {
  impersonate_env
  mkdir -p "$CI_DIR"; echo old > "$CI_DIR/VERSION"
  sum="$(sha256sum "$W/rel/good.tar.gz" | cut -d' ' -f1)"
  # mv fails once the new build is to take the old one's place — as on a full /opt.
  printf '#!/bin/sh\ncase "$1" in *curl-impersonate.new) exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$W/bin/mv"
  chmod +x "$W/bin/mv"
  FAKE_REL_TAG=v9.9.9 FAKE_REL_SUM="$sum" FAKE_REL_FILE="$W/rel/good.tar.gz" run impersonate_install
  rm -f "$W/bin/mv"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not put the new build in place"* ]]
  [ "$(cat "$CI_DIR/VERSION")" = old ]
  [ ! -e "$CI_DIR.new" ] && [ ! -e "$CI_DIR.old" ]
}

@test "impersonate: every pinned digest is a sha256" {
  eval "$(installer_fn ci_pin_sum)"
  for p in aarch64-linux-gnu aarch64-linux-musl arm-linux-gnueabihf i386-linux-gnu \
           riscv64-linux-gnu x86_64-linux-gnu x86_64-linux-musl; do
    ci_pin_sum "$p" | grep -qxE '[0-9a-f]{64}'
  done
  [ -z "$(ci_pin_sum mips-linux-gnu)" ]
}
