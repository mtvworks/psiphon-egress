# Shared by tests/*.bats. The installer writes its helper scripts as heredocs, so the
# tests pull them out of psiphon_install.sh and run them against a scratch root with
# stub binaries, rather than keeping a second copy that could drift from the real one.

REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
INSTALLER="$REPO/psiphon_install.sh"

# Body of the heredoc `cat > … <<'TAG'` … `TAG`.
heredoc() {
  awk -v t="$1" '$0 ~ "<<\x27"t"\x27$" {f=1; next} $0==t {f=0} f' "$INSTALLER"
}

# A top-level function of the installer, `name() {` through the first `}` at column 0.
installer_fn() {
  sed -n "/^$1() {/,/^}/p" "$INSTALLER"
}

# A function defined inside the CLI heredoc, indented by four spaces.
cli_fn() {
  heredoc CLI | sed -n "/^    $1() {/,/^    }\$/p"
}

# Scratch root: every absolute path the generated scripts touch is moved under $ROOT,
# and the binaries they call are stubbed through $ROOT/bin.
setup_root() {
  ROOT="$(mktemp -d)"
  mkdir -p "$ROOT/etc/default" "$ROOT/var/log" "$ROOT/var/lib" "$ROOT/run" \
           "$ROOT/usr/local/sbin" "$ROOT/bin" "$ROOT/metrics"
  STUB_LOG="$ROOT/calls.log"; : > "$STUB_LOG"
  export ROOT STUB_LOG
  for t in WD ADV CLI; do
    heredoc "$t" | sed -e "s#/etc/default/#$ROOT/etc/default/#g" \
                       -e "s#/var/log/#$ROOT/var/log/#g" \
                       -e "s#/var/lib/#$ROOT/var/lib/#g" \
                       -e "s#/run/#$ROOT/run/#g" \
                       -e "s#/usr/local/sbin/#$ROOT/usr/local/sbin/#g" \
      > "$ROOT/$t.sh"
  done
  cp "$ROOT/ADV.sh" "$ROOT/usr/local/sbin/vps-psiphon-advance-region"
  chmod +x "$ROOT/usr/local/sbin/vps-psiphon-advance-region"
  write_env
  write_stubs
  PATH="$ROOT/bin:$PATH"
}

teardown_root() { if [ -n "${ROOT:-}" ]; then rm -rf "$ROOT"; fi; }

write_env() {
  cat > "$ROOT/etc/default/vps-psiphon" <<EOF
NAME=vps-psiphon
BIND=127.0.0.1
SOCKS_PORT=1080
EGRESS_REGION=DE
CONF_DIR=$ROOT/config
FAIL_THRESHOLD=2
FAIL_WINDOW=5
ROTATE_COOLDOWN=1800
OK_REGIONS=
DENY_REGIONS='RU BY'
MIN_THROUGHPUT_KBPS=800
THROUGHPUT_GRACE_SEC=900
REGION_POOL='DE NL'
ACCEPT_REGIONS=''
TG_TOKEN='123:abc'
TG_CHAT='42'
METRICS_DIR='$ROOT/metrics'
EOF
}

# curl is driven by FAKE_* variables:
#   FAKE_204      liveness status          (default 204)
#   FAKE_YT_W     -w output of the YouTube fetch   (default "2048000 200")
#   FAKE_YT_RC    its exit status                  (default 0)
#   FAKE_YT_BODY  its body                         (default 60 KB carrying GL DE)
#   FAKE_IP       ipify answer                     (default 203.0.113.9)
# Telegram calls are recorded in $STUB_LOG as "TG <text>".
write_stubs() {
  cat > "$ROOT/bin/curl" <<'C'
#!/usr/bin/env bash
out=""; url=""; data=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|--max-time|-H|--socks5-hostname) shift 2 ;;
    --data-urlencode) data+=("$2"); shift 2 ;;
    -K) url="$(sed -n 's/^url = "\(.*\)"$/\1/p')"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *api.telegram.org*)
    for d in "${data[@]}"; do case "$d" in text=*) echo "TG ${d#text=}" >> "$STUB_LOG" ;; esac; done
    printf 200 ;;
  *generate_204*) printf '%s' "${FAKE_204:-204}" ;;
  *youtube*)
    if [ -n "$out" ]; then
      if [ -n "${FAKE_YT_BODY+x}" ]; then printf '%s' "$FAKE_YT_BODY" > "$out"
      else { printf '"GL":"DE"'; head -c 60000 /dev/zero | tr '\0' x; } > "$out"; fi
    fi
    printf '%s' "${FAKE_YT_W:-2048000 200}"
    exit "${FAKE_YT_RC:-0}" ;;
  *ipify*) printf '%s' "${FAKE_IP:-203.0.113.9}" ;;
  *google.com/search*) : ;;
esac
exit 0
C
  cat > "$ROOT/bin/docker" <<'D'
#!/usr/bin/env bash
# inspect -f {{.State.StartedAt}} → FAKE_STARTED (default: an hour ago)
# image inspect → FAKE_DIGESTS (the RepoDigests lines); pull, image rm → recorded
case "$1" in
  inspect) echo "${FAKE_STARTED:-$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000000000Z)}" ;;
  pull)    echo "docker pull ${*: -1}" >> "$STUB_LOG" ;;
  image)
    case "$2" in
      inspect) printf '%s\n' "${FAKE_DIGESTS:-}" ;;
      rm)      echo "docker image rm ${*: -1}" >> "$STUB_LOG" ;;
    esac ;;
esac
exit 0
D
  printf '#!/bin/sh\necho "systemctl $*" >> "$STUB_LOG"\n' > "$ROOT/bin/systemctl"
  printf '#!/bin/sh\n:\n' > "$ROOT/bin/sleep"
  chmod +x "$ROOT/bin/"*
}

run_watchdog() { run bash "$ROOT/WD.sh"; WDLOG="$ROOT/var/log/vps-psiphon-watchdog.log"; }
wd_log() { cat "$ROOT/var/log/vps-psiphon-watchdog.log"; }
run_cli() { run bash "$ROOT/CLI.sh" "$@"; }
