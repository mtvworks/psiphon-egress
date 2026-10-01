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
  for t in RUN ADV WD CLI; do
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
              "--accept DE,xyz"; do
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

setup()    { case "$BATS_TEST_DESCRIPTION" in watchdog:*|cli:*) setup_root ;; esac; }
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
  lock="$(grep -n '^flock -w 300 9 ' "$INSTALLER" | cut -d: -f1)"
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
