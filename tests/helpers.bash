# Shared by tests/*.bats. The installer writes its helper scripts as heredocs, so the
# tests pull them out of psiphon_install.sh and run them against a scratch root with
# stub binaries, rather than keeping a second copy that could drift from the real one.

REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
INSTALLER="$REPO/psiphon_install.sh"

# A generated script as the installer writes it: the heredoc body, shared functions
# substituted in (see tests/render.sh).
heredoc() { bash "$REPO/tests/render.sh" "$1"; }

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
           "$ROOT/usr/local/sbin" "$ROOT/bin" "$ROOT/metrics" "$ROOT/config" "$ROOT/opt/vps-psiphon"
  STUB_LOG="$ROOT/calls.log"; : > "$STUB_LOG"
  # One start time for the whole test: computed per call, two calls a second apart
  # would read as a restart during the check.
  FAKE_STARTED="${FAKE_STARTED:-$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000000000Z)}"
  export ROOT STUB_LOG FAKE_STARTED
  for t in WD ADV CLI GEM RUN; do
    heredoc "$t" | sed -e "s#/etc/default/#$ROOT/etc/default/#g" \
                       -e "s#/var/log/#$ROOT/var/log/#g" \
                       -e "s#/var/lib/#$ROOT/var/lib/#g" \
                       -e "s#/run/#$ROOT/run/#g" \
                       -e "s#/opt/vps-psiphon/#$ROOT/opt/vps-psiphon/#g" \
                       -e "s#/usr/local/sbin/#$ROOT/usr/local/sbin/#g" \
      > "$ROOT/$t.sh"
  done
  cp "$ROOT/ADV.sh" "$ROOT/usr/local/sbin/vps-psiphon-advance-region"
  cp "$ROOT/GEM.sh" "$ROOT/usr/local/sbin/vps-psiphon-gemini-check"
  chmod +x "$ROOT/usr/local/sbin/vps-psiphon-advance-region" "$ROOT/usr/local/sbin/vps-psiphon-gemini-check"
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
TG_THREAD=''
METRICS_DIR='$ROOT/metrics'
EOF
}

# curl is driven by FAKE_* variables:
#   FAKE_204      liveness status          (default 204)
#   FAKE_YT_W     -w output of the YouTube fetch   (default "2048000 200")
#   FAKE_YT_RC    its exit status                  (default 0)
#   FAKE_YT_BODY  its body                         (default 60 KB carrying GL DE)
#   FAKE_IP       ipify answer                     (default 203.0.113.9)
#   FAKE_ROTATED_IP  optional ipify answer after the watchdog starts the new tunnel
#   FAKE_PROBE    status of a PROBE_URLS target on gemini.google.com (default 200);
#                 a target on *.example times out (000, exit 28), like one that is down
# The Gemini check (its page is the one fetched with -D):
#   FAKE_GEM_CODE  status of the page            (default 200)
#   FAKE_GEM_PAGE  its body                      (default: carries both session fields)
#   FAKE_GEM_HEAD  its response headers          (default: none)
#   FAKE_GEM_OUT   the answer to the message     (default: a reply placing us in Berlin)
#   FAKE_CURL_OLD  1: a curl without --parallel and HTTP/2
#   FAKE_KEEPALIVE_EARLY  1: the keep-alive request ends before the message does
# Telegram calls are recorded in $STUB_LOG as "TG <text>", probe fetches as "PROBE <url>",
# the Gemini page as "GEMPAGE <how>" and the message as "GEMMSG parallel=<0|1> <proxy>".
write_stubs() {
  cat > "$ROOT/bin/curl" <<'C'
#!/usr/bin/env bash
out=""; url=""; data=(); head=""; par=0; wfmt=""; proxy=none
case "$1" in
  --help) [ "${FAKE_CURL_OLD:-0}" = 1 ] || echo ' -Z, --parallel  Perform transfers in parallel'; exit 0 ;;
  -V)     if [ "${FAKE_CURL_OLD:-0}" = 1 ]; then echo 'Features: SSL'; else echo 'Features: HTTP2 SSL'; fi; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    # With --next the first -o and the first URL are the message's; the trickle's are not.
    -o) [ -z "$out" ] && out="$2"; shift 2 ;;
    -D) head="$2"; shift 2 ;;
    -w) [ -z "$wfmt" ] && wfmt="$2"; shift 2 ;;
    --socks5-hostname) proxy="socks"; shift 2 ;;
    -4) proxy="direct"; shift ;;
    --max-time|-H|-A|-b|-c|-X|-T) shift 2 ;;
    --parallel) par=1; shift ;;
    --next) shift; while [ $# -gt 0 ]; do shift; done ;;
    --data-urlencode) data+=("$2"); shift 2 ;;
    -K) url="$(sed -n 's/^url = "\(.*\)"$/\1/p')"; shift 2 ;;
    http*) [ -z "$url" ] && url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ -n "$head" ] && [[ "$url" == https://gemini.google.com/app ]]; then
  echo "GEMPAGE ${CURL_AS:-plain} $proxy" >> "$STUB_LOG"
  if [ -n "${FAKE_GEM_PAGE+x}" ]; then printf '%s' "$FAKE_GEM_PAGE" > "$out"
  else printf '%s' '<script>WIZ_global_data = {"FdrFJe":"-4242","cfb2h":"boq_gemini-web-uiserver_20261103.01_p0"};</script>' > "$out"; fi
  printf '%s' "${FAKE_GEM_HEAD:-}" > "$head"
  printf '%s' "${FAKE_GEM_CODE:-200}"; exit 0
fi
case "$url" in
  *StreamGenerate*)
    echo "GEMMSG parallel=$par $proxy $url" >> "$STUB_LOG"
    if [ -n "${FAKE_GEM_OUT+x}" ]; then printf '%s' "$FAKE_GEM_OUT" > "$out"
    else printf '%s\n' ')]}'"'" '' '120' '[["wrb.fr",null,"[null,[\"c_1\",\"r_1\"],null,null,[[\"rc_1\",[\"Hello!\"]]],[\"Berlin, Germany\",\"SWML_DESCRIPTION_FROM_YOUR_INTERNET_ADDRESS\"]]"]]' > "$out"; fi
    # The keep-alive request after --next reports when it ended: after the message as
    # Google does, or first with FAKE_KEEPALIVE_EARLY=1.
    [ "$par" = 1 ] && [ "${FAKE_KEEPALIVE_EARLY:-0}" = 1 ] && printf '\nkeepalive-done 400 0.4\n' >&2
    [[ "$wfmt" == *'%{stderr}message-done'* ]] && printf 'message-done' >&2
    [ "$par" = 1 ] && [ "${FAKE_KEEPALIVE_EARLY:-0}" != 1 ] && printf '\nkeepalive-done 400 31.2\n' >&2
    exit 0 ;;
esac
case "$url" in
  *api.telegram.org*)
    for d in "${data[@]}"; do
      case "$d" in
        text=*) echo "TG ${d#text=}" >> "$STUB_LOG" ;;
        chat_id=*) echo "TGCHAT ${d#chat_id=}" >> "$STUB_LOG" ;;
        message_thread_id=*) echo "TGTHREAD ${d#message_thread_id=}" >> "$STUB_LOG" ;;
      esac
    done
    printf 200 ;;
  *generate_204*) printf '%s' "${FAKE_204:-204}" ;;
  *youtube*)
    if [ -n "$out" ]; then
      if [ -n "${FAKE_YT_BODY+x}" ]; then printf '%s' "$FAKE_YT_BODY" > "$out"
      else { printf '"GL":"DE"'; head -c 60000 /dev/zero | tr '\0' x; } > "$out"; fi
    fi
    printf '%s' "${FAKE_YT_W:-2048000 200}"
    exit "${FAKE_YT_RC:-0}" ;;
  *ipify*)
    if [ -n "${FAKE_ROTATED_IP:-}" ] && grep -qx 'systemctl start vps-psiphon.service' "$STUB_LOG"; then
      printf '%s' "$FAKE_ROTATED_IP"
    else
      printf '%s' "${FAKE_IP:-203.0.113.9}"
    fi ;;
  *google.com/search*) : ;;
  *gemini.google.com*) echo "PROBE $url" >> "$STUB_LOG"; printf '%s' "${FAKE_PROBE:-200}" ;;
  *.example*) echo "PROBE $url" >> "$STUB_LOG"; printf '000'; exit 28 ;;
esac
exit 0
C
  cat > "$ROOT/bin/docker" <<'D'
#!/usr/bin/env bash
# inspect -f {{.State.StartedAt}} → FAKE_STARTED (default: an hour ago)
# image inspect → FAKE_DIGESTS (the RepoDigests lines); pull, image rm → recorded
# FAKE_STARTED_SEQ: a file of start times, one per inspect call, the last one repeating —
# a tunnel restarted during a check. run --entrypoint cat → FAKE_TEMPLATE (the image's
# psiphon.config); any other run is the launcher's exec, recorded as "docker run …".
case "$1" in
  inspect)
    if [ -n "${FAKE_STARTED_SEQ:-}" ] && [ -s "$FAKE_STARTED_SEQ" ]; then
      head -1 "$FAKE_STARTED_SEQ"
      [ "$(wc -l < "$FAKE_STARTED_SEQ")" -gt 1 ] && sed -i 1d "$FAKE_STARTED_SEQ"
    else
      echo "${FAKE_STARTED:-$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000000000Z)}"
    fi ;;
  run)
    if [[ " $* " == *" --entrypoint cat "* ]]; then
      [ -n "${FAKE_TEMPLATE:-}" ] && cat "$FAKE_TEMPLATE"
      [ -n "${FAKE_TEMPLATE:-}" ]; exit $?
    fi
    echo "docker $*" >> "$STUB_LOG" ;;
  rm) : ;;
  pull)    echo "docker pull ${*: -1}" >> "$STUB_LOG" ;;
  image)
    case "$2" in
      inspect)
        # {{.Id}} lookups answer from FAKE_IDS ("ref=id" lines) when it is set.
        if [ -n "${FAKE_IDS:-}" ] && [[ "$*" == *'{{.Id}}'* ]]; then
          printf '%s\n' "$FAKE_IDS" | sed -n "s|^${*: -1}=||p"
        else
          printf '%s\n' "${FAKE_DIGESTS:-}"
        fi ;;
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
# Shown only when a test fails: what the check answered, and the calls it made.
# shellcheck disable=SC2154  # status and output are set by bats run
run_gem() { run bash "$ROOT/usr/local/sbin/vps-psiphon-gemini-check" "$@"; echo "gem[$status]: $output"; tail -3 "$STUB_LOG"; }

# curl-impersonate as the installer leaves it: the binary and a curl_chromeN wrapper.
# The wrapper hands over to the curl stub, marked, so a test can tell which one ran.
fake_impersonate() {
  local ci="$ROOT/opt/vps-psiphon/curl-impersonate"
  mkdir -p "$ci"
  printf '#!/bin/sh\nexit 0\n' > "$ci/curl-impersonate"
  for n in 99 136 152; do printf '#!/bin/sh\nCURL_AS=chrome%s exec curl "$@"\n' "$n" > "$ci/curl_chrome$n"; done
  printf '#!/bin/sh\nCURL_AS=firefox exec curl "$@"\n' > "$ci/curl_firefox155"
  chmod +x "$ci"/*
  echo v2.3.2 > "$ci/VERSION"
}

# The launcher, with what a real env file always carries and the tests' env does not.
run_launcher() {
  grep -q '^IMAGE=' "$ROOT/etc/default/vps-psiphon" || cat >> "$ROOT/etc/default/vps-psiphon" <<EOF
IMAGE=repo/psiphon:latest@sha256:0123
HTTP_PORT=8080
PUBLISH_HTTP=0
DEVICE_REGION=DE
EOF
  run bash "$ROOT/RUN.sh"
}

# The image's psiphon.config, in its shape: two-space keys, the last without a comma.
psiphon_template() {
  cat <<'T'
{
  "DataRootDirectory": "/config/",
  "DeviceRegion": "IN",
  "EgressRegion": "SG",
  "LocalHttpProxyPort": 8080,
  "LocalSocksProxyPort": 1080,
  "RemoteServerListURLs": [
      {
          "OnlyAfterAttempts": 0,
          "URL": "aHR0cHM6Ly9leGFtcGxlLmludmFsaWQv"
      }
  ],
  "UseIndistinguishableTLS": true
}
T
}

# Any start of the tunnel at all — a plain restart or a fresh start — is a rotation in
# the watchdog's tests; a fresh one is the client on an empty config directory.
rotated() { grep -qE '^systemctl (restart|start) vps-psiphon.service$' "$STUB_LOG"; }
rotated_fresh() {
  grep -qx 'systemctl stop vps-psiphon.service' "$STUB_LOG" &&
    grep -qx 'systemctl start vps-psiphon.service' "$STUB_LOG" &&
    refute grep -qx 'systemctl restart vps-psiphon.service' "$STUB_LOG"
}
