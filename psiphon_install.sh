#!/usr/bin/env bash
# psiphon-egress — Psiphon egress for an xray/remnawave node.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/mtvworks/psiphon-egress/main/psiphon_install.sh)
#
# Derived from Chara-Freedom/vps-psiphon (MIT) — see CREDITS.md. What this copy
# adds over its parent: the default image is digest-pinned rather than :latest,
# the container carries memory/pids/log ceilings, `routing` prints the panel
# rules the outbound alone is useless without, and `verify` answers "is my SOCKS
# reachable from outside" in a way TCP-connect probes cannot.
#
# The tunnel runs as a container; its SOCKS5 is published on a host-private
# address and handed to xray through a four-line outbound. systemd owns the
# lifecycle, and a watchdog rotates the tunnel when the exit stops being usable.
#
# Installs:
#   /etc/default/vps-psiphon              parameters
#   /usr/local/sbin/vps-psiphon-run       container launcher (systemd ExecStart)
#   /usr/local/sbin/vps-psiphon-watchdog  liveness + burned-exit detector
#   /usr/local/sbin/vps-psiphon-advance-region  walks REGION_POOL on each rotation
#   /usr/local/sbin/vps-psiphon-gemini-check    asks Gemini itself whether it serves the exit
#   /usr/local/sbin/vps-psiphon           management CLI
#   /etc/systemd/system/vps-psiphon.service
#   /etc/systemd/system/vps-psiphon-watchdog.service + .timer
#   /opt/vps-psiphon/config               psiphon's own config and server list
#   /opt/vps-psiphon/curl-impersonate     with --impersonate: a browser build of curl
#   /var/log/vps-psiphon-watchdog.log     watchdog journal
#   /var/lib/vps-psiphon-watchdog.state   watchdog counters
#   /var/lib/vps-psiphon-watchdog.seen    the last tunnel the watchdog logged
#   /var/lib/vps-psiphon-run.state        what the launcher made of the last start
#
# `vps-psiphon uninstall` removes all of those, the container, the image and itself.
set -euo pipefail

# Digest-pinned by default. The parent project ships :latest, which re-resolves on
# every pull: the code running on the node can change without a single local edit,
# and nothing announces it. A digest is reproducible — `--image ref:tag` still
# accepts a moving tag for anyone who wants one, with a warning.
IMAGE_DEFAULT_DIGEST="sha256:26bb31230f2c99defcb4f1e3d912037aeba0971333a17eb55b37f3e5bf7f69c0"
IMAGE_DEFAULT="swarupsengupta2007/psiphon:latest@$IMAGE_DEFAULT_DIGEST"
# Asked for (flag or environment) or not: an image moved on by `vps-psiphon
# update-image` must survive a reinstall, not be rolled back to the digest shipped here.
IMAGE_SET=0; [ -n "${IMAGE:-}" ] && IMAGE_SET=1
IMAGE="${IMAGE:-$IMAGE_DEFAULT}"
NAME="${NAME:-vps-psiphon}"

# Container ceilings. A tunnel that leaks must not take the node down with it: on a
# 1 GB VPS the OOM killer picks the largest process, and that is xray, not psiphon.
# Steady state measured across three nodes is 8-22 MiB, so 512m is ~25x headroom and
# still a ceiling. json-file logging is unbounded by default and psiphon is chatty
# on every dial, hence the rotation caps.
# Asked for (flag or environment) or not, like IMAGE: a ceiling lowered by hand for a
# small node must survive a reinstall instead of quietly going back to the default.
MEM_LIMIT_SET=0;    [ -n "${MEM_LIMIT:-}" ]    && MEM_LIMIT_SET=1
PIDS_LIMIT_SET=0;   [ -n "${PIDS_LIMIT:-}" ]   && PIDS_LIMIT_SET=1
LOG_MAX_SIZE_SET=0; [ -n "${LOG_MAX_SIZE:-}" ] && LOG_MAX_SIZE_SET=1
LOG_MAX_FILE_SET=0; [ -n "${LOG_MAX_FILE:-}" ] && LOG_MAX_FILE_SET=1
MEM_LIMIT="${MEM_LIMIT:-512m}"
PIDS_LIMIT="${PIDS_LIMIT:-256}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-10m}"
LOG_MAX_FILE="${LOG_MAX_FILE:-3}"
# Resolved after preflight, because the default is an address that does not exist
# until docker is running. Empty here means "not chosen yet"; a reinstall takes the
# stored one before falling back to that default (restore_bind below).
BIND="${BIND:-}"
# Services the exit is for, checked by the watchdog through the tunnel; a refusal
# (403/451) rotates. Unset means: keep the stored list, else this default. '' turns
# the check off. The reasoning sits beside PROBE_URLS in the env file below.
PROBE_URLS_DEFAULT="https://gemini.google.com/app"
PROBE_URLS=""; PROBE_URLS_SET=0
# The watchdog asks Gemini itself at every check (vps-psiphon-gemini-check): a refusal
# (error 1060) arrives on a page that answers 200, which no status-code probe sees.
GEMINI_CHECK=1; GEMINI_CHECK_SET=0
# With --impersonate the Gemini check fetches its page with a browser's TLS handshake,
# so a captcha Google shows browsers alone rotates the exit. Off unless asked for.
IMPERSONATE=0; IMPERSONATE_SET=0
# Psiphon's in-proxy (WebRTC through a volunteer's device) is kept out of the tunnel
# protocols; --inproxy lets Psiphon choose again. The reasoning is in the launcher.
EXCLUDE_INPROXY=1; EXCLUDE_INPROXY_SET=0

SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"
EGRESS_REGION="${EGRESS_REGION:-}"
REGION_POOL=""; REGION_POOL_SET=0
DEVICE_REGION="${DEVICE_REGION:-}"
WATCHDOG=1
PUBLISH_HTTP=1
# Countries the exit must never sit in. Checked before any allow-list and in every
# mode, including auto, where nothing else looks at the country at all. Sanctioned
# regions, where Google withholds service, plus CN, which blocks Google itself —
# useless for the same reason. A false positive costs one rotation.
DENY_REGIONS_DEFAULT="RU BY IR SY CU KP CN VE"
DENY_REGIONS=""; DENY_REGIONS_SET=0
# Countries the exit MAY be seen in — a different question from the ones we ask
# Psiphon for, because GL is Google's verdict about the address, not the server's
# location. Empty computes to everything requested plus US; "any" accepts every
# verdict. The reasoning sits beside ACCEPT_REGIONS in the env file below.
ACCEPT_REGIONS=""; ACCEPT_REGIONS_SET=0
# Optional Telegram alerts from the watchdog (rotation, denied country). Both empty =
# off. Kept across reinstalls unless given again; '' turns them off.
TG_TOKEN=""; TG_TOKEN_SET=0; TG_CHAT=""; TG_CHAT_SET=0
# Optional forum topic (message_thread_id) inside TG_CHAT; empty = the chat itself.
TG_THREAD=""; TG_THREAD_SET=0
# The token may come from the environment instead of --tg-token, so it stays out of
# `ps` and the shell history: VPSPSI_TG_TOKEN=... bash psiphon_install.sh --tg-chat ...
if [ -n "${VPSPSI_TG_TOKEN+x}" ]; then TG_TOKEN="$VPSPSI_TG_TOKEN"; TG_TOKEN_SET=1; fi
# node_exporter textfile collector directory for the watchdog's metrics. Unset means:
# keep the stored value, else use the collector's usual directory if it exists.
METRICS_DIR=""; METRICS_DIR_SET=0
METRICS_DIR_DEFAULT=/var/lib/node_exporter/textfile_collector

CONF_DIR=/opt/vps-psiphon/config
ENVF=/etc/default/vps-psiphon
# Ports asked for explicitly are honoured or refused, never silently moved.
SOCKS_PORT_SET=0
HTTP_PORT_SET=0
PUBLISH_HTTP_SET=0

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Country lists arrive comma- or space-separated and in any case, and leave as
# upper-case codes separated by single spaces. Anything else is refused rather than
# carried: GL is always upper case, so a stray "de" never matches and the watchdog
# rotates forever, and every value here ends up in a file that root sources and
# edits with sed.
cc_list() {
  local s
  s="$(printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//' \
       | tr '[:lower:]' '[:upper:]')"
  [ -z "$s" ] || printf '%s\n' "$s" | grep -qxE '[A-Z]{2}( [A-Z]{2})*' || return 1
  printf '%s' "$s"
}

# Image references are kept as repo:tag@sha256:… — the digest is what runs, the tag is
# what `update-image` follows, so a node installed from :v2 keeps getting v2 and never
# drifts to whatever :latest has become. A tag lives after the last '/', so a registry
# port (host:5000/x) is never taken for one. A reference with no tag follows :latest.
img_repo()   { local r="${1%@*}"; case "${r##*/}" in *:*) r="${r%:*}" ;; esac; printf '%s' "$r"; }
img_tag()    { local r="${1%@*}"; case "${r##*/}" in *:*) printf '%s' "${r##*:}" ;; *) printf latest ;; esac; }
img_tagged() { local r="${1%@*}"; case "${r##*/}" in *:*) return 0 ;; esac; return 1; }
img_digest() { case "$1" in *@*) printf '%s' "${1#*@}" ;; esac; }
# What docker inspects or removes: repo@digest when pinned, the reference as given
# otherwise. The tag is bookkeeping and is kept out of those lookups.
img_canon()  {
  local d; d="$(img_digest "$1")"
  if [ -n "$d" ]; then printf '%s@%s' "$(img_repo "$1")" "$d"; else printf '%s' "$1"; fi
}

# The tunnel restarted on an empty config directory, which the launcher seeds again from
# the env file. The client keeps the servers it knows in that directory, and a plain
# restart kept bringing it back to the same server in the country: rotations through a
# pool of four countries kept landing on the same four exits — in one journal, 13
# rotations into one country over two days all came back to one server — and a pool with
# no good exit among them never left it (measured by vps-psiphon 1.3, whose fix this is).
# Every rotation (the watchdog's, `rotate`) and `region` start this way. A CONF_DIR of
# fewer than two path components is refused: the env file is edited by hand, and this
# empties the directory it names.
fresh_start() {
  local c="${CONF_DIR:-/opt/vps-psiphon/config}"
  # Two or more plain components, no trailing slash, no "." or ".." among them: /opt/,
  # //, /opt/.. and the like are refused rather than emptied.
  if ! [[ "$c" =~ ^(/[A-Za-z0-9_][A-Za-z0-9._-]*){2,}$ ]] || [[ "$c" =~ /\.\.?(/|$) ]]; then
    echo "CONF_DIR='$c' is not a directory this would empty — restarting without a fresh start" >&2
    systemctl restart vps-psiphon.service; return 1
  fi
  systemctl stop vps-psiphon.service
  rm -rf "${c:?}"/*; mkdir -p "$c"; chown -R 1000:1000 "$c"
  systemctl start vps-psiphon.service
}

# The generated launcher, watchdog and CLI need these too. They get these exact definitions,
# written in where @@SHARED_FUNCS@@ stands, rather than a hand-kept second copy that
# could drift: the reinstall path and update-image must parse IMAGE the same way.
# Through ENVIRON, not awk -v, which would expand the \n inside cc_list.
SHARED_FUNCS="$(declare -f cc_list img_repo img_tag img_tagged img_digest img_canon fresh_start)"
put_shared_funcs() {
  local f="$1" t; t="$(mktemp "$f.XXXXXX")"
  SHARED_FUNCS="$SHARED_FUNCS" awk '$0 == "@@SHARED_FUNCS@@" { print ENVIRON["SHARED_FUNCS"]; next } { print }' \
    "$f" > "$t" && mv -f "$t" "$f"
}

usage() {
  cat <<'U'
psiphon_install.sh [options]
  --region CC[,CC…]    egress country (ISO 3166-1 alpha-2). Empty = auto, the
                       fastest server in any country. Give several, comma-
                       separated, to form a POOL: every rotation advances to the
                       next country in it. That widens the server choice when one
                       country is congested, while keeping the exit inside a set
                       you chose — unlike auto, which may land on another
                       continent and cost you the latency. 'auto' = empty.
                       Available at the time of writing: AT AU BE BR CA CH CZ
                       DE DK ES FR GB ID IE IN IT JP LT NL NO PL RO RS SE SG US.
                       Omitted on a reinstall, the stored region and pool are
                       kept; --region '' switches back to auto.
  --device-region CC   region the client reports. Cosmetic — the server decides
                       by GeoIP. Default: autodetected from this host.
  --socks-port N       SOCKS5 port for xray, default 1080. Refused if
                       taken — xray's outbound names this port, so moving it
                       behind your back would leave a tunnel nothing routes to.
  --http-port N        HTTP proxy port, default 8080. Nothing here
                       consumes it, so a taken default is moved to the next free
                       port; a port you name explicitly is refused instead.
  --no-http            do not publish the HTTP proxy at all. Remembered: a
                       later reinstall keeps it unpublished
  --http               publish it after all — undoes a stored --no-http, and
                       restores the proxy when an earlier run found no free port
  --deny-regions 'CC…' countries the exit must never be in, space or comma
                       separated. Default: RU BY IR SY CU KP CN VE. Unlike the
                       region and the pool, this is checked in EVERY mode — with
                       no --region and no OK_REGIONS it is the only country check
                       there is. An empty string disables it.
  --accept 'CC…'       countries Google's verdict may report, space or comma
                       separated. This is NOT the pool: the pool is what Psiphon
                       is asked for, this is what is accepted once Google has had
                       its say about the address it handed us. Default: everything
                       requested plus US, because Google rewrites many Psiphon
                       exits to US regardless of where they are, and that costs
                       nothing. Pass 'any' to accept every country and leave
                       --deny-regions as the only country check.
  --bind ADDR          host IPv4 address to publish the SOCKS5 on. Default: the
                       docker0 gateway (usually 172.17.0.1). Publishing there
                       lets the kernel DNAT the traffic; publishing on loopback
                       cannot, so every byte is copied through docker-proxy in
                       userspace instead — 0.10 of a core sustained on a node
                       carrying ~100 new connections/s, 0.27-0.36 at peak. On a
                       1-core box that copy is the difference that matters.
                       Any address is accepted, a public one included; that is
                       your call, and the access control it then needs is yours.
  --bind-loopback      publish on 127.0.0.1 instead. Narrower — only processes
                       on the host reach it, whereas the gateway is also
                       reachable by containers on the default bridge — at the
                       price of that userspace copy. Neither address is
                       reachable from the internet.
                       With neither flag, a reinstall keeps the stored address:
                       xray's outbound dials it, so it moves only when asked.
  --image REF          container image, default swarupsengupta2007/psiphon pinned
                       by digest
  --memory SIZE        container memory ceiling (default 512m; a reinstall keeps
                       the stored one)
  --pids-limit N       container pid ceiling (default 256; kept the same way)
  --no-watchdog        skip the watchdog
  --probe-urls 'URL …' https:// pages the exit is for, checked by the watchdog
                       through the tunnel; a 403 or 451 from any of them rotates.
                       Default https://gemini.google.com/app; kept across
                       reinstalls; '' turns the check off.
  --no-gemini-check    do not ask Gemini itself at every check. On by default: a
                       logged-out message is sent through the tunnel and Gemini's
                       refusal (error 1060, on a page that answers 200) rotates the
                       exit at once. About 1 MB per check. --gemini-check turns it
                       back on; remembered across reinstalls.
  --impersonate        install curl-impersonate and let the Gemini check fetch its
                       page with a browser's TLS handshake. Google can flag an exit
                       for browsers alone and send them to a captcha; a redirect
                       to it then rotates at once. For a node whose Gemini leaves
                       through this tunnel while www.google.com does not — there
                       that captcha cannot be solved. Remembered across reinstalls
  --no-impersonate     turn it off again and remove curl-impersonate
  --inproxy            let Psiphon pick in-proxy tunnels (WebRTC through a
                       volunteer's device) and apply its server-sent tactics. Off
                       by default: under an exit's load such tunnels died within
                       minutes or crawled. --no-inproxy restores the default.
  --tg-token TOKEN     Telegram bot token for watchdog alerts (rotations, denied
  --tg-chat ID         country). Both are needed; '' turns alerts off. Kept across
                       reinstalls. Test with: vps-psiphon notify-test
  --tg-thread ID       optional forum topic (message_thread_id) inside that chat;
                       default: the chat itself. Kept across reinstalls.
  --metrics-dir DIR    where the watchdog writes vps-psiphon.prom for the
                       node_exporter textfile collector. Default: kept from the
                       last install, else /var/lib/node_exporter/textfile_collector
                       if it exists. '' turns metrics off.
U
}

while [ $# -gt 0 ]; do
  case "$1" in
    --region)
      # One country as before; several form a pool the watchdog walks on rotation.
      V="${2:-}"; case "$V" in [Aa][Uu][Tt][Oo]) V="" ;; esac
      REGION_POOL="$(cc_list "$V")" || die "--region: '$V' is not a list of two-letter country codes"
      EGRESS_REGION="${REGION_POOL%% *}"
      [ "$REGION_POOL" = "$EGRESS_REGION" ] && REGION_POOL=""
      REGION_POOL_SET=1; shift 2 ;;
    --device-region) DEVICE_REGION="${2:-}"; shift 2 ;;
    --socks-port)    SOCKS_PORT="${2:?}"; SOCKS_PORT_SET=1; shift 2 ;;
    --http-port)     HTTP_PORT="${2:?}";  HTTP_PORT_SET=1;  shift 2 ;;
    --no-http)       PUBLISH_HTTP=0; PUBLISH_HTTP_SET=1; shift ;;
    --http)          PUBLISH_HTTP=1; PUBLISH_HTTP_SET=1; shift ;;
    --deny-regions)
      DENY_REGIONS="$(cc_list "${2:-}")" \
        || die "--deny-regions: '${2:-}' is not a list of two-letter country codes"
      DENY_REGIONS_SET=1; shift 2 ;;
    --accept)
      case "${2:-}" in
        [Aa][Nn][Yy]) ACCEPT_REGIONS=any ;;
        *) ACCEPT_REGIONS="$(cc_list "${2:-}")" \
             || die "--accept: '${2:-}' is neither 'any' nor a list of two-letter country codes" ;;
      esac
      ACCEPT_REGIONS_SET=1; shift 2 ;;
    --bind)          BIND="${2:?}";          shift 2 ;;

    --bind-loopback) BIND=127.0.0.1;         shift   ;;
    --image)         IMAGE="${2:?}"; IMAGE_SET=1; shift 2 ;;
    --tg-token)      TG_TOKEN="${2:-}"; TG_TOKEN_SET=1; shift 2 ;;
    --tg-chat)       TG_CHAT="${2:-}";  TG_CHAT_SET=1;  shift 2 ;;
    --tg-thread)     TG_THREAD="${2:-}"; TG_THREAD_SET=1; shift 2 ;;
    --metrics-dir)   METRICS_DIR="${2:-}"; METRICS_DIR_SET=1; shift 2 ;;
    --memory)        MEM_LIMIT="${2:?}";  MEM_LIMIT_SET=1;  shift 2 ;;
    --pids-limit)    PIDS_LIMIT="${2:?}"; PIDS_LIMIT_SET=1; shift 2 ;;
    --no-watchdog)   WATCHDOG=0;             shift   ;;
    --probe-urls)    PROBE_URLS="${2:-}"; PROBE_URLS_SET=1; shift 2 ;;
    --gemini-check)    GEMINI_CHECK=1;    GEMINI_CHECK_SET=1;    shift ;;
    --no-gemini-check) GEMINI_CHECK=0;    GEMINI_CHECK_SET=1;    shift ;;
    --impersonate)     IMPERSONATE=1;     IMPERSONATE_SET=1;     shift ;;
    --no-impersonate)  IMPERSONATE=0;     IMPERSONATE_SET=1;     shift ;;
    --inproxy)         EXCLUDE_INPROXY=0; EXCLUDE_INPROXY_SET=1; shift ;;
    --no-inproxy)      EXCLUDE_INPROXY=1; EXCLUDE_INPROXY_SET=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# ------------------------------------------------------------------- inputs --
# Checked before anything is written: every one of these lands in the env file that
# root sources, and several are spliced into sed expressions or docker arguments.
# EGRESS_REGION and DEVICE_REGION may also come from the environment, so they are
# normalised here rather than only in the option parser.
EGRESS_REGION="$(cc_list "$EGRESS_REGION")" && [ "$EGRESS_REGION" = "${EGRESS_REGION%% *}" ] \
  || die "EGRESS_REGION: expected one two-letter country code"
DEVICE_REGION="$(cc_list "$DEVICE_REGION")" && [ "$DEVICE_REGION" = "${DEVICE_REGION%% *}" ] \
  || die "--device-region: expected one two-letter country code"
is_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_port "$SOCKS_PORT" || die "--socks-port: '$SOCKS_PORT' is not a port number"
is_port "$HTTP_PORT"  || die "--http-port: '$HTTP_PORT' is not a port number"
# IPv4 only: the launcher publishes "$BIND:port:port" and the probes dial
# "$BIND:port", neither of which is written to take an IPv6 literal.
is_ipv4() {
  printf '%s\n' "$1" | grep -qxE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    && [ "$(printf '%s' "$1" | tr '.' '\n' | awk '$1 > 255' | wc -l)" = 0 ]
}
if [ -n "$BIND" ]; then
  is_ipv4 "$BIND" || die "--bind: '$BIND' is not an IPv4 address"
fi
printf '%s\n' "$IMAGE"      | grep -qxE '[A-Za-z0-9._/:@-]+' || die "--image: '$IMAGE' is not an image reference"
printf '%s\n' "$NAME"       | grep -qxE '[A-Za-z0-9][A-Za-z0-9_.-]*' || die "NAME: '$NAME' is not a container name"
# These are checked again after the stored values are restored, since those are
# sourced too and go straight into docker arguments.
check_limits() {
  printf '%s\n' "$MEM_LIMIT"    | grep -qxE '[0-9]+[bkmgBKMG]?' || die "--memory: '$MEM_LIMIT' is not a size like 512m"
  printf '%s\n' "$PIDS_LIMIT"   | grep -qxE '[0-9]+'            || die "--pids-limit: '$PIDS_LIMIT' is not a number"
  printf '%s\n' "$LOG_MAX_SIZE" | grep -qxE '[0-9]+[kmgKMG]?'   || die "LOG_MAX_SIZE: '$LOG_MAX_SIZE' is not a size like 10m"
  printf '%s\n' "$LOG_MAX_FILE" | grep -qxE '[0-9]+'            || die "LOG_MAX_FILE: '$LOG_MAX_FILE' is not a number"
}
check_limits
check_extras() {
  [ -z "$TG_TOKEN" ] || printf '%s\n' "$TG_TOKEN" | grep -qxE '[0-9]+:[A-Za-z0-9_-]+' \
    || die "--tg-token: not a bot token (digits:letters, as BotFather prints it)"
  [ -z "$TG_CHAT" ] || printf '%s\n' "$TG_CHAT" | grep -qxE -e '-?[0-9]+|@[A-Za-z0-9_]+' \
    || die "--tg-chat: expected a numeric chat id or @channelname"
  [ -z "$TG_THREAD" ] || printf '%s\n' "$TG_THREAD" | grep -qxE '[0-9]+' \
    || die "--tg-thread: expected a numeric topic id"
  [ -z "$METRICS_DIR" ] || printf '%s\n' "$METRICS_DIR" | grep -qxE '/[A-Za-z0-9._/-]*' \
    || die "--metrics-dir: expected an absolute path"
  # Normalised to single spaces, then each URL held to plain https:// characters: the
  # list is written single-quoted into a file root sources, and the watchdog hands
  # every entry to curl. Read into an array, not word-split, so a '?' in a URL is
  # never taken for a glob.
  local -a urls; local u
  PROBE_URLS="$(printf '%s' "$PROBE_URLS" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
  read -r -a urls <<< "$PROBE_URLS"
  for u in "${urls[@]}"; do
    printf '%s\n' "$u" | grep -qxE 'https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/?=&%+-]*)?' \
      || die "--probe-urls: '$u' is not a plain https:// URL (letters, digits and ._~/?=&%+- only)"
  done
}
check_extras

# ---------------------------------------------------------------- preflight --
[ "$(id -u)" = 0 ] || die "run as root"
command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "docker daemon is not running"
command -v curl >/dev/null || die "curl is not installed"
# Without ss every port reads as free, and a collision surfaces only as a unit that
# loops on a bind error after the install has claimed success.
command -v ss >/dev/null || die "ss is not installed (package iproute2) — needed to check the ports"
# The watchdog and the CLI's rotate/region/update-image serialise on one lock.
command -v flock >/dev/null || die "flock is not installed (package util-linux)"
# Taken before the old settings are read and held until this script exits. A watchdog
# rotation running meanwhile would otherwise write its region step into the env file
# and restart the unit under us — the old region comes back over the new one, and the
# overlapping restart reads below as a tunnel that never started. The watchdog skips
# while this is held, the CLI waits.
exec 9>/run/vps-psiphon.lock
flock -w 600 9 || die "a watchdog check or vps-psiphon command has held the lock for 10 minutes — try again"

# ------------------------------------------------------------- bind address --
# Where the SOCKS5 is published decides whether the kernel can carry it. Docker
# writes a DNAT rule per published port, but a loopback destination needs
# net.ipv4.conf.all.route_localnet, which docker does not set — so that rule stays
# at zero packets and docker-proxy copies every byte through userspace: 0.10 of a
# core sustained on a live node, 0.00 once the same traffic goes to the gateway.
# Both addresses are host-private; the gateway is additionally reachable from
# containers on the default bridge.
#
# Both lookups end in `|| true` — under `set -e` a missing `ip` binary would make
# the assignment itself the failing command and kill the install before it reaches
# its fallback.
docker_gateway() {
  local g=""
  g="$(ip -4 -o addr show docker0 2>/dev/null \
       | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
  [ -n "$g" ] || g="$(docker network inspect bridge \
                      -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  printf '%s' "$g"
}
# A reinstall keeps the address the last run published on. xray's outbound in the
# panel dials it, out of this script's reach, and the default below is a different
# address: every node installed with --bind-loopback and re-run bare used to move to
# the gateway, warn, and carry nothing until the outbound was edited by hand. --bind
# or --bind-loopback still moves it, and the move is announced further down.
restore_bind() {
  [ -z "$BIND" ] && [ -r "$ENVF" ] || return 0
  BIND="$(sed -n 's/^BIND=//p' "$ENVF" | head -1 | tr -d "'")"
  [ -n "$BIND" ] || return 0
  is_ipv4 "$BIND" || die "BIND '$BIND' in $ENVF is not an IPv4 address"
  say "keeping the published address $BIND from the previous install"
}
restore_bind
# The container ceilings likewise, unless given again: a node sized down by hand
# (--memory 256m on a 1 GB box) went back to the 512m default on every bare re-run.
# Called from the restore block further down; checked again after it (check_limits).
restore_limits() {
  local v
  if [ "$MEM_LIMIT_SET" = 0 ]; then
    v="$(sed -n 's/^MEM_LIMIT=//p' "$ENVF" | head -1 | tr -d "'")"
    if [ -n "$v" ] && [ "$v" != "$MEM_LIMIT" ]; then
      say "keeping memory ceiling $v from the previous install"
    fi
    [ -z "$v" ] || MEM_LIMIT="$v"
  fi
  if [ "$PIDS_LIMIT_SET" = 0 ]; then
    v="$(sed -n 's/^PIDS_LIMIT=//p' "$ENVF" | head -1 | tr -d "'")"
    [ -z "$v" ] || PIDS_LIMIT="$v"
  fi
  if [ "$LOG_MAX_SIZE_SET" = 0 ]; then
    v="$(sed -n 's/^LOG_MAX_SIZE=//p' "$ENVF" | head -1 | tr -d "'")"
    [ -z "$v" ] || LOG_MAX_SIZE="$v"
  fi
  if [ "$LOG_MAX_FILE_SET" = 0 ]; then
    v="$(sed -n 's/^LOG_MAX_FILE=//p' "$ENVF" | head -1 | tr -d "'")"
    [ -z "$v" ] || LOG_MAX_FILE="$v"
  fi
}
# The on/off switches likewise. Only 0 or 1 is taken back: the file is sourced, and
# anything else there was not written by this script. An install older than a switch
# has no line for it and gets the default.
restore_switches() {
  local v
  if [ "$GEMINI_CHECK_SET" = 0 ]; then
    v="$(sed -n 's/^GEMINI_CHECK=//p' "$ENVF" | head -1 | tr -d "'")"
    case "$v" in 0|1) GEMINI_CHECK="$v" ;; esac
  fi
  if [ "$IMPERSONATE_SET" = 0 ]; then
    v="$(sed -n 's/^IMPERSONATE=//p' "$ENVF" | head -1 | tr -d "'")"
    case "$v" in 0|1) IMPERSONATE="$v" ;; esac
  fi
  if [ "$EXCLUDE_INPROXY_SET" = 0 ]; then
    v="$(sed -n 's/^EXCLUDE_INPROXY=//p' "$ENVF" | head -1 | tr -d "'")"
    case "$v" in 0|1) EXCLUDE_INPROXY="$v" ;; esac
  fi
}
if [ -z "$BIND" ]; then
  BIND="$(docker_gateway)"
  # No docker0 — a custom bridge, or docker configured without one. Loopback
  # still works, docker-proxy and all.
  [ -n "$BIND" ] || BIND=127.0.0.1
fi

# --------------------------------------------------------- port arbitration --
# Docker allocates host ports when the container starts, long after this script has
# written its files, so an unchecked collision does not fail the install: the service
# loops on a bind error, the wait loop below sits out two minutes in silence (`--rm`
# deletes every crash, so `docker logs` has nothing), and the run still ends with
# "here is your outbound" and exit 0. Both published ports are cleared up front.
#
# Collision is the kernel's rule, not string equality: a listener on 0.0.0.0 blocks
# every bind of that port, one on a specific address blocks only that address — so a
# stranger on 0.0.0.0:8080 clashes with our 127.0.0.1:8080 while the two strings
# differ.
#
# Prints who holds $1 when a bind on $2 would collide; exit 0 = taken, 1 = free.
port_conflict() {
  local port="$1" bind="$2" line field addr label ct
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    addr=""
    for field in $line; do
      case "$field" in *:"$port") addr="${field%:"$port"}"; break ;; esac
    done
    [ -n "$addr" ] || continue
    case "$addr" in
      '0.0.0.0'|'*'|'[::]'|'::') : ;;   # wildcard: blocks any bind of this port
      "$bind")                   : ;;   # same address
      *) continue ;;                    # some other specific address: no clash
    esac
    label="$(printf '%s\n' "$line" \
             | sed -n 's/.*users:((\"\([^\"]*\)\",pid=\([0-9]\{1,\}\).*/\1 (pid \2)/p')"
    [ -n "$label" ] || label="an unidentified listener"
    # Every published container port is held by docker-proxy, so that name alone
    # tells the operator nothing. Ask docker which container is behind it.
    case "$label" in
      docker-proxy*)
        ct="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
              | awk -v pat=":$port->" 'index($0, pat) { print $1; exit }')"
        [ -n "$ct" ] && label="container '$ct'"
        ;;
    esac
    printf '%s\n' "$label"
    return 0
  done <<EOF
$(ss -tlnpH "sport = :$port" 2>/dev/null)
EOF
  return 1
}

# First port at or above $1 that is free for a bind on $2.
free_port() {
  local port="$1" bind="$2" tries=0
  while [ "$tries" -lt 100 ]; do
    port_conflict "$port" "$bind" >/dev/null || { printf '%s\n' "$port"; return 0; }
    port=$((port + 1)); tries=$((tries + 1))
  done
  return 1
}

# Ports settled on an earlier run must survive a reinstall, or they drift one higher
# every time: 8080 taken, move to 8081, next run finds 8081 held by our own container
# and lands on 8082. For SOCKS_PORT the stake is larger than tidiness — it is the port
# the panel's outbound dials, so resetting it to the default would aim the outbound at
# nothing. Whether the HTTP proxy is published is restored the same way: --no-http is a
# decision, and what is stored is the outcome, so a run that found no free port stays
# unpublished until --http asks for it back. An explicit flag always wins.
if [ -r "$ENVF" ]; then
  if [ "$SOCKS_PORT_SET" = 0 ]; then
    V="$(sed -n 's/^SOCKS_PORT=//p' "$ENVF" | head -1)"; [ -n "$V" ] && SOCKS_PORT="$V"
  fi
  if [ "$HTTP_PORT_SET" = 0 ]; then
    V="$(sed -n 's/^HTTP_PORT=//p' "$ENVF" | head -1)"; [ -n "$V" ] && HTTP_PORT="$V"
  fi
  if [ "$PUBLISH_HTTP_SET" = 0 ]; then
    V="$(sed -n 's/^PUBLISH_HTTP=//p' "$ENVF" | head -1)"; [ -n "$V" ] && PUBLISH_HTTP="$V"
  fi
  # The region too, or a reinstall with no --region quietly means auto: the country
  # the operator pinned is dropped, and the change of region below wipes the cached
  # config and server list with it. What is stored may be a later pool step than the
  # one first asked for — that is where the tunnel is now, so it is kept. An explicit
  # --region, '' included, wins; so does EGRESS_REGION from the environment.
  if [ "$REGION_POOL_SET" = 0 ] && [ -z "$EGRESS_REGION" ]; then
    V="$(sed -n 's/^EGRESS_REGION=//p' "$ENVF" | head -1)"
    [ -n "$V" ] && EGRESS_REGION="$(cc_list "$V")" && [ "$EGRESS_REGION" = "${EGRESS_REGION%% *}" ] \
      || EGRESS_REGION=""
  fi
  # Values quoted in the file ('…') come back with the quotes stripped.
  stored() { sed -n "s/^$1=//p" "$ENVF" | head -1 | tr -d "'"; }
  if [ "$IMAGE_SET" = 0 ]; then
    V="$(stored IMAGE)"
    # Compared by what runs, not by spelling: an older install stored the same build
    # as repo@digest without the tag.
    if [ -n "$V" ] && [ "$(img_canon "$V")" != "$(img_canon "$IMAGE")" ]; then
      say "keeping image $V from the previous install (this script's default: $IMAGE)"
      say "    move it with 'vps-psiphon update-image', or re-run with --image"
    fi
    # Rewritten as repo:tag@digest, so an env from before the tag was recorded
    # comes out in the documented form (a bare repo@digest follows :latest).
    if [ -n "$V" ] && [ -n "$(img_digest "$V")" ]; then
      IMAGE="$(img_repo "$V"):$(img_tag "$V")@$(img_digest "$V")"
    elif [ -n "$V" ]; then
      IMAGE="$V"
    fi
  elif [ -n "$(img_digest "$IMAGE")" ] && ! img_tagged "$IMAGE"; then
    # --image repo@sha256:… pins a build without naming a tag: the tag this node
    # followed so far carries on, exactly as `update-image repo@sha256:…` does.
    V="$(stored IMAGE)"
    if [ -n "$V" ] && [ "$(img_repo "$V")" = "$(img_repo "$IMAGE")" ]; then
      IMAGE="$(img_repo "$IMAGE"):$(img_tag "$V")@$(img_digest "$IMAGE")"
    fi
  fi
  [ "$TG_TOKEN_SET" = 1 ]    || TG_TOKEN="$(stored TG_TOKEN)"
  [ "$TG_CHAT_SET" = 1 ]     || TG_CHAT="$(stored TG_CHAT)"
  [ "$TG_THREAD_SET" = 1 ]   || TG_THREAD="$(stored TG_THREAD)"
  # A line present but empty is a decision (metrics off) and survives; no line at all
  # is an install older than the option, which gets the default below.
  if [ "$METRICS_DIR_SET" = 0 ] && grep -q '^METRICS_DIR=' "$ENVF"; then
    METRICS_DIR="$(stored METRICS_DIR)"; METRICS_DIR_SET=1
  fi
  # Same rule for the watchdog's targets: emptied on purpose stays off.
  if [ "$PROBE_URLS_SET" = 0 ] && grep -q '^PROBE_URLS=' "$ENVF"; then
    PROBE_URLS="$(stored PROBE_URLS)"; PROBE_URLS_SET=1
  fi
  restore_switches
  restore_limits
fi
if [ "$METRICS_DIR_SET" = 0 ] && [ -d "$METRICS_DIR_DEFAULT" ]; then
  METRICS_DIR="$METRICS_DIR_DEFAULT"
fi
[ "$PROBE_URLS_SET" = 1 ] || PROBE_URLS="$PROBE_URLS_DEFAULT"
printf '%s\n' "$IMAGE" | grep -qxE '[A-Za-z0-9._/:@-]+' || die "IMAGE '$IMAGE' in $ENVF is not an image reference"
check_limits
check_extras
is_port "$SOCKS_PORT" || die "SOCKS_PORT '$SOCKS_PORT' in $ENVF is not a port number"
is_port "$HTTP_PORT"  || die "HTTP_PORT '$HTTP_PORT' in $ENVF is not a port number"

# Re-running over an existing install must work. The listener on our port is
# docker-proxy, never a process called "$NAME", so ask docker who owns it.
SOCKS_HOLDER="$(port_conflict "$SOCKS_PORT" "$BIND" || true)"
if [ -n "$SOCKS_HOLDER" ]; then
  if [ "$SOCKS_HOLDER" = "container '$NAME'" ]; then
    say "port $SOCKS_PORT held by the existing '$NAME' container — reinstalling over it"
  else
    ALT="$(free_port $((SOCKS_PORT + 1)) "$BIND" || true)"
    die "SOCKS port $SOCKS_PORT is taken by ${SOCKS_HOLDER}.
       This port is the one xray's outbound dials, so it is never moved for you:
       a tunnel on a port nothing routes to looks healthy and carries no traffic.
       Re-run with --socks-port ${ALT:-<a free port>} and set the same port in the
       outbound, or free $SOCKS_PORT first."
  fi
fi

# Nothing here consumes the HTTP proxy, so a busy default is worth working around.
# A port named explicitly is honoured or refused, never reinterpreted.
if [ "$PUBLISH_HTTP" = 1 ]; then
  HTTP_HOLDER="$(port_conflict "$HTTP_PORT" "$BIND" || true)"
  if [ -n "$HTTP_HOLDER" ] && [ "$HTTP_HOLDER" != "container '$NAME'" ]; then
    if [ "$HTTP_PORT_SET" = 1 ]; then
      die "HTTP port $HTTP_PORT is taken by ${HTTP_HOLDER}.
       Choose another with --http-port N, or drop it entirely with --no-http."
    fi
    ALT="$(free_port $((HTTP_PORT + 1)) "$BIND" || true)"
    if [ -n "$ALT" ]; then
      say "HTTP proxy port $HTTP_PORT is taken by ${HTTP_HOLDER} — publishing it on $ALT instead"
      HTTP_PORT="$ALT"
    else
      say "HTTP proxy port $HTTP_PORT is taken by ${HTTP_HOLDER} and no free port found — publishing SOCKS only"
      PUBLISH_HTTP=0
    fi
  fi
fi

# Loopback exists separately in every namespace, so 127.0.0.1 in the outbound means
# "this container" unless xray runs on host networking. The gateway is unambiguous —
# the second reason it is the default.
XRAY_CT="$(docker ps --format '{{.Names}}' | grep -iE 'remnanode|xray' | head -1 || true)"
if [ -n "$XRAY_CT" ] && [ "$BIND" = "127.0.0.1" ]; then
  NETMODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$XRAY_CT" 2>/dev/null || echo '?')"
  if [ "$NETMODE" != "host" ]; then
    echo
    echo "  !! container '$XRAY_CT' runs with NetworkMode=$NETMODE, not host."
    echo "     127.0.0.1:$SOCKS_PORT will NOT be reachable from xray."
    echo "     Drop --bind-loopback: the default gateway address is reachable"
    echo "     from both, and needs no change to that container."
    echo
  fi
fi

if [ -z "$DEVICE_REGION" ]; then
  # ifconfig.co answers datacenter IPs with a Cloudflare challenge, so try several and
  # take the first plausible code. -4 is deliberate: unflagged, curl prefers the AAAA
  # on a dual-stack host and would report the country of an address the traffic does
  # not leave from.
  for probe in https://ipinfo.io/country \
               https://api.country.is \
               https://ifconfig.co/country-iso ; do
    DEVICE_REGION="$(curl -4 -fsS --max-time 8 "$probe" 2>/dev/null \
                     | grep -oE '\b[A-Z]{2}\b' | head -1 || true)"
    [ -n "$DEVICE_REGION" ] && break
  done
  [ -n "$DEVICE_REGION" ] || DEVICE_REGION="US"
fi

if [ "$PUBLISH_HTTP" = 1 ]; then HTTP_DESC="$BIND:$HTTP_PORT"; else HTTP_DESC="not published"; fi
say "image=$IMAGE  egress=${EGRESS_REGION:-auto}  device=$DEVICE_REGION  socks=$BIND:$SOCKS_PORT  http=$HTTP_DESC"

# --------------------------------------------------------- curl-impersonate --
# With --impersonate the Gemini check fetches its page with a browser's TLS handshake.
# The build is the latest release of lexiforest/curl-impersonate, checked against the
# sha256 digest GitHub publishes for the asset. Both are read from github.com, not from
# the API: the API's anonymous limit is 60 requests an hour per address, and an exit
# shares its address with everything its users run. Fetched before anything is
# written, so a failure leaves the host as it was. (Ported from vps-psiphon 1.2.)
CI_DIR=/opt/vps-psiphon/curl-impersonate
CI_REPO=lexiforest/curl-impersonate
# A known-good release, taken when the latest cannot be read, fetched, verified or run.
# Its digests are written here, so neither a change to GitHub's release page nor a newer
# release that is renamed or broken stops the install. Google's flag answers any
# browser's handshake, so an older Chrome serves as well as the newest. Each digest was
# checked against the asset GitHub serves.
CI_PIN=v2.3.2
ci_pin_sum() {
  case "$1" in
    aarch64-linux-gnu)   echo 35a351db883f5ce82945bd8280c727b08e27aa48594d4eb9e091d8c80e936d52 ;;
    aarch64-linux-musl)  echo 1519bcee11f9c93a7ed95026bd951d53e8c7cd093f3ac53651b143e5a1e2098f ;;
    arm-linux-gnueabihf) echo a5bc29ea22c15286d8cecfed601cd222f569cd734a8d17232aece7bea0e6fe42 ;;
    i386-linux-gnu)      echo c15fd50d8f1e3811c9a048942505ec476aad0aa432d5f2aebcd63ccb1ebcac16 ;;
    riscv64-linux-gnu)   echo 23089329bdd51fb29d5d2ae730fbe5933b117b4f6e9734569a931b2b1813106f ;;
    x86_64-linux-gnu)    echo bc9bd2522fe1850dd54c0fff189c8dd606df3f222ab2a905f2dd255123c3f495 ;;
    x86_64-linux-musl)   echo ce79849f3be2e15d06364f89aeebb901b6be7b48947e2af8dae0616bbc87731f ;;
  esac
}

# Downloads release $1's asset $2, checks it against sha256 $3 and puts it in place;
# on failure prints why and returns 1, leaving the installed build untouched. Called
# inside $(...), where set -e does not hold, so every step is checked by hand.
ci_fetch() {
  local tag="$1" asset="$2" sum="$3" tmp
  tmp="$(mktemp -d)" || { echo "no temp dir"; return 1; }
  if ! curl -fsSL --max-time 300 -o "$tmp/$asset" \
       "https://github.com/$CI_REPO/releases/download/$tag/$asset"; then
    rm -rf "$tmp"; echo "could not download $asset"; return 1
  fi
  if [ "$(sha256sum "$tmp/$asset" | cut -d' ' -f1)" != "$sum" ]; then
    rm -rf "$tmp"; echo "$asset does not match its sha256"; return 1
  fi
  mkdir "$tmp/x" || { rm -rf "$tmp"; echo "no temp dir"; return 1; }
  # Owned by root and writable by root alone. The release's files carry the builder's
  # uid (1001 for v2.3.2), and tar run as root keeps it by default: whoever holds that
  # uid on this host could then rewrite a curl_chromeN wrapper — a shell script — that
  # the root watchdog runs every ten minutes. Only plain files and directories are
  # taken, so no link in the archive can point an install outside this directory.
  if ! tar --no-same-owner --no-same-permissions -xzf "$tmp/$asset" -C "$tmp/x" 2>/dev/null ||
     [ -n "$(find "$tmp/x" ! -type f ! -type d -print -quit)" ] ||
     ! chown -R 0:0 "$tmp/x" || ! chmod -R u+rwX,go+rX,go-w "$tmp/x"; then
    rm -rf "$tmp"; echo "$asset could not be unpacked as plain root-owned files"; return 1
  fi
  # The Gemini check needs the binary and one curl_chromeN wrapper, the newest of which
  # it runs. The binary is run once here, so a build for the wrong libc is refused now
  # rather than discovered by the watchdog.
  if ! "$tmp/x/curl-impersonate" --version >/dev/null 2>&1 ||
     [ -z "$(find "$tmp/x" -maxdepth 1 -name 'curl_chrome[0-9]*' -print -quit)" ]; then
    rm -rf "$tmp"; echo "$asset holds no working curl-impersonate with a Chrome profile"; return 1
  fi
  printf '%s\n' "$tag" > "$tmp/x/VERSION" || { rm -rf "$tmp"; echo "could not write VERSION"; return 1; }
  # Staged next to the target (the copy out of /tmp is the step a full disk breaks), and
  # the old build is moved aside, not deleted, until the new one stands in its place.
  rm -rf "${CI_DIR:?}.new" "${CI_DIR:?}.old"
  if ! mkdir -p "${CI_DIR%/*}" || ! mv "$tmp/x" "$CI_DIR.new"; then
    rm -rf "$tmp" "${CI_DIR:?}.new"; echo "could not copy the build to ${CI_DIR%/*}"; return 1
  fi
  rm -rf "$tmp"
  if [ -e "$CI_DIR" ] && ! mv "$CI_DIR" "$CI_DIR.old"; then
    rm -rf "${CI_DIR:?}.new"; echo "could not move the installed build aside"; return 1
  fi
  if ! mv "$CI_DIR.new" "$CI_DIR"; then
    [ -e "$CI_DIR.old" ] && mv "$CI_DIR.old" "$CI_DIR"
    rm -rf "${CI_DIR:?}.new"; echo "could not put the new build in place"; return 1
  fi
  rm -rf "${CI_DIR:?}.old"
  echo "$tag ($asset, sha256 ${sum:0:12}…)"
}

impersonate_install() {
  local arch libc tag="" sum="" why pin out have
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    armv7l)        arch=arm ;;
    i?86)          arch=i386 ;;
    riscv64)       arch=riscv64 ;;
    *) echo "no build is published for $(uname -m)"; return 1 ;;
  esac
  # Not a pipe into grep -q: musl's ldd exits 1, and under pipefail that hides the match.
  case "$(ldd --version 2>&1 || true)" in
    *musl*) libc=linux-musl ;;
    *)      libc=linux-gnu ;;
  esac
  [ "$arch" = arm ] && libc=linux-gnueabihf

  # The latest release redirects to its tag: read off the redirect a GET gets, which
  # also works where a proxy refuses HEAD. The tag goes into URLs and a file name, so
  # anything but a plain tag is ignored. The tag's asset list names each asset's digest
  # in the label of its copy button — page markup, not an API contract: if GitHub
  # changes it, no digest is found and the pinned release is taken.
  tag="$(curl -s -o /dev/null --max-time 20 -w '%{redirect_url}' \
         "https://github.com/$CI_REPO/releases/latest" 2>/dev/null \
         | sed -n 's#^https://github.com/.*/releases/tag/##p' || true)"
  printf '%s\n' "$tag" | grep -qxE '[A-Za-z0-9._-]{1,40}' || tag=""
  if [ -n "$tag" ]; then
    sum="$(curl -fsS --max-time 20 "https://github.com/$CI_REPO/releases/expanded_assets/$tag" \
           2>/dev/null | grep -oE "sha256:[0-9a-f]{64}\" aria-label=\"Copy to clipboard digest for curl-impersonate-$tag.$arch-$libc.tar.gz\"" \
           | head -1 | cut -c8-71 || true)"
  fi
  # A build of that very release, checked when it was installed, is kept: a reinstall for
  # another reason should not hang on a 30 MB download, nor fail on one.
  have="$(cat "$CI_DIR/VERSION" 2>/dev/null || true)"
  if [ -n "$tag" ] && [ "$have" = "$tag" ] && [ -x "$CI_DIR/curl-impersonate" ]; then
    echo "$tag, already installed"; return 0
  fi
  if [ -n "$tag" ] && [ -n "$sum" ]; then
    why="$(ci_fetch "$tag" "curl-impersonate-$tag.$arch-$libc.tar.gz" "$sum")" && { echo "$why"; return 0; }
  else
    why="could not read the latest release${tag:+ ($tag)} or its digest for $arch-$libc"
  fi

  pin="$(ci_pin_sum "$arch-$libc")"
  [ -n "$pin" ] || { echo "$why; no pinned build for $arch-$libc either"; return 1; }
  if [ "$have" = "$CI_PIN" ] && [ -x "$CI_DIR/curl-impersonate" ]; then
    echo "$CI_PIN, already installed — the pinned release, as the latest failed: $why"; return 0
  fi
  if out="$(ci_fetch "$CI_PIN" "curl-impersonate-$CI_PIN.$arch-$libc.tar.gz" "$pin")"; then
    echo "$out — the pinned release, as the latest failed: $why"; return 0
  fi
  echo "$why; the pinned $CI_PIN failed too: $out"; return 1
}
if [ "$IMPERSONATE" = 1 ]; then
  [ "$GEMINI_CHECK" = 1 ] || say "!! --impersonate acts through the Gemini check, which is off (--no-gemini-check)"
  say "fetching curl-impersonate"
  if CI_MSG="$(impersonate_install)"; then
    say "curl-impersonate $CI_MSG"
  elif [ -x "$CI_DIR/curl-impersonate" ]; then
    say "!! curl-impersonate: $CI_MSG — keeping the installed $(cat "$CI_DIR/VERSION" 2>/dev/null || echo build)"
  elif [ "$IMPERSONATE_SET" = 1 ]; then
    die "curl-impersonate: $CI_MSG.
       --impersonate needs it, so nothing was installed. Re-run later, or run
       without --impersonate."
  else
    # Asked for on an earlier run, not on this one: a reinstall made for another reason
    # is not blocked by a download. The check fetches its page by plain curl and says
    # so in every line it logs, and the watchdog alerts once.
    say "!! curl-impersonate: $CI_MSG — no build installed; the Gemini check falls back to plain curl until a re-run fetches one"
  fi
fi

# ------------------------------------------------------------------ install --
mkdir -p "$CONF_DIR"
# A changed region is a new draw of servers, as `region` is: the restart at the end is
# then a fresh start (fresh_start), which stops the client before emptying CONF_DIR —
# never under a running one. The region itself the launcher writes at every start.
OLD_REGION="__none__"; REGION_CHANGED=0
[ -r "$ENVF" ] && OLD_REGION="$(sed -n 's/^EGRESS_REGION=//p' "$ENVF")"
if [ "$OLD_REGION" != "__none__" ] && [ "$OLD_REGION" != "$EGRESS_REGION" ]; then
  say "egress region ${OLD_REGION:-auto} -> ${EGRESS_REGION:-auto}: the tunnel starts on a fresh server list"
  REGION_CHANGED=1
fi
chown -R 1000:1000 "$CONF_DIR"

# Preserve operator-set values across a reinstall.
OLD_OK_REGIONS=""; OLD_MIN_THROUGHPUT=""; OLD_REGION_POOL=""
OLD_FAIL_WINDOW=""; OLD_GRACE=""; OLD_ACCEPT_REGIONS=""
OLD_FAIL_THRESHOLD=""; OLD_COOLDOWN=""; OLD_COOLDOWN_MAX=""
# Tracked as set-or-not, not by value: a deliberately emptied deny-list is a choice
# the next reinstall must not undo.
OLD_DENY_SET=0; OLD_DENY_REGIONS=""
if [ -r "$ENVF" ] && grep -q '^DENY_REGIONS=' "$ENVF"; then
  OLD_DENY_SET=1
  OLD_DENY_REGIONS="$(sed -n 's/^DENY_REGIONS=//p' "$ENVF" | tr -d "'")"
fi
if [ "$DENY_REGIONS_SET" = 0 ]; then
  if [ "$OLD_DENY_SET" = 1 ]; then DENY_REGIONS="$OLD_DENY_REGIONS"
  else DENY_REGIONS="$DENY_REGIONS_DEFAULT"; fi
fi
if [ -r "$ENVF" ]; then
  OLD_OK_REGIONS="$(sed -n 's/^OK_REGIONS=//p' "$ENVF")"
  OLD_MIN_THROUGHPUT="$(sed -n 's/^MIN_THROUGHPUT_KBPS=//p' "$ENVF")"
  OLD_FAIL_WINDOW="$(sed -n 's/^FAIL_WINDOW=//p' "$ENVF")"
  OLD_FAIL_THRESHOLD="$(sed -n 's/^FAIL_THRESHOLD=//p' "$ENVF")"
  OLD_COOLDOWN="$(sed -n 's/^ROTATE_COOLDOWN=//p' "$ENVF")"
  OLD_COOLDOWN_MAX="$(sed -n 's/^ROTATE_COOLDOWN_MAX=//p' "$ENVF")"
  OLD_GRACE="$(sed -n 's/^THROUGHPUT_GRACE_SEC=//p' "$ENVF")"
  OLD_REGION_POOL="$(sed -n 's/^REGION_POOL=//p' "$ENVF" | tr -d "'")"
  # An explicit --region wins; otherwise an existing pool survives the reinstall.
  [ "$REGION_POOL_SET" = 1 ] || REGION_POOL="$OLD_REGION_POOL"
  OLD_ACCEPT_REGIONS="$(sed -n 's/^ACCEPT_REGIONS=//p' "$ENVF" | tr -d "'")"
  [ "$ACCEPT_REGIONS_SET" = 1 ] || ACCEPT_REGIONS="$OLD_ACCEPT_REGIONS"
fi

# Checked here because the pool is only known once given or restored just above. A
# country both requested and denied rotates forever — every rotation lands somewhere
# the deny-list rejects on the next check.
for r in ${EGRESS_REGION:-} ${REGION_POOL:-}; do
  case " $DENY_REGIONS " in
    *" $r "*) say "!! '$r' is both requested and denied — every exit there will be rejected" ;;
  esac
done
# Deny is checked first, so an overlap is not ambiguous — just a line that never does
# what its author meant.
for r in ${ACCEPT_REGIONS:-}; do
  case " $DENY_REGIONS " in
    *" $r "*) say "!! '$r' is both accepted and denied — denied wins, it is checked first" ;;
  esac
done

# A moved address leaves the outbound dialing one nobody listens on — a tunnel that
# reads healthy in every check and carries nothing. The outbound lives in the panel,
# out of this script's reach, so it warns here and again beside the new outbound.
OLD_BIND=""
[ -r "$ENVF" ] && OLD_BIND="$(sed -n 's/^BIND=//p' "$ENVF")"
BIND_CHANGED=0
if [ -n "$OLD_BIND" ] && [ "$OLD_BIND" != "$BIND" ]; then
  BIND_CHANGED=1
  echo
  printf '\033[1;33m  !! published address changes: %s -> %s\033[0m\n' "$OLD_BIND" "$BIND"
  echo "     xray still dials $OLD_BIND, and will carry nothing until you change it."
  echo "     Update the outbound printed at the end of this run."
  echo "     To stay where you are instead: re-run with --bind $OLD_BIND"
  echo
fi

# Created 0600 before anything is written into it: it may carry a bot token, and
# `cat >` onto a fresh file under the default umask leaves it world-readable until the
# chmod below.
[ -e "$ENVF" ] || install -m 600 /dev/null "$ENVF"
chmod 600 "$ENVF"
cat > "$ENVF" <<EOF
# vps-psiphon — written by psiphon_install.sh
# repo:tag@digest — the digest runs, the tag is what \`vps-psiphon update-image\` follows.
IMAGE=$IMAGE
NAME=$NAME
MEM_LIMIT=$MEM_LIMIT
PIDS_LIMIT=$PIDS_LIMIT
LOG_MAX_SIZE=$LOG_MAX_SIZE
LOG_MAX_FILE=$LOG_MAX_FILE
BIND=$BIND
SOCKS_PORT=$SOCKS_PORT
HTTP_PORT=$HTTP_PORT
PUBLISH_HTTP=$PUBLISH_HTTP
EGRESS_REGION=$EGRESS_REGION
DEVICE_REGION=$DEVICE_REGION
CONF_DIR=$CONF_DIR
# watchdog tuning. FAIL_THRESHOLD failures within the last FAIL_WINDOW checks rotate
# the tunnel — a window, not a run of consecutive failures: a degraded tunnel
# alternates around the floor instead of failing outright, and a counter that resets
# on the first passing check never reaches the threshold. Seen on a live node — four
# failures inside 70 minutes and no rotation.
FAIL_THRESHOLD=${OLD_FAIL_THRESHOLD:-2}
FAIL_WINDOW=${OLD_FAIL_WINDOW:-5}
ROTATE_COOLDOWN=${OLD_COOLDOWN:-1800}
# Rotations that do not help back off. After three rotations in a row with no passing
# check between them, the cooldown doubles with each further one, up to this many
# seconds, and an alert says so once. A fault that follows the host rather than the
# exit — Google refusing the node's whole pool, a broken upstream, a check that has
# gone stale — would otherwise drop every live connection twice an hour, forever. Set
# it equal to ROTATE_COOLDOWN to turn the back-off off.
ROTATE_COOLDOWN_MAX=${OLD_COOLDOWN_MAX:-7200}
#
# NOTE: this file is sourced by the shell, so any value containing spaces MUST be
# quoted. Unquoted, everything after the first space is run as a command.
#
# Acceptable countries for Google's verdict in auto mode, when no region is pinned:
#   OK_REGIONS='DE NL JP'
# Ignored once EGRESS_REGION or REGION_POOL is set — the verdict is then judged
# against ACCEPT_REGIONS below.
OK_REGIONS=$OLD_OK_REGIONS
# Countries the exit must NEVER be in, space separated. Checked before the allow-list
# and in every mode: with no EGRESS_REGION and no OK_REGIONS this is the only country
# check that runs at all. Those regions are where Google withholds service, the very
# failure this tool exists to escape — a false positive costs one rotation, a miss
# costs the service. Empty disables it.
DENY_REGIONS='$DENY_REGIONS'
# Minimum throughput, KB/s, read off the watchdog's own YouTube fetch — no extra
# traffic. Below this on FAIL_THRESHOLD of the last FAIL_WINDOW checks the tunnel is
# rotated: Psiphon picks its server per tunnel, so a bad pick otherwise persists while
# liveness and country both read green. 0 disables the gate.
#
# One floor for every node, on purpose: a number fitted by hand per machine is one
# nobody can reason about six months later. 800 came from replaying three nodes' own
# logged history (medians 1765 / 1987 / 3079 KB/s) through the window rule above — at
# 800 none of them would have rotated, at 1000 the slowest twice, at 1200 five times.
# Raising it buys nothing: a real collapse (66-128 KB/s while a healthy tunnel on the
# same box read 1500) trips the gate on the second check at 600 and at 1000 alike. The
# old default of 100 never fired at all, a working tunnel reading in the thousands.
#
# Lower it for a node that genuinely cannot reach it — after replaying that node's own
# throughput history from the watchdog log, not on one bad reading.
MIN_THROUGHPUT_KBPS=${OLD_MIN_THROUGHPUT:-800}
# Seconds after a container start during which the throughput gate is skipped. A
# freshly dialled tunnel is still ramping while every client the restart cut loose
# reconnects at once: the first check after a rotation read 73 KB/s on a tunnel that
# settled at 1500 a few minutes later, and judging it rotates a healthy tunnel
# away. It must be LONGER than the gap between checks or it protects nothing — the
# timer fires every 10 minutes, and the 300 this shipped with never once applied
# across three nodes. Liveness and country are still checked.
THROUGHPUT_GRACE_SEC=${OLD_GRACE:-900}
# Countries to rotate through, space separated. Empty = stay in EGRESS_REGION and only
# change server within it. Each rotation advances one entry, so a retry draws on a
# different country's servers instead of the same crowded set. Keep them near each
# other, and note the pool also feeds what the watchdog accepts: everything listed here
# you are accepting as a destination.
REGION_POOL='$REGION_POOL'
# Countries Google's verdict may report — deliberately NOT the same list as
# REGION_POOL. The pool is what Psiphon is asked for; this is what is accepted once
# Google has had its say about the address it handed us, and the two differ: Google
# rewrites many Psiphon exits to US whatever country the server reports, so judging the
# verdict against the request rotated healthy, fast exits away. Empty means the
# computed default — everything requested, plus US. The word any accepts every verdict.
# Sanctioned regions are rejected either way: deny is checked first.
ACCEPT_REGIONS='$ACCEPT_REGIONS'
# Services this exit is for, space separated, fetched through the tunnel on every check
# — a GET cut off at 64 KB, so a check costs the head of a page, not the page. A
# refusal (HTTP 403 or 451) from any of them is a failure like a wrong country and
# counts towards the same window. Google refuses single Psiphon exits per service while
# YouTube still reads them as healthy and in an accepted country: on 2026-10-19
# gemini.google.com answered 403 through an AT exit for hours and no other check here
# noticed. Nothing else is judged — not a timeout, a 5xx or a redirect: the target can
# be down for reasons of its own, and a dead tunnel is caught above. Empty disables.
PROBE_URLS='$PROBE_URLS'
# 1: the watchdog asks Gemini itself at every check (vps-psiphon-gemini-check): the
# page is fetched for its session fields, then one logged-out message is sent and held
# open until Gemini answers, two minutes at most. Error 1060 is Gemini declining this
# address on a page that answers 200 — no status-code probe sees it — and one refusal
# rotates at once. An answer that settles nothing is never grounds for a rotation; if
# every answer settles nothing for three hours, the check has likely gone stale against
# a change on Google's side, and the watchdog alerts once. About 1 MB a check. 0: off.
GEMINI_CHECK=$GEMINI_CHECK
# 1: the Gemini check fetches its page with curl-impersonate, installed by --impersonate
# in $CI_DIR, so the request carries a browser's TLS handshake. Google
# can flag an exit for browsers alone: Gemini then sends them to a captcha on
# www.google.com, and where that host does not leave through this tunnel the captcha
# cannot be solved. A redirect to it rotates at once. 0: plain curl, which that flag
# lets through. Set it with --impersonate or --no-impersonate, which also install or
# remove the build.
IMPERSONATE=$IMPERSONATE
# 1: the launcher turns Psiphon's server-sent tactics off, which keeps in-proxy (WebRTC
# through a volunteer's device) out of the tunnel protocols. 0: Psiphon and its tactics
# choose, as by default. Set with --inproxy / --no-inproxy.
EXCLUDE_INPROXY=$EXCLUDE_INPROXY
# Telegram alerts from the watchdog: a rotation (with its reason and the new exit), a
# denied country the first time it is seen, a rotation that did not bring the tunnel
# back. Sent directly, not through the tunnel. Both empty = off.
# Test with: vps-psiphon notify-test
TG_TOKEN='$TG_TOKEN'
TG_CHAT='$TG_CHAT'
# Forum topic inside that chat (message_thread_id). Empty = the chat itself.
TG_THREAD='$TG_THREAD'
# node_exporter textfile collector directory; the watchdog writes vps-psiphon.prom
# there after every check. Empty = off.
METRICS_DIR='$METRICS_DIR'
EOF
chmod 600 "$ENVF"
# Removed only once the env file says IMPERSONATE=0: removed earlier, a run that fails
# in between would leave a watchdog looking for a build that is gone.
if [ "$IMPERSONATE" = 0 ] && [ -e "$CI_DIR" ]; then
  rm -rf "${CI_DIR:?}" "${CI_DIR:?}.new" "${CI_DIR:?}.old"
  say "curl-impersonate removed: --impersonate is off"
fi

case "$IMAGE" in
  *@sha256:*) : ;;
  *) printf '\033[1;33m  !! %s is a moving tag, not a digest. What runs here can change\n' "$IMAGE"
     printf '     under you on any pull, silently. Pin it with --image name@sha256:…\033[0m\n' ;;
esac
say "pulling image"
docker pull -q "$(img_canon "$IMAGE")" >/dev/null
docker image inspect -f '{{index .RepoDigests 0}}' "$(img_canon "$IMAGE")" 2>/dev/null \
  | sed 's/^/    deployed digest: /' || true

# ---- launcher ---------------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-run <<'RUN'
#!/usr/bin/env bash
# Foreground container launcher; systemd owns the lifecycle.
set -euo pipefail
. /etc/default/vps-psiphon
@@SHARED_FUNCS@@
log() { printf 'vps-psiphon-run: %s\n' "$*" >&2; }
# Fails closed. An empty BIND would publish "-p :1080:1080", which docker reads as every
# interface: an open SOCKS5 proxy. The installer never writes one, a hand edit can; so
# nothing starts unless the address and ports are what the installer would write.
if ! [[ "${BIND:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  log "BIND='${BIND:-}' in /etc/default/vps-psiphon is not an IPv4 address — refusing to publish the proxy"
  exit 1
fi
for p in "$SOCKS_PORT" "$HTTP_PORT"; do
  [[ "$p" =~ ^[0-9]{1,5}$ ]] || { log "port '$p' in /etc/default/vps-psiphon is not a number — refusing to start"; exit 1; }
done
docker rm -f "$NAME" >/dev/null 2>&1 || true
IMG="$(img_canon "$IMAGE")"

cfg="${CONF_DIR}/psiphon.config"
# Nothing in this part may stop the tunnel from starting: every step is checked, and a
# step that fails (a full disk, a template in another shape) leaves the config as it was
# and the start goes ahead. The launcher runs under set -e, and inside a function
# called with || errexit is off, so each command carries its own || return 1.

# The image writes psiphon.config only when it is absent, from its template plus the
# ports and regions, and then never again. Seeded here from the same template, so the
# first tunnel after an install, a rotation or `region` already carries the settings
# below; the regions are written there, at every start. If the template cannot be read,
# the image seeds the file as before and the settings apply from the next start.
seed_config() {
  rm -rf "$cfg.new" 2>/dev/null
  docker run --rm --entrypoint cat "$IMG" /etc/psiphon/psiphon.config > "$cfg.new" 2>/dev/null || return 1
  grep -q '"LocalSocksProxyPort"' "$cfg.new" || return 1
  # A template cut short is not a config: its last line must close the object.
  [ "$(grep -v '^[[:space:]]*$' "$cfg.new" | tail -1 | tr -d '[:space:]')" = "}" ] || return 1
  sed -i -E \
    -e "s/\"LocalHttpProxyPort\"[[:space:]]*:[[:space:]]*[0-9]+/\"LocalHttpProxyPort\": ${HTTP_PORT}/" \
    -e "s/\"LocalSocksProxyPort\"[[:space:]]*:[[:space:]]*[0-9]+/\"LocalSocksProxyPort\": ${SOCKS_PORT}/" \
    "$cfg.new" || return 1
  if command -v jq >/dev/null 2>&1; then jq -e . "$cfg.new" >/dev/null 2>&1 || return 1; fi
  chown 1000:1000 "$cfg.new" 2>/dev/null || true
  mv "$cfg.new" "$cfg" || return 1
}
# A config that is not JSON at all stops Psiphon on every start, and the image never
# rewrites a file that exists. Where jq can tell, such a file is moved aside (kept, for
# whoever wants to see it) and seeded afresh; the server list lives in the datastore, not
# here, so nothing is lost.
if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1 && ! jq -e . "$cfg" >/dev/null 2>&1; then
  if mv -f "$cfg" "$cfg.broken" 2>/dev/null; then
    log "psiphon.config was not valid JSON — moved to psiphon.config.broken, seeding a fresh one"
  fi
fi
if [ ! -f "$cfg" ]; then
  seed_config || log "could not seed psiphon.config from the image — the image seeds it during this start"
fi
rm -rf "$cfg.new" 2>/dev/null || true

# Psiphon's servers send every client tactics: settings for the client's network,
# applied on top of this file. They put in-proxy first: the first dials of every tunnel
# go through a volunteer's device over WebRTC, which is built for users whose networks
# block Psiphon's servers. An exit carries a whole host's traffic, and through a
# volunteer's link such a tunnel almost always died within minutes or crawled at a few
# hundred KB/s, while a direct one carried megabytes a second for hours; each rotation
# drew in-proxy again (measured by vps-psiphon, whose finding this is).
#
# "DisableTactics": true is the whole fix. Every INPROXY-WEBRTC protocol is disabled by
# default in tunnel-core (DefaultDisabledTunnelProtocols), and with no protocol limit
# the client never selects a default-disabled one; only tactics can enable them, and
# with tactics off the client applies none, not even stored ones, and has no in-proxy
# broker to dial. Upstream also writes a LimitTunnelProtocols list; it names exactly the
# default-enabled set, so it adds nothing — and it is the one setting that can stop the
# client from starting, which refuses a protocol name its build does not know. It is
# not written here, and a list in the form this launcher (or upstream's) writes is
# removed.
#
# The launcher owns lines in exactly the form it writes — one space of indent, one line,
# a trailing comma — and touches no other line, so a value someone wrote by hand in
# any other form is left alone.
mode=psiphon-default
[ "${EXCLUDE_INPROXY:-1}" = 1 ] && mode=no-inproxy
# The regions come from the env file at every start, an empty one written as empty, which
# Psiphon reads as any country. The image's template says "SG" and "IN" and the image
# replaces them only with a value that is not empty, so "auto" used to exit through
# Singapore — and a config seeded by an older version still says so until this rewrites
# it. Only a value in the form the installer writes (two capital letters, or nothing) is
# written; a hand edit in any other form leaves the file's value as it is, and says so.
for v in EGRESS_REGION DEVICE_REGION; do
  if ! [[ "${!v:-}" =~ ^([A-Z]{2})?$ ]]; then
    # Written as any country rather than left to the template's SG and IN, which every
    # fresh start would bring back.
    log "$v='${!v}' in /etc/default/vps-psiphon is not a two-letter code — written as empty (any country)"
    printf -v "$v" ''
  fi
done
#
# Psiphon's window per connection, in 32 KB blocks. Its default, 4 (128 KB), caps one
# connection at about a window per round trip — ~20 Mbit/s over a 30 ms tunnel, however
# idle the tunnel is. 32 (1 MB) measured 5-14x faster per connection with no added wait
# for a small request behind eight downloads; 64 and 128 began to delay it (measured by
# vps-psiphon, whose setting this is). An owned line, as DisableTactics is below.
WINDOW=32
edit_config() {
  rm -rf "$cfg.edit" 2>/dev/null
  cp "$cfg" "$cfg.edit" || return 1
  sed -i -E \
    -e "s/\"EgressRegion\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"EgressRegion\": \"${EGRESS_REGION:-}\"/" \
    -e "s/\"DeviceRegion\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"DeviceRegion\": \"${DEVICE_REGION:-}\"/" \
    -e '/^ "SSHChannelWindowSize": [0-9]+,$/d' \
    "$cfg.edit" || return 1
  sed -i "0,/{/s/{/{\n \"SSHChannelWindowSize\": $WINDOW,/" "$cfg.edit" || return 1
  [ "$(grep -c "^ \"SSHChannelWindowSize\": $WINDOW,\$" "$cfg.edit")" = 1 ] || return 1
  sed -i -E -e '/^ "DisableTactics": (true|false),$/d' \
            -e '/^ "LimitTunnelProtocols": \[[^]]*\],$/d' "$cfg.edit" || return 1
  if [ "$mode" = no-inproxy ]; then
    sed -i '0,/{/s/{/{\n "DisableTactics": true,\n/' "$cfg.edit" || return 1
    sed -i '/^$/d' "$cfg.edit" || return 1
    [ "$(grep -c '^ "DisableTactics": true,$' "$cfg.edit")" = 1 ] || return 1
  fi
  grep -q '"LocalSocksProxyPort"' "$cfg.edit" || return 1
  if command -v jq >/dev/null 2>&1; then jq -e . "$cfg.edit" >/dev/null 2>&1 || return 1; fi
  # Unchanged is left unwritten, so the file is not rewritten on every start.
  if cmp -s "$cfg" "$cfg.edit"; then rm -f "$cfg.edit"; return 0; fi
  chown --reference="$cfg" "$cfg.edit" 2>/dev/null || true
  mv -f "$cfg.edit" "$cfg" || return 1
}
if [ -f "$cfg" ]; then
  if ! edit_config; then
    rm -rf "$cfg.edit" 2>/dev/null || true
    mode=unedited
    log "could not edit psiphon.config (not in the shape this launcher edits, or a step failed) — started as it is, in-proxy NOT excluded"
  elif [ "$mode" = no-inproxy ] && grep -qE '"DisableTactics"[[:space:]]*:[[:space:]]*false' "$cfg"; then
    # Written by hand in another form, and left alone — but a later key wins in Go's
    # JSON, so tactics are on and in-proxy is not kept out; reported, not overruled.
    mode=overridden
    log "psiphon.config sets \"DisableTactics\": false itself — tactics stay on, in-proxy NOT excluded"
  fi
elif [ "$mode" = no-inproxy ]; then
  # The image seeds the file during this start; the setting applies from the next.
  mode=pending
fi
# What this start did, for `vps-psiphon status` and the watchdog.
printf '%s %s\n' "$(date +%s)" "$mode" > /var/lib/vps-psiphon-run.state 2>/dev/null || true

# NOTE: the BIND prefix is load-bearing. Publishing without it exposes an OPEN SOCKS5
# PROXY to the internet — psiphon binds 0.0.0.0 inside the container. Both addresses
# this installer picks on its own are host-private; a --bind you typed yourself is
# honoured as given, a public one included, and the access control it then needs is
# yours to add.
PUB=( -p "${BIND}:${SOCKS_PORT}:${SOCKS_PORT}" )
# Default to publishing it, so env files written before this was an option keep
# their old behaviour instead of silently losing the HTTP proxy.
[ "${PUBLISH_HTTP:-1}" = 1 ] && PUB+=( -p "${BIND}:${HTTP_PORT}:${HTTP_PORT}" )
exec docker run --rm --name "$NAME" \
  "${PUB[@]}" \
  --memory="${MEM_LIMIT:-512m}" --pids-limit="${PIDS_LIMIT:-256}" \
  --log-opt max-size="${LOG_MAX_SIZE:-10m}" --log-opt max-file="${LOG_MAX_FILE:-3}" \
  -e PUID=1000 -e PGID=1000 \
  -e SOCKS_PORT="$SOCKS_PORT" -e HTTP_PORT="$HTTP_PORT" \
  -e DEVICE_REGION="$DEVICE_REGION" -e EGRESS_REGION="$EGRESS_REGION" \
  -v "${CONF_DIR}:/config" \
  "$IMG"
RUN
put_shared_funcs /usr/local/sbin/vps-psiphon-run
chmod 755 /usr/local/sbin/vps-psiphon-run

# ---- region pool ------------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-advance-region <<'ADV'
#!/usr/bin/env bash
# Advance EGRESS_REGION to the next country in REGION_POOL. Prints "old -> new" when it
# changes anything, silent when there is no pool.
#
# Rotating within one country retries exactly the servers that are exhausted when it
# is busy; walking a pool draws on another country instead, without handing the choice
# to "auto", which may answer from another continent.
#
# Only the env file is edited. Both callers, the watchdog and `vps-psiphon rotate`, then
# start the client on an empty config directory, and the launcher writes the region
# from the env file into psiphon.config at every start.
set -uo pipefail
ENVF=/etc/default/vps-psiphon
# shellcheck source=/dev/null
[ -r "$ENVF" ] && . "$ENVF"
[ -n "${REGION_POOL:-}" ] || exit 0

cur="${EGRESS_REGION:-}"; first=""; nxt=""; take=0
for r in $REGION_POOL; do
  # The pool is edited by hand too; a value the installer would not write is skipped,
  # not copied into EGRESS_REGION, where the launcher would refuse it at every start.
  [[ "$r" =~ ^[A-Z]{2}$ ]] || continue
  [ -z "$first" ] && first="$r"
  if [ "$take" = 1 ]; then nxt="$r"; break; fi
  [ "$r" = "$cur" ] && take=1
done
# Not in the pool (hand-edited, or the pool changed under us) falls to the first
# entry, which is also what makes the last entry wrap around.
[ -n "$nxt" ] || nxt="$first"
[ -n "$nxt" ] || exit 0   # no usable country in the pool at all
[ "$nxt" = "$cur" ] && exit 0

sed -i "s/^EGRESS_REGION=.*/EGRESS_REGION=$nxt/" "$ENVF"
printf '%s -> %s\n' "${cur:-auto}" "$nxt"
ADV
chmod 0755 /usr/local/sbin/vps-psiphon-advance-region

# ---- gemini check -----------------------------------------------------------
# Ported from vps-psiphon 1.2 (Chara-Freedom), whose measurements the comments cite.
cat > /usr/local/sbin/vps-psiphon-gemini-check <<'GEM'
#!/usr/bin/env bash
# Asks Gemini itself whether it serves this exit, and prints one line:
#   exit 0  ok            Gemini replied; the line names the place it puts us in, when
#                         Gemini names one
#   exit 1  REFUSED       error 1060: Gemini declines this address
#   exit 2  inconclusive  anything else — never grounds for a rotation
#   exit 3  CAPTCHA       with IMPERSONATE=1 only: Google sends a browser on this exit to
#                         its captcha on www.google.com/sorry
# Logged out: the page is fetched for its session fields and cookies, then one message
# is sent and held open until Gemini answers (two minutes at most). The page answers
# 200 even where Gemini refuses the address, which is why a status-code probe cannot
# see a refusal and this asks.
#
# With IMPERSONATE=1 the page is fetched by curl-impersonate as the newest Chrome it
# knows. Google can flag an exit for browsers alone: on one such exit every browser
# handshake (Chrome, Firefox, Safari) was redirected to the captcha, with or without a
# browser's headers, while plain curl got the page, with or without them — the
# handshake decides. The message itself still goes by plain curl.
#
#   --direct  probe from this host's own address instead of through the tunnel, to
#             tell a burned exit apart from a refusal that follows the whole host.
set -uo pipefail
# shellcheck source=/dev/null
[ -r /etc/default/vps-psiphon ] && . /etc/default/vps-psiphon
P=(--socks5-hostname "${BIND:-127.0.0.1}:${SOCKS_PORT:-1080}")
[ "${1:-}" = --direct ] && P=(-4)
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
d="$(mktemp -d)" || { echo "inconclusive (no temp dir)"; exit 2; }
trap 'rm -rf "$d"' EXIT
C=(-s "${P[@]}" -A "$UA" -H 'Accept-Language: en-US,en;q=0.9' -b "$d/jar" -c "$d/jar")

# The browser build sends its own coherent headers, so it gets no -A or -H of ours.
G=(curl "${C[@]}"); imp=0; note=""
if [ "${IMPERSONATE:-0}" = 1 ]; then
  ci=/opt/vps-psiphon/curl-impersonate
  n="$(find "$ci" -maxdepth 1 -name 'curl_chrome*' 2>/dev/null \
       | sed -n 's#^.*/curl_chrome\([0-9][0-9]*\)$#\1#p' | sort -n | tail -1)"
  if [ -n "$n" ] && [ -x "$ci/curl-impersonate" ]; then
    G=("$ci/curl_chrome$n" -s "${P[@]}" -b "$d/jar" -c "$d/jar"); imp=1
  else
    note=" (impersonate is on, but no curl-impersonate build is installed: the page went by plain curl)"
  fi
fi

code="$("${G[@]}" --max-time 30 -o "$d/app" -D "$d/head" -w '%{http_code}' https://gemini.google.com/app 2>/dev/null || true)"
if [ "$imp" = 1 ] && [ "$code" = 302 ] &&
   grep -qiE '^location: *https://([a-z0-9-]+\.)*google\.[a-z]{2,3}(\.[a-z]{2})?/sorry/' "$d/head" 2>/dev/null; then
  echo "CAPTCHA — Google sends a browser on this exit to /sorry, Gemini not asked"; exit 3
fi
bl="$(grep -oE '"cfb2h":"[^"]+"' "$d/app" 2>/dev/null | head -1 | cut -d'"' -f4)"
sid="$(grep -oE '"FdrFJe":"[^"]+"' "$d/app" 2>/dev/null | head -1 | cut -d'"' -f4)"
if [ -z "$bl" ] || [ -z "$sid" ]; then
  echo "inconclusive (page answered ${code:-nothing}, without the session fields)$note"; exit 2
fi
# Both go into a URL: anything but the plain characters Google uses is a page this does
# not understand, not something to pass on.
if printf '%s\n%s\n' "$bl" "$sid" | grep -qvxE '[A-Za-z0-9._-]+'; then
  echo "inconclusive (the session fields are not in the form this check knows)$note"; exit 2
fi

U='https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate'
H=(-H 'Content-Type: application/x-www-form-urlencoded;charset=utf-8'
   -H 'Origin: https://gemini.google.com' -H 'Referer: https://gemini.google.com/' -H 'X-Same-Domain: 1')
Q="$U?bl=${bl}&f.sid=${sid}&hl=en&_reqid=$(( RANDOM * 10 + 100000 ))&rt=c"
M='f.req=[null,"[[\"hi\"],null,null]"]'

# Gemini can take a minute or more to answer, while Psiphon's servers close a connection
# on which no byte has moved for 30 s. So a second request rides the same HTTP/2
# connection and keeps it busy: its body trickles one byte every 2 s until the message's
# transfer is over (its -w line goes to stderr, unbuffered, into $d/w). Google answers
# that request 400 once its body ends, and the answer is discarded.
#
# That needs a curl with --parallel (7.66) and HTTP/2. Without them the message goes
# alone: a refusal that arrives inside 30 s is still read, a slower answer is lost, and
# the line says so — an older curl must cost precision, not the whole check.
# Read into variables, not piped into grep -q: grep stops at the first match, curl then
# dies of SIGPIPE, and under pipefail the match reads as a miss.
ch="$( { curl --help all; curl --help; } 2>/dev/null )"; cv="$(curl -V 2>/dev/null)"
if [[ "$ch" == *--parallel* ]] && [[ "$cv" == *HTTP2* ]]; then
  i=0
  # Once curl is done the pipe is closed: the next byte would fail with "write error:
  # Broken pipe" on stderr, so a failed write ends the trickle, quietly.
  while ! grep -q message-done "$d/w" 2>/dev/null && [ "$i" -lt 60 ]; do
    sleep 2; printf x 2>/dev/null || break; i=$((i + 1))
  done |
    curl --parallel "${C[@]}" "${H[@]}" --max-time 130 -o "$d/out" -w '%{stderr}message-done' \
      --data-urlencode "$M" "$Q" \
      --next "${C[@]}" "${H[@]}" -X POST -T - --max-time 130 -o /dev/null \
      -w '%{stderr}\nkeepalive-done %{http_code} %{time_total}\n' "$U?rt=c" \
      >/dev/null 2>"$d/w"
  # The keep-alive request is meant to end with the message. If it ended first — Google
  # answered it before its body was over — the hold did not hold, and an answer that
  # then never came says why.
  if ! grep -q message-done "$d/w" 2>/dev/null || [ "$(grep -o 'keepalive-done\|message-done' "$d/w" | head -1)" = keepalive-done ]; then
    ka="$(grep -o 'keepalive-done [0-9]* [0-9.]*' "$d/w" 2>/dev/null | head -1)"
    [ -n "$ka" ] && note="$note (the keep-alive request ended before the answer: HTTP $(echo "$ka" | cut -d' ' -f2) after $(echo "$ka" | cut -d' ' -f3)s)"
  fi
else
  curl "${C[@]}" "${H[@]}" --max-time 130 -o "$d/out" --data-urlencode "$M" "$Q" >/dev/null 2>&1
  note="$note (curl here cannot hold the answer open: one slower than Psiphon's 30 s idle cut is lost)"
fi

# 1060 decides first: a held answer can open with a frame that is not a reply. Served
# means a reply that names the place; 1096 trails every logged-out reply and says
# nothing. The code opens the error's array: once a bare [1060], now [1060,null,"…"].
errs="$(grep -oE 'BardErrorInfo",\[[0-9]+' "$d/out" 2>/dev/null | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')"
case " $errs " in
  *" 1060 "*) echo "REFUSED — Gemini declines this exit (error 1060, no reply)$note"; exit 1 ;;
esac
where="$(grep -oE '\\"[^"\\]+\\",\\"SWML_DESCRIPTION' "$d/out" 2>/dev/null | head -1 | cut -d'"' -f2 | tr -d '\\')"
[ -n "$where" ] && { echo "ok — Gemini replies, and places this exit in $where$note"; exit 0; }
# A reply is a response candidate ("rc_…") carrying text. Upstream asks for a place as
# well, but Gemini does not name one everywhere: measured from a US datacenter on
# 2026-11-05, it answered "Hello! How can I help you today?" with no place, run after
# run — a served exit that a place rule calls inconclusive for good. A frame that is
# not a reply (the conversation's ids, its title) still settles nothing. The reply's
# head goes into the line, so an answer that is itself an error reads as one.
said="$(grep -oE 'rc_[0-9a-f]+\\",\[\\"[^"\\]{1,60}' "$d/out" 2>/dev/null | tail -1 | sed 's/.*\[\\"//')"
# A reply that reads like a refusal in words is not counted as served: Gemini's refusal
# is error 1060, and a worded one is a form this check does not know, so it settles
# nothing — and leaves the stale-check alert armed — rather than passing as ok.
case "$(printf '%s' "$said" | tr '[:upper:]' '[:lower:]')" in
  *"not available"*|*"available in your"*|*unavailable*|*"your region"*|*"your country"*)
    echo "inconclusive (a reply that reads like a refusal: \"$said…\")$note"; exit 2 ;;
esac
[ -n "$said" ] && { echo "ok — Gemini replies (\"$said…\"), naming no place$note"; exit 0; }
if grep -q '"wrb.fr",null,"\[' "$d/out" 2>/dev/null; then
  echo "inconclusive (an answer without a reply${errs:+, error ${errs% }})$note"; exit 2
fi
# A message Google sends to its captcha gets a 302 page in place of an answer. Told apart
# from silence in the log, but never a rotation: the message goes by plain curl, and a
# captcha for curl's handshake says nothing about what a browser gets on this exit —
# rotating on the browser's captcha is IMPERSONATE's job, above. (vps-psiphon 1.3.)
if grep -qiE 'https://([a-z0-9-]+\.)*google\.[a-z]{2,3}(\.[a-z]{2})?/sorry/' "$d/out" 2>/dev/null; then
  echo "inconclusive (the message was sent to /sorry${errs:+, error ${errs% }})$note"; exit 2
fi
echo "inconclusive (no reply${errs:+, error ${errs% }})$note"; exit 2
GEM
chmod 755 /usr/local/sbin/vps-psiphon-gemini-check

# ---- watchdog ---------------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-watchdog <<'WD'
#!/usr/bin/env bash
# Rotation triggers, in order of how certain they are:
#   1. tunnel dead    — SOCKS does not answer.
#   2. denied country — Google places this exit in a sanctioned or Google-blocked
#      region. Checked first and in EVERY mode: under auto with no OK_REGIONS the
#      allow-list judges nothing, which is precisely when a sanctioned exit would go
#      unnoticed. The two lists are not alternatives — acceptable countries are a
#      closed, short set, dangerous ones an open one, so the latter is named and
#      checked unconditionally.
#   3. wrong country  — Google's verdict about this exit, published in YouTube's page
#      source as "GL":"XX", is not one we accept. This is what makes Cloudflare WARP
#      unusable for region-gated services: WARP reads back as the client's own
#      country. Not every mismatch weighs the same — Psiphon is used mostly from
#      America, so Google has reclassified many of its exits as US, which is harmless;
#      a rewrite to a sanctioned region is trigger 2.
#   4. stalled tunnel — SOCKS answers the liveness probe, yet no HTTP request through
#      the tunnel completes. Judged by the ABSENCE of a response, never by its size,
#      so a captcha page is not mistaken for a stall.
#   5. slow tunnel    — the exit answers from an accepted country but carries almost
#      nothing. Psiphon picks its server per tunnel, so a bad pick stays until
#      something forces a reconnect while liveness and country read green throughout;
#      without this gate a 30-90x collapse is invisible. Measured on the YouTube fetch
#      below, and skipped for THROUGHPUT_GRACE_SEC after a start while the tunnel is
#      still ramping.
#   6. refused by target — a service the exit is for (PROBE_URLS) turns it away with
#      403 or 451 while every check above reads green. Google refuses single Psiphon
#      exits per service: gemini.google.com answered 403 through an exit that YouTube
#      judged healthy, fast and US, for hours, until a rotation was made by hand.
#
#   7. Gemini refuses — GEMINI_CHECK=1 (the default): Gemini itself is asked at every
#      check, since its answer about an exit can change while the tunnel lasts. Error
#      1060 arrives on a page that answers 200, so trigger 6 never sees it. One refusal
#      is decisive: it rotates without waiting for the failure window (the cooldown
#      still applies). Ported from vps-psiphon, as is trigger 8.
#   8. browser captcha — IMPERSONATE=1 only: the Gemini check's page, fetched with a
#      browser's handshake, is redirected to www.google.com/sorry. Where that host
#      leaves from another address, the captcha cannot be solved; decisive as well.
#
# Google's /sorry captcha for plain curl (below) is recorded but never rotates on its
# own: a human solves one in seconds, and churning the tunnel over it costs more than
# it saves.
#
# Failures belong to the tunnel they were counted on: a tunnel started by anything —
# this watchdog, `rotate`, `region`, the installer, a crash — begins with an empty
# window, and a check during which the tunnel restarted is not judged at all. Rotations
# that keep not helping back off (ROTATE_COOLDOWN_MAX), and a Gemini check that keeps
# settling nothing raises an alert, because a check that has gone stale against a change
# on Google's side looks exactly like a healthy exit.
set -uo pipefail
. /etc/default/vps-psiphon
@@SHARED_FUNCS@@
LOG=/var/log/vps-psiphon-watchdog.log
STATE=/var/lib/vps-psiphon-watchdog.state
S=(--socks5-hostname "${BIND:-127.0.0.1}:${SOCKS_PORT}")
touch "$LOG" 2>/dev/null
log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

# One writer at a time. `vps-psiphon rotate`, `region` and `update-image` take the same
# lock: without it a manual rotate landing mid-check restarts the tunnel twice, and
# both sides rewrite the state and env files under each other. A check that finds the
# lock taken is skipped, not queued — the next timer tick is ten minutes away.
exec 9>/run/vps-psiphon.lock
if ! flock -n 9; then
  log "skipped: another vps-psiphon operation (installer or a manual command) holds the lock"
  exit 0
fi

# Telegram, sent directly rather than through the tunnel: an alert about a dead tunnel
# must not depend on it. The token is part of the URL, so it reaches curl through a
# config on stdin — never argv, where any local user could read it in ps.
notify() {
  [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_TOKEN" \
    | curl -s -o /dev/null --max-time 10 -K - \
        --data-urlencode "chat_id=${TG_CHAT}" \
        ${TG_THREAD:+--data-urlencode "message_thread_id=${TG_THREAD}"} \
        --data-urlencode "text=vps-psiphon @ $(hostname): $*" >/dev/null 2>&1 || true
}

fails=0; last_rotate=0; captcha=0; window=""; rotations=0; last_reason=""; denied_gl=""
refused_seen=""; tunnel=""; futile=0; backoff_seen=0; gem_streak=0; gem_stale_seen=0
imp_missing_seen=0; run_mode_seen=""
# shellcheck source=/dev/null
[ -r "$STATE" ] && . "$STATE"
# Everything comes back from a file that is sourced, and goes back into it. Each value
# is held to the form this script writes, or starts over: a counter is a plain decimal
# of at most 12 digits (a leading zero would read as octal, "08" as an error, and a huge
# one would overflow into a cooldown that never ends); a flag is 0 or 1; the window is
# a string of 0s and 1s. Nothing else is carried forward, so a bad value cannot repeat.
for v in last_rotate rotations futile gem_streak; do
  if [[ "${!v}" =~ ^[0-9]{1,12}$ ]]; then printf -v "$v" '%s' "$((10#${!v}))"; else printf -v "$v" 0; fi
done
for v in captcha backoff_seen gem_stale_seen imp_missing_seen; do
  case "${!v}" in 0|1) : ;; *) printf -v "$v" 0 ;; esac
done
[[ "$window" =~ ^[01]{0,64}$ ]] || window=""
[[ "$denied_gl" =~ ^([A-Z]{2})?$ ]] || denied_gl=""
# A last rotation in the future — the clock stepped back, say — would hold every
# rotation until the clock caught up; counted from now instead, it holds one cooldown.
[ "$last_rotate" -gt "$(date +%s)" ] && last_rotate="$(date +%s)"
# Tuning from the env file, held to sane numbers: a threshold of 0 would rotate a
# healthy tunnel at every cooldown.
[[ "${FAIL_THRESHOLD:-}" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$FAIL_THRESHOLD))" -ge 1 ] && FAIL_THRESHOLD=$((10#$FAIL_THRESHOLD)) || FAIL_THRESHOLD=2
[[ "${FAIL_WINDOW:-}" =~ ^[0-9]{1,2}$ ]] && [ "$((10#$FAIL_WINDOW))" -ge 1 ] && FAIL_WINDOW=$((10#$FAIL_WINDOW)) || FAIL_WINDOW=5
[[ "${GEMINI_STALE_CHECKS:-}" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$GEMINI_STALE_CHECKS))" -ge 1 ] && GEMINI_STALE_CHECKS=$((10#$GEMINI_STALE_CHECKS)) || GEMINI_STALE_CHECKS=18

# %q: the reason carries spaces, quotes and parentheses, and this file is sourced.
save_state() {
  {
    # No fails: it is always counted afresh from the window.
    printf 'last_rotate=%q\ncaptcha=%q\nwindow=%q\nrotations=%q\n' \
      "$last_rotate" "$captcha" "$window" "$rotations"
    printf 'last_reason=%q\ndenied_gl=%q\nrefused_seen=%q\ntunnel=%q\nfutile=%q\nbackoff_seen=%q\n' \
      "$last_reason" "$denied_gl" "$refused_seen" "$this_tunnel" "$futile" "$backoff_seen"
    printf 'gem_streak=%q\ngem_stale_seen=%q\nimp_missing_seen=%q\nrun_mode_seen=%q\n' \
      "$gem_streak" "$gem_stale_seen" "$imp_missing_seen" "$run_mode_seen"
  } > "$STATE"
}

# Every tunnel the client brings up, with its protocol: after a rotation, after the
# client's own reconnect inside a running container, after any restart. The client
# stores the parameters of each tunnel that connected, one record per server, with the
# time it connected and its protocol; the record outlives the container. Each tunnel is
# logged once; the first run after an install starts from the container's own start.
# This is where the in-proxy exclusion shows: no INPROXY-WEBRTC-… line while it holds.
SEEN=/var/lib/vps-psiphon-watchdog.seen
DB="${CONF_DIR:-/opt/vps-psiphon/config}/ca.psiphon.PsiphonTunnel.tunnel-core/datastore/psiphon.boltdb"
log_tunnels() {
  local last="" max ts proto ns
  [ -r "$SEEN" ] && last="$(cat "$SEEN" 2>/dev/null)"
  # Nanoseconds since 1970 are 19 digits; anything longer would overflow, and a leading
  # zero would read as octal. Either starts over from the container's start.
  if [[ "$last" =~ ^[1-9][0-9]{0,18}$ ]]; then last=$((10#$last)); else last=""; fi
  if ! [[ "$last" =~ ^[0-9]+$ ]]; then
    # No container, no start time: `date -d ""` would read as midnight and log the day.
    last="$(docker inspect -f '{{.State.StartedAt}}' "${NAME:-vps-psiphon}" 2>/dev/null)"
    [ -n "$last" ] || return 0
    last="$(date -d "$last" +%s%N 2>/dev/null)"
    [[ "$last" =~ ^[0-9]+$ ]] || return 0
    last=$(( last - 60000000000 ))
  fi
  [ -r "$DB" ] || return 0
  max="$last"
  # Times carry nanoseconds of varying length, so they are compared as numbers.
  while read -r ns proto ts; do
    [[ "$ns" =~ ^[1-9][0-9]{0,18}$ ]] || continue
    [ "$ns" -gt "$last" ] || continue
    log "tunnel up: $proto (dialled at $ts)"
    [ "$ns" -gt "$max" ] && max="$ns"
  done < <(grep -aoE '"LastUsedTimestamp":"[^"]+"[^{}]{0,600}"TunnelProtocol":"[A-Z0-9-]+"' "$DB" 2>/dev/null \
             | sed -E 's/"LastUsedTimestamp":"([^"]+)".*"TunnelProtocol":"([^"]+)"/\1 \2/' | sort -u \
             | while read -r ts proto; do
                 printf '%s %s %s\n' "$(date -d "$ts" +%s%N 2>/dev/null || echo 0)" "$proto" "$ts"
               done | sort -n)
  printf '%s\n' "$max" > "$SEEN"
}
log_tunnels

# The tunnel this check is about, by the container's start time.
this_tunnel="$(docker inspect -f '{{.State.StartedAt}}' "${NAME:-vps-psiphon}" 2>/dev/null)"
if [ "$tunnel" != "$this_tunnel" ]; then
  # Whatever restarted it, the fresh tunnel starts from zero instead of inheriting a
  # reading that was never its own: one slow check of its own would otherwise complete
  # the old tunnel's window and rotate it away. It is a new exit, so the once-only
  # alerts start over too. The cooldown and the back-off are about rotations, not
  # tunnels, and carry on.
  [ -n "$tunnel" ] && [ -n "$window" ] && log "new tunnel (started ${this_tunnel:-?}): the failure window starts over"
  window=""; denied_gl=""; refused_seen=""
fi

# What the launcher made of the last start (see vps-psiphon-run). "unedited" means it
# could not read psiphon.config in the shape it edits, so in-proxy is NOT kept out: said
# once, when it first happens.
run_mode="$(awk '{print $2}' /var/lib/vps-psiphon-run.state 2>/dev/null)"
if [ -n "$run_mode" ] && [ "$run_mode" != "$run_mode_seen" ]; then
  if [ "$run_mode" = unedited ]; then
    log "launcher could not edit psiphon.config: in-proxy is not excluded on this tunnel"
    notify "the launcher could not edit psiphon.config (not in the shape it knows), so in-proxy is NOT kept out of this tunnel. See journalctl -u vps-psiphon and $CONF_DIR/psiphon.config"
  elif [ "$run_mode" = pending ]; then
    # The image seeded the config itself, so this tunnel runs on its template: in-proxy
    # not kept out, auto as SG. Every rotation starts on an empty directory, so until
    # the template can be read again (a changed image, say) no start ever catches up.
    log "launcher could not seed psiphon.config from the image: in-proxy is not excluded on this tunnel"
    notify "the launcher could not seed psiphon.config from the image's template, so this tunnel runs on the image's own config: in-proxy is NOT kept out, and auto exits through the template's SG. Every rotation repeats this. See journalctl -u vps-psiphon"
  fi
  run_mode_seen="$run_mode"
fi

alive=0
# Retry once: a check that races tunnel establishment (boot, restart, rotate)
# would otherwise log a failure the tunnel never actually had.
for attempt in 1 2; do
  code="$(curl -s -o /dev/null --max-time 20 "${S[@]}" -w '%{http_code}' \
          https://www.gstatic.com/generate_204 2>/dev/null || true)"
  [ "$code" = "204" ] && { alive=1; break; }
  [ "$attempt" = 1 ] && sleep 15
done

reason=""; gl=""; kbps=""; refused=""
if [ "$alive" = 0 ]; then
  reason="socks-dead"
else
  # One fetch serves two checks: the country verdict and how fast it arrived.
  ytf="$(mktemp)"
  # The status code is read alongside the rate: the two failures below are told apart
  # by whether an HTTP transaction completed at all, not by how big it was.
  # curl prints -w even when it gives up at --max-time, so a fallback must not be
  # APPENDED to that output: "12345 200" followed by "0 000" reads back as status 000,
  # and a transfer that had its response and ran out of time judged as a stall. Only an
  # empty or malformed answer falls back.
  # Its exit status is kept: 28 is curl giving up at --max-time, which tells a slow
  # transfer that had its response apart from one that finished.
  probe="$(LC_ALL=C curl -s --max-time 25 "${S[@]}" -H 'Accept-Language: en-US' \
           -o "$ytf" -w '%{speed_download} %{http_code}' https://www.youtube.com/ 2>/dev/null)"
  yrc=$?
  spd="${probe%% *}"; spd="${spd%%.*}"; ytcode="${probe##* }"
  case "$spd" in ''|*[!0-9]*) spd=0 ;; esac
  case "$ytcode" in [0-9][0-9][0-9]) : ;; *) ytcode=000 ;; esac
  gl="$(grep -oE '"GL":"[A-Z]{2}"' "$ytf" 2>/dev/null | head -1 | cut -d'"' -f4)"
  got="$(stat -c %s "$ytf" 2>/dev/null || echo 0)"
  rm -f "$ytf"
  kbps=$(( spd / 1024 ))
  if [ -n "$gl" ]; then
    # Deny runs first and in every mode: under auto with no OK_REGIONS the allow-list
    # below is empty by definition and judges nothing.
    denied=0
    case " ${DENY_REGIONS:-} " in
      *" $gl "*) reason="denied-country (Google sees $gl — sanctioned or Google-blocked)"; denied=1 ;;
    esac
    # Alerted once per country, not on every check until the rotation lands.
    if [ "$denied" = 1 ] && [ "$denied_gl" != "$gl" ]; then
      notify "exit is seen as $gl (denied) — rotating once the failure window fills"
    fi
    [ "$denied" = 1 ] && denied_gl="$gl" || denied_gl=""
    # What we ASK Psiphon for and what we ACCEPT from Google are different lists:
    # Google rewrites many exits to US whatever country they report, so judging the
    # verdict against the request rotated a fast, healthy FR exit away for nothing.
    if [ "$denied" = 0 ]; then
      acc="${ACCEPT_REGIONS:-}"
      if [ -z "$acc" ]; then
        if [ -n "${REGION_POOL:-}${EGRESS_REGION:-}" ]; then
          # Everything requested — the pool, plus a region pinned outside it by hand
          # — and US, the one harmless rewrite. Deduplicated for the log line.
          for r in ${REGION_POOL:-} ${EGRESS_REGION:-} US; do
            case " $acc " in *" $r "*) ;; *) acc="${acc:+$acc }$r" ;; esac
          done
        else
          # Auto with an operator-set allow-list behaves as always; auto with neither
          # leaves the deny-list as the only country check, as documented.
          acc="${OK_REGIONS:-}"
        fi
      fi
      if [ -n "$acc" ] && [ "$acc" != any ]; then
        case " $acc " in
          *" $gl "*) : ;;
          *) reason="wrong-country (Google sees $gl; asked ${EGRESS_REGION:-auto}, accepted '$acc')" ;;
        esac
      fi
    fi
  fi
  # Throughput gate. A truncated fetch is itself a symptom, so a partial download still
  # counts once it carries enough bytes for a rate to mean anything. Rotating drops
  # every live client connection, hence the failure window and the cooldown below.
  #
  # Tunnel age, so a rate measured while it is still ramping is recorded but not
  # judged. An unknown age (no docker, renamed container) reads as old rather than
  # young: disabling the gate on a failed lookup is the worse of the two mistakes.
  up_for=999999
  started="$this_tunnel"
  [ -n "$started" ] && up_for=$(( $(date +%s) - $(date -d "$started" +%s 2>/dev/null || echo 0) ))
  # A tunnel that completes no HTTP transaction at all, seconds after SOCKS answered
  # the liveness probe, is broken — and it used to read as healthy, since a zero-byte
  # fetch falls straight through the 50 KB rate gate below and logs "0 KB/s" with no
  # verdict. Judged by the ABSENCE of a response, never by a small one: a captcha is a
  # small response, and rotating on a captcha is deliberately not wanted. `ytcode` is
  # named apart from the liveness probe's `code` so that reordering them cannot pass
  # silently.
  if [ -z "$reason" ] && [ "$ytcode" = "000" ]; then
    reason="stalled-tunnel (no HTTP response in 25s while SOCKS answered)"
  fi
  if [ -z "$reason" ] && [ "${MIN_THROUGHPUT_KBPS:-0}" -gt 0 ] && [ "$got" -ge 50000 ]; then
    if [ "$kbps" -lt "${MIN_THROUGHPUT_KBPS}" ]; then
      if [ "$up_for" -lt "${THROUGHPUT_GRACE_SEC:-900}" ]; then
        log "slow (${kbps} KB/s) but the tunnel is ${up_for}s old — still ramping, not judged"
      else
        reason="slow-tunnel (${kbps} KB/s < ${MIN_THROUGHPUT_KBPS} KB/s floor)"
      fi
    fi
  fi
  # A response that arrived but could not finish in 25 s is slow whatever its size.
  # Below 50 KB the rate gate above does not look at it, and it is not a stall either —
  # so without this it passed as healthy. Part of the throughput gate: off with it, and
  # held back during the same grace period. A captcha is small and finishes at once,
  # so it never lands here.
  if [ -z "$reason" ] && [ "$yrc" = 28 ] && [ "$ytcode" != 000 ] \
     && [ "${MIN_THROUGHPUT_KBPS:-0}" -gt 0 ]; then
    if [ "$up_for" -lt "${THROUGHPUT_GRACE_SEC:-900}" ]; then
      log "timed out at ${kbps} KB/s but the tunnel is ${up_for}s old — still ramping, not judged"
    else
      reason="slow-tunnel (timed out after 25s at ${kbps} KB/s, ${got} bytes)"
    fi
  fi
  # The services the exit is for (PROBE_URLS). Only a refusal is judged: a 403 or 451
  # is the target turning this address away, which a new exit fixes; a timeout, a 5xx
  # or a redirect says nothing about the exit, and a dead tunnel is caught above.
  # --max-filesize ends a healthy fetch after 64 KB — curl exits 63 with the status
  # already known — so a check does not pull a whole app shell through the tunnel.
  # Read into an array, not word-split, so a '?' in a URL is never taken for a glob.
  read -r -a probe_urls <<< "${PROBE_URLS:-}"
  for u in "${probe_urls[@]}"; do
    pc="$(curl -s -o /dev/null --max-time 20 --max-filesize 65536 "${S[@]}" \
          -H 'Accept-Language: en-US' -w '%{http_code}' "$u" 2>/dev/null)"
    case "$pc" in
      403|451) h="${u#*://}"; refused="${refused:+$refused, }${h%%/*} $pc" ;;
    esac
  done
  if [ -n "$refused" ]; then
    [ -z "$reason" ] && reason="refused-by-target ($refused through this exit)"
    # Alerted once per refusal, like a denied country, not on every check until the
    # rotation lands.
    [ "$refused_seen" != "$refused" ] \
      && notify "$refused through this exit — rotating once the failure window fills"
    refused_seen="$refused"
  else
    refused_seen=""
  fi
  # Informational only, and logged on change so a captcha'd exit does not fill the log.
  rd="$(curl -s -o /dev/null --max-time 25 "${S[@]}" -w '%{redirect_url}' \
        'https://www.google.com/search?q=status' 2>/dev/null || true)"
  now_captcha=0; case "$rd" in */sorry/*) now_captcha=1 ;; esac
  if [ "$now_captcha" != "$captcha" ]; then
    [ "$now_captcha" = 1 ] && log "note: Google now serves a captcha to this exit (informational, no action)" \
                           || log "note: Google no longer serves a captcha to this exit"
  fi
  captcha="$now_captcha"
fi

# Gemini itself (trigger 7, and 8 with IMPERSONATE=1). Asked whenever the tunnel carries
# HTTP at all; a dead or stalled one answers nothing worth reading. Bounded from outside
# as well as inside, so a hung transfer cannot hold the lock past the next check.
decisive=0; gem=""; grc=""
if [ "${GEMINI_CHECK:-1}" = 1 ] && [ "$alive" = 1 ] && [ "${ytcode:-000}" != 000 ]; then
  gem="$(timeout 200 /usr/local/sbin/vps-psiphon-gemini-check 2>/dev/null)"; grc=$?
  gem="${gem%%$'\n'*}"   # one line into the log, whatever the check printed
  case "$grc" in
    0|1|3) : ;;
    124) grc=2; gem="inconclusive (the check ran past 200 s and was stopped)" ;;
    *)   grc=2; gem="${gem:-inconclusive (the check printed nothing)}" ;;
  esac
  log "gemini: $gem"
  if [ "$grc" = 1 ]; then
    decisive=1
    reason="gemini-refused (error 1060 — one refusal is decisive)${reason:+; also $reason}"
  elif [ "$grc" = 3 ]; then
    decisive=1
    reason="google-captcha (a browser on this exit is sent to /sorry — decisive)${reason:+; also $reason}"
  fi
  # A check that settles nothing for three hours protects nothing. That is how the
  # upstream check failed silently for days when Gemini changed the frame of its
  # refusal: every refusal read as "inconclusive" and nothing rotated. Said once.
  if [ "$grc" = 2 ]; then
    gem_streak=$(( gem_streak + 1 ))
    if [ "$gem_streak" -ge "${GEMINI_STALE_CHECKS:-18}" ] && [ "$gem_stale_seen" = 0 ]; then
      gem_stale_seen=1
      log "gemini check has settled nothing for $gem_streak checks in a row — refusals are not being detected"
      notify "the Gemini check has settled nothing for $gem_streak checks in a row (last: $gem). Refusals are not being detected: Google may have changed its answer, or Gemini fails for this host. Compare: vps-psiphon gemini --direct"
    fi
  else
    [ "$gem_stale_seen" = 1 ] && log "gemini check settles again: $gem"
    gem_streak=0; gem_stale_seen=0
  fi
  # A build asked for and missing (a re-run could not fetch one) is said once.
  # A build without a curl_chromeN wrapper watches nothing either: the check then goes by
  # plain curl, exactly as with no build.
  if [ "${IMPERSONATE:-0}" = 1 ] && { [ ! -x /opt/vps-psiphon/curl-impersonate/curl-impersonate ] ||
       [ -z "$(find /opt/vps-psiphon/curl-impersonate -maxdepth 1 -regex '.*/curl_chrome[0-9]+' -print -quit 2>/dev/null)" ]; }; then
    [ "$imp_missing_seen" = 0 ] \
      && notify "IMPERSONATE=1, but no curl-impersonate build is installed: the browser captcha is not watched. Re-run the installer to fetch one."
    imp_missing_seen=1
  else
    imp_missing_seen=0
  fi
fi

# A restart during the check — the installer, `rotate`, `region`, a crash — leaves
# readings that belong to neither tunnel, and judging them would rotate the fresh one
# for nothing (or a decisive failure would). The readings are not counted; the state is
# still saved — the once-only alerts already sent must stay sent — under the tunnel the
# check began on, so the next check finds a new one and starts it clean.
if [ "$this_tunnel" != "$(docker inspect -f '{{.State.StartedAt}}' "${NAME:-vps-psiphon}" 2>/dev/null)" ]; then
  log "check not judged: the tunnel restarted during it${reason:+ (it read: $reason)}"
  save_state
  exit 0
fi

# Failures are counted over a window of recent checks. Consecutive ones are the wrong
# unit: the tunnel that most needs rotating is degraded rather than dead, and it passes
# every other check — which reset the counter and put rotation out of reach.
if [ -z "$reason" ]; then
  # Recovery is the first pass after a failed check, said once — not every pass while
  # an older failure still sits in the window.
  [ "${window: -1}" = 1 ] && log "recovered (exit $(curl -s --max-time 15 "${S[@]}" https://api.ipify.org 2>/dev/null), country ${gl:-?})"
  window="${window}0"
  # A passing check ends a run of rotations that did not help.
  if [ "$futile" -gt 0 ]; then
    [ "$backoff_seen" = 1 ] && log "a check passes again after $futile rotations: the back-off is over"
    futile=0; backoff_seen=0
  fi
else
  window="${window}1"
fi
# Trimmed only when already longer than the window: in bash a negative offset larger
# than the string yields the EMPTY string, not the whole of it — which would silently
# forget every failure until the window had filled.
[ "${#window}" -gt "${FAIL_WINDOW:-5}" ] && window="${window: -${FAIL_WINDOW:-5}}"
ones="${window//0/}"; fails="${#ones}"
[ -n "$reason" ] && log "check failed ($reason), $fails of the last ${#window} checks"
[ -n "$reason" ] && last_reason="$reason"
# Always record the rate: this is the history that makes a slow decline legible.
[ -n "$kbps" ] && log "throughput ${kbps} KB/s (country ${gl:-?})"

# The cooldown between rotations, backed off while rotations keep not helping: after
# three in a row with no passing check between them, it doubles with each further one,
# up to ROTATE_COOLDOWN_MAX. A fault that follows the host instead of the exit — Google
# refusing the whole pool, an upstream outage, a check gone stale — would otherwise drop
# every live connection on every cooldown, forever.
cool="${ROTATE_COOLDOWN:-1800}"; cap="${ROTATE_COOLDOWN_MAX:-7200}"
if [[ "$cool" =~ ^[0-9]{1,7}$ ]]; then cool=$((10#$cool)); else cool=1800; fi
if [[ "$cap" =~ ^[0-9]{1,7}$ ]]; then cap=$((10#$cap)); else cap=7200; fi
[ "$cap" -lt "$cool" ] && cap="$cool"
cooldown_after() {
  local c="$cool" k="$1"
  while [ "$k" -ge 3 ] && [ "$c" -lt "$cap" ]; do c=$(( c * 2 )); k=$(( k - 1 )); done
  [ "$c" -gt "$cap" ] && c="$cap"
  printf '%s' "$c"
}
wait_s="$(cooldown_after "$futile")"

# A decisive failure (Gemini's refusal, the browser captcha) does not wait for the
# window; everything else needs FAIL_THRESHOLD of the last FAIL_WINDOW checks.
due=0
{ [ "$fails" -ge "${FAIL_THRESHOLD:-2}" ] || [ "$decisive" = 1 ]; } && due=1
now=$(date +%s)
if [ "$due" = 1 ] && [ $((now - last_rotate)) -ge "$wait_s" ]; then
  old="$(curl -s --max-time 15 "${S[@]}" https://api.ipify.org 2>/dev/null || echo '?')"
  log "rotating away from exit $old"
  moved="$(/usr/local/sbin/vps-psiphon-advance-region 2>/dev/null)"
  [ -n "$moved" ] && log "region $moved"
  # On an empty config directory, or the client draws the same server again (see
  # fresh_start in the installer).
  fresh_start 2>>"$LOG"
  sleep 45
  new="$(curl -s --max-time 20 "${S[@]}" https://api.ipify.org 2>/dev/null || echo '?')"
  log "rotated: $old -> $new"
  log_tunnels
  if [ -z "$new" ] || [ "$new" = '?' ]; then
    notify "rotated away from $old (${last_reason:-?}) — and the new tunnel does not answer yet"
  else
    notify "rotated $old -> $new${moved:+, region $moved} (${last_reason:-?})"
  fi
  # A refusal on the new exit is news again, so the once-only alerts start over.
  fails=0; window=""; last_rotate=$now; rotations=$((rotations + 1)); denied_gl=""; refused_seen=""
  futile=$(( futile + 1 ))
  if [ "$futile" -ge 3 ] && [ "$backoff_seen" = 0 ]; then
    backoff_seen=1
    log "$futile rotations in a row without a passing check: backing off, the next waits $(cooldown_after "$futile")s"
    notify "$futile rotations in a row have not brought a passing check (last: ${last_reason:-?}). The fault likely follows this host rather than the exit, so rotations now back off: the next in $(cooldown_after "$futile")s, at most every ${cap}s."
  fi
  # The tunnel just started is the one the next check judges, and it starts clean.
  this_tunnel="$(docker inspect -f '{{.State.StartedAt}}' "${NAME:-vps-psiphon}" 2>/dev/null)"
elif [ "$due" = 1 ]; then
  held="rotation due but held: $(( wait_s - (now - last_rotate) ))s of the ${wait_s}s cooldown left"
  [ "$futile" -ge 3 ] && held="$held (backed off after $futile rotations that did not help)"
  log "$held"
fi

save_state

# node_exporter textfile collector. Written to a temporary file in the same directory
# and renamed, so a scrape never reads half a file.
if [ -n "${METRICS_DIR:-}" ] && [ -d "$METRICS_DIR" ]; then
  mf="$(mktemp "$METRICS_DIR/.vps-psiphon.prom.XXXXXX" 2>/dev/null)" && {
    {
      echo '# HELP vps_psiphon_up 1 if the SOCKS5 liveness probe succeeded on the last check.'
      echo '# TYPE vps_psiphon_up gauge'
      echo "vps_psiphon_up $alive"
      echo '# HELP vps_psiphon_check_ok 1 if the last check found nothing to rotate for.'
      echo '# TYPE vps_psiphon_check_ok gauge'
      echo "vps_psiphon_check_ok $([ -z "$reason" ] && echo 1 || echo 0)"
      if [ -n "$kbps" ]; then
        echo '# HELP vps_psiphon_throughput_kbps Rate of the watchdog YouTube fetch, KB/s.'
        echo '# TYPE vps_psiphon_throughput_kbps gauge'
        echo "vps_psiphon_throughput_kbps $kbps"
      fi
      echo '# HELP vps_psiphon_window_failures Failed checks within the failure window.'
      echo '# TYPE vps_psiphon_window_failures gauge'
      echo "vps_psiphon_window_failures $fails"
      echo '# HELP vps_psiphon_rotations_total Rotations made by the watchdog.'
      echo '# TYPE vps_psiphon_rotations_total counter'
      echo "vps_psiphon_rotations_total $rotations"
      echo '# HELP vps_psiphon_last_rotate_timestamp_seconds Time of the last watchdog rotation.'
      echo '# TYPE vps_psiphon_last_rotate_timestamp_seconds gauge'
      echo "vps_psiphon_last_rotate_timestamp_seconds $last_rotate"
      echo '# HELP vps_psiphon_captcha 1 if Google serves a captcha to this exit.'
      echo '# TYPE vps_psiphon_captcha gauge'
      echo "vps_psiphon_captcha $captcha"
      echo '# HELP vps_psiphon_target_refused 1 if a PROBE_URLS target refused this exit (403/451) on the last check.'
      echo '# TYPE vps_psiphon_target_refused gauge'
      echo "vps_psiphon_target_refused $([ -n "$refused" ] && echo 1 || echo 0)"
      if [ -n "$grc" ]; then
        echo '# HELP vps_psiphon_gemini_result Last Gemini check: 0 ok, 1 refused (1060), 2 inconclusive, 3 browser captcha.'
        echo '# TYPE vps_psiphon_gemini_result gauge'
        echo "vps_psiphon_gemini_result $grc"
      fi
      echo '# HELP vps_psiphon_gemini_inconclusive_streak Gemini checks in a row that settled nothing.'
      echo '# TYPE vps_psiphon_gemini_inconclusive_streak gauge'
      echo "vps_psiphon_gemini_inconclusive_streak $gem_streak"
      echo '# HELP vps_psiphon_rotation_cooldown_seconds Cooldown the next rotation waits, back-off included.'
      echo '# TYPE vps_psiphon_rotation_cooldown_seconds gauge'
      echo "vps_psiphon_rotation_cooldown_seconds $(cooldown_after "$futile")"
      echo '# HELP vps_psiphon_inproxy_excluded 1 if the last start kept in-proxy out (tactics off).'
      echo '# TYPE vps_psiphon_inproxy_excluded gauge'
      echo "vps_psiphon_inproxy_excluded $([ "$run_mode" = no-inproxy ] && echo 1 || echo 0)"
      if [ -n "$gl" ]; then
        echo "# HELP vps_psiphon_country_info Google's country verdict about this exit."
        echo '# TYPE vps_psiphon_country_info gauge'
        echo "vps_psiphon_country_info{gl=\"$gl\"} 1"
      fi
      echo '# HELP vps_psiphon_last_check_timestamp_seconds Time of the last watchdog check.'
      echo '# TYPE vps_psiphon_last_check_timestamp_seconds gauge'
      echo "vps_psiphon_last_check_timestamp_seconds $(date +%s)"
    } > "$mf" && chmod 644 "$mf" && mv -f "$mf" "$METRICS_DIR/vps-psiphon.prom" || rm -f "$mf"
  }
fi
WD
put_shared_funcs /usr/local/sbin/vps-psiphon-watchdog
chmod 755 /usr/local/sbin/vps-psiphon-watchdog
touch /var/log/vps-psiphon-watchdog.log
# The watchdog appends a few lines every ten minutes, forever. copytruncate because it
# opens the file per line and holds nothing to signal.
if [ -d /etc/logrotate.d ]; then
  cat > /etc/logrotate.d/vps-psiphon <<'LR'
/var/log/vps-psiphon-watchdog.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LR
fi

# ---- management CLI ---------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon <<'CLI'
#!/usr/bin/env bash
set -uo pipefail
# Sourced defensively: once the env file is gone — a half-finished uninstall, a
# hand-deleted file — `set -u` would abort on the first unset variable and leave the
# CLI unable to clean up after itself.
[ -r /etc/default/vps-psiphon ] && . /etc/default/vps-psiphon
# Filled in by the installer with the image it deployed, so an uninstall that has
# lost the env file still removes that image and not an unrelated :latest.
IMAGE="${IMAGE:-@@IMAGE@@}"
NAME="${NAME:-vps-psiphon}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"
PUBLISH_HTTP="${PUBLISH_HTTP:-1}"
CONF_DIR="${CONF_DIR:-/opt/vps-psiphon/config}"
# Env files written before --bind existed carry no BIND line at all.
BIND="${BIND:-127.0.0.1}"
S=(--socks5-hostname "${BIND}:${SOCKS_PORT}")

# Same rule the watchdog applies, so status never disagrees with the thing that
# actually rotates.
accepted_regions() {
  acc="${ACCEPT_REGIONS:-}"
  if [ -z "$acc" ]; then
    if [ -n "${REGION_POOL:-}${EGRESS_REGION:-}" ]; then
      for r in ${REGION_POOL:-} ${EGRESS_REGION:-} US; do
        case " $acc " in *" $r "*) ;; *) acc="${acc:+$acc }$r" ;; esac
      done
    else
      acc="${OK_REGIONS:-}"
    fi
  fi
  printf '%s' "$acc"
}

# cc_list and the img_* helpers: the installer's own definitions, put here at
# install time (see SHARED_FUNCS in psiphon_install.sh) — one copy, not two.
@@SHARED_FUNCS@@

# Removes a pinned image: its digest, and its tag while that tag still names this very
# image. update-image pulls by tag, which leaves the tag on the build, so removing the
# digest alone would only untag it and keep it on disk; a tag that has since moved to
# another build belongs to that build and is left alone. Docker refuses either while
# something still uses the image, which is fine.
rm_image() {
  local c t cid
  c="$(img_canon "$1")"; t="$(img_repo "$1"):$(img_tag "$1")"
  cid="$(docker image inspect -f '{{.Id}}' "$c" 2>/dev/null)" || return 1
  [ -n "$cid" ] || return 1
  if [ "$(docker image inspect -f '{{.Id}}' "$t" 2>/dev/null)" = "$cid" ]; then
    docker image rm "$t" >/dev/null 2>&1
  fi
  docker image rm "$c" >/dev/null 2>&1
}

# The lock shared with the watchdog and the installer. Commands that restart the tunnel
# or rewrite the env file wait for whichever holds it — a check can take a few minutes
# when it rotates, a reinstall longer — and a watchdog check that starts meanwhile
# skips itself.
take_lock() {
  exec 9>/run/vps-psiphon.lock
  flock -w 600 9 || { echo "another vps-psiphon operation (installer, watchdog check or command) has held the lock for 10 minutes — try again" >&2; exit 1; }
}

# Same sender as the watchdog's: direct, token kept out of argv.
notify() {
  [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 1
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_TOKEN" \
    | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - \
        --data-urlencode "chat_id=${TG_CHAT}" \
        ${TG_THREAD:+--data-urlencode "message_thread_id=${TG_THREAD}"} \
        --data-urlencode "text=vps-psiphon @ $(hostname): $*" 2>/dev/null
}

status() {
  local v
  v="$(docker ps --filter "name=^${NAME}$" --format '{{.Status}}' 2>/dev/null)"
  echo "container : ${v:-DOWN}"
  echo "service   : $(systemctl is-active vps-psiphon.service) / $(systemctl is-enabled vps-psiphon.service 2>/dev/null)"
  echo "watchdog  : $(systemctl is-active vps-psiphon-watchdog.timer) / $(systemctl is-enabled vps-psiphon-watchdog.timer 2>/dev/null)"
  echo "socks     : ${BIND}:${SOCKS_PORT}   (region requested: ${EGRESS_REGION:-auto})"
  [ -n "${REGION_POOL:-}" ] && echo "pool      : ${REGION_POOL}   (each rotation advances one step)"
  [ -n "${DENY_REGIONS:-}" ] && echo "deny      : ${DENY_REGIONS}   (rejected in every mode, checked first)"
  acc="$(accepted_regions)"
  [ -n "$acc" ] && echo "accept    : ${acc}   (verdicts tolerated — the pool is only what we ask for)"
  if [ "$PUBLISH_HTTP" = 1 ]; then
    echo "http      : ${BIND}:${HTTP_PORT}   (unused by xray; handy for curl -x)"
  else
    echo "http      : not published"
  fi
  # A pipeline's fallback never fires here — tail succeeds on empty input, and
  # grep -c prints its own 0 before failing — so the defaults are applied to the value.
  v="$(docker logs "$NAME" 2>&1 | grep -o '"serverRegion":"[A-Z]*"' | tail -1)"
  echo "server    : ${v:-?}"
  v="$(docker logs "$NAME" 2>&1 | grep -c '"noticeType":"Tunnels"')"
  echo "tunnels   : ${v:-0}"
  v="$(docker logs "$NAME" 2>&1 | grep -o '"downstreamBytesPerSecond":[0-9]*' | tail -1)"
  echo "limits    : ${v:-n/a}"
  echo -n "exit IP   : "; curl -s --max-time 20 "${S[@]}" https://api.ipify.org 2>/dev/null || echo 'UNREACHABLE'; echo
  local gl; gl="$(curl -s --max-time 25 "${S[@]}" -H 'Accept-Language: en-US' https://www.youtube.com/ 2>/dev/null \
                  | grep -oE '"GL":"[A-Z]{2}"' | head -1 | cut -d'"' -f4)"
  # Deny first and in every mode, exactly as the watchdog does — with no pinned
  # region and no OK_REGIONS it is the only check that would catch an RU exit.
  denied=0; ok=1
  if [ -n "$gl" ]; then
    case " ${DENY_REGIONS:-} " in *" $gl "*) denied=1 ;; esac
  fi
  if [ "$denied" = 0 ] && [ -n "$gl" ] && [ -n "$acc" ] && [ "$acc" != any ]; then
    case " $acc " in *" $gl "*) ;; *) ok=0 ;; esac
  fi
  if [ "$denied" = 1 ]; then
    echo "country   : ${gl} — DENIED (sanctioned or Google-blocked); the watchdog will rotate"
  elif [ "$ok" = 0 ]; then
    echo "country   : ${gl} — NOT ACCEPTED (accepted: ${acc}); the watchdog will rotate"
  elif [ -n "${EGRESS_REGION:-}" ] && [ -n "$gl" ] && [ "$gl" != "$EGRESS_REGION" ]; then
    echo "country   : ${gl}   (asked ${EGRESS_REGION} — accepted; Google rewrites exits, and that alone is not a fault)"
  else
    echo "country   : ${gl:-?}   (Google's own verdict about this exit)"
  fi
  local rd; rd="$(curl -s -o /dev/null --max-time 25 "${S[@]}" -w '%{redirect_url}' 'https://www.google.com/search?q=status' 2>/dev/null)"
  case "$rd" in */sorry/*) echo "captcha   : yes (informational — no rotation, a human solves it)" ;;
                        *) echo "captcha   : no" ;; esac
  # Fetched exactly as the watchdog fetches them, and judged by the same rule.
  local -a probe_urls; local u h pc
  read -r -a probe_urls <<< "${PROBE_URLS:-}"
  for u in "${probe_urls[@]}"; do
    h="${u#*://}"; h="${h%%/*}"
    pc="$(curl -s -o /dev/null --max-time 20 --max-filesize 65536 "${S[@]}" \
          -H 'Accept-Language: en-US' -w '%{http_code}' "$u" 2>/dev/null)"
    case "$pc" in
      403|451) echo "target    : $h $pc — REFUSED through this exit; the watchdog will rotate" ;;
      [23][0-9][0-9]) echo "target    : $h $pc ok" ;;
      *) echo "target    : $h ${pc:-000}   (not judged — only 403/451 rotate)" ;;
    esac
  done
  # The watchdog's last reading, not a fresh one: asking Gemini takes up to two minutes.
  # `vps-psiphon gemini` asks now.
  if [ "${GEMINI_CHECK:-1}" = 1 ]; then
    v="$(grep ' gemini: ' /var/log/vps-psiphon-watchdog.log 2>/dev/null | tail -1)"
    if [ -n "$v" ]; then echo "gemini    : ${v#* gemini: }   (watchdog, ${v%% *})"
    else echo "gemini    : not asked yet — the watchdog asks at every check; now: vps-psiphon gemini"; fi
  else
    echo "gemini    : not asked (--no-gemini-check)"
  fi
  if [ "${IMPERSONATE:-0}" = 1 ]; then
    if [ -x /opt/vps-psiphon/curl-impersonate/curl-impersonate ]; then
      echo "browsers  : captcha watched — Gemini's page is fetched as Chrome (curl-impersonate $(cat /opt/vps-psiphon/curl-impersonate/VERSION 2>/dev/null || echo '?'))"
    else
      echo "browsers  : captcha NOT watched — IMPERSONATE=1 but curl-impersonate is missing; re-run the installer"
    fi
  fi
  # What the launcher made of the last start; "unedited" is the one to act on.
  v="$(awk '{print $2}' /var/lib/vps-psiphon-run.state 2>/dev/null)"
  case "$v" in
    no-inproxy)      echo "protocols : in-proxy excluded (tactics off)" ;;
    pending)         echo "protocols : in-proxy NOT excluded on this tunnel — the launcher could not seed psiphon.config from the image (journalctl -u vps-psiphon); every fresh start repeats it" ;;
    unedited)        echo "protocols : in-proxy NOT excluded — psiphon.config is not in the shape the launcher edits (journalctl -u vps-psiphon)" ;;
    overridden)      echo "protocols : in-proxy NOT excluded — psiphon.config sets \"DisableTactics\": false by hand" ;;
    psiphon-default) echo "protocols : Psiphon's own choice (--inproxy)" ;;
  esac
  v="$(grep ' tunnel up: ' /var/log/vps-psiphon-watchdog.log 2>/dev/null | tail -1)"
  [ -n "$v" ] && echo "last tunnel: ${v#* tunnel up: }"
  echo -n "traffic   : "; docker exec "$NAME" cat /proc/net/dev 2>/dev/null | awk '/eth0/{printf "rx %.2f GB / tx %.2f GB\n", $2/1e9, $10/1e9}' || echo 'n/a'
}

case "${1:-status}" in
  status) status ;;
  rotate)
    take_lock
    echo "rotating (fresh tunnel, new exit)…"
    moved="$(/usr/local/sbin/vps-psiphon-advance-region 2>/dev/null)"
    [ -n "$moved" ] && echo "region    : $moved"
    fresh_start; sleep 45
    # advance-region rewrote the env file; without re-reading it, status would judge
    # the new exit against the region we just left.
    [ -r /etc/default/vps-psiphon ] && . /etc/default/vps-psiphon
    status ;;
  pool)
    # An empty string is valid here — it clears the pool — so this tests for a
    # MISSING argument, not an empty one.
    [ $# -ge 2 ] || { echo "usage: vps-psiphon pool '<CC CC …>'   (empty string clears it)"; exit 1; }
    np="$(cc_list "$2")" || { echo "pool: '$2' is not a list of two-letter country codes" >&2; exit 1; }
    take_lock
    grep -q '^REGION_POOL=' /etc/default/vps-psiphon \
      || { echo "pool: no REGION_POOL line in /etc/default/vps-psiphon — re-run the installer" >&2; exit 1; }
    sed -i "s/^REGION_POOL=.*/REGION_POOL='$np'/" /etc/default/vps-psiphon
    REGION_POOL="$np"
    if [ -n "$np" ]; then
      echo "pool      : $np"
      case " $np " in
        *" ${EGRESS_REGION:-} "*) : ;;
        *) echo "note      : current region ${EGRESS_REGION:-auto} is outside the pool;"
           echo "            the next rotation moves to ${np%% *}" ;;
      esac
    else
      echo "pool cleared — rotations stay in ${EGRESS_REGION:-auto}"
    fi ;;
  accept)
    # An empty string is valid here too — it restores the computed default.
    [ $# -ge 2 ] || { echo "usage: vps-psiphon accept '<CC CC …>|any'   (empty string restores the default)"; exit 1; }
    case "$2" in
      [Aa][Nn][Yy]) na=any ;;
      *) na="$(cc_list "$2")" \
           || { echo "accept: '$2' is neither 'any' nor a list of two-letter country codes" >&2; exit 1; } ;;
    esac
    take_lock
    grep -q '^ACCEPT_REGIONS=' /etc/default/vps-psiphon \
      || { echo "accept: no ACCEPT_REGIONS line in /etc/default/vps-psiphon — re-run the installer" >&2; exit 1; }
    sed -i "s/^ACCEPT_REGIONS=.*/ACCEPT_REGIONS='$na'/" /etc/default/vps-psiphon
    ACCEPT_REGIONS="$na"
    if [ -n "$na" ]; then
      echo "accept    : $na"
      for d in ${DENY_REGIONS:-}; do
        case " $na " in *" $d "*) echo "note      : $d is also denied — denied wins, it is checked first" ;; esac
      done
    else
      echo "accept    : $(accepted_regions)   (back to the default: everything requested, plus US)"
    fi ;;
  region)
    [ -n "${2:-}" ] || { echo "usage: vps-psiphon region <CC|auto>"; exit 1; }
    case "$2" in
      [Aa][Uu][Tt][Oo]) r="" ;;
      *) r="$(cc_list "$2")" && [ -n "$r" ] && [ "$r" = "${r%% *}" ] \
           || { echo "region: '$2' is neither 'auto' nor one two-letter country code" >&2; exit 1; } ;;
    esac
    take_lock
    sed -i "s/^EGRESS_REGION=.*/EGRESS_REGION=$r/" /etc/default/vps-psiphon
    EGRESS_REGION="$r"   # the file was sourced at startup; keep status() honest
    # A new country is a new draw of servers, as every rotation is.
    fresh_start; sleep 45; status ;;
  speed)
    U="https://speed.cloudflare.com/__down?bytes=50000000"
    echo -n "single 50MB : "
    curl -s -o /dev/null --max-time 300 "${S[@]}" -w '%{speed_download}\n' "$U" | awk '{printf "%.1f Mbit/s\n", $1*8/1e6}'
    echo -n "4x parallel : "
    # mktemp, not a fixed name: this runs as root, and a predictable path in /tmp is
    # one anybody on the host can pre-plant as a symlink.
    tf="$(mktemp)"; t0=$(date +%s.%N)
    for _ in 1 2 3 4; do curl -s -o /dev/null --max-time 300 "${S[@]}" -w '%{size_download}\n' "$U" >> "$tf" & done
    wait; t1=$(date +%s.%N)
    awk -v a="$t0" -v b="$t1" '{s+=$1} END{printf "%.1f Mbit/s aggregate\n", s*8/(b-a)/1e6}' "$tf"
    rm -f "$tf" ;;
  logs)     docker logs --tail "${2:-50}" "$NAME" ;;
  gemini)
    # The watchdog's own check, asked now. --direct asks from this host's address, to
    # tell a burned exit from a refusal that follows the whole host.
    case "${2:-}" in ''|--direct) ;; *) echo "usage: vps-psiphon gemini [--direct]" >&2; exit 1 ;; esac
    /usr/local/sbin/vps-psiphon-gemini-check ${2:+"$2"} ;;
  notify-test)
    if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT:-}" ]; then
      echo "Telegram alerts are off: set them with the installer's --tg-token and --tg-chat" >&2
      exit 1
    fi
    code="$(notify "test message — alerts from this node reach this chat")"
    if [ "$code" = 200 ]; then echo "sent"
    else echo "not sent (HTTP ${code:-no answer}) — check the token, the chat id, and that the bot is in the chat" >&2; exit 1
    fi ;;
  update-image)
    # The image is pinned by digest, which is what keeps it from changing under you —
    # and also what keeps it from ever picking up a fix. This moves the pin on, in the
    # open: it pulls the followed tag, shows old and new digest, and only then switches.
    check=0; ref=""
    for a in "${@:2}"; do
      case "$a" in --check) check=1 ;; -*) echo "update-image: unknown option $a" >&2; exit 1 ;; *) ref="$a" ;; esac
    done
    # No reference: the tag recorded in IMAGE. A reference that names a tag makes that
    # tag the one followed from now on; one without (a bare repo or a digest) keeps the
    # current tag when it is the same repository, :latest otherwise.
    [ -n "$ref" ] || ref="$(img_repo "$IMAGE"):$(img_tag "$IMAGE")"
    printf '%s\n' "$ref" | grep -qxE '[A-Za-z0-9._/:@-]+' || { echo "update-image: '$ref' is not an image reference" >&2; exit 1; }
    repo="$(img_repo "$ref")"
    if img_tagged "$ref"; then tag="$(img_tag "$ref")"
    elif [ "$repo" = "$(img_repo "$IMAGE")" ]; then tag="$(img_tag "$IMAGE")"
    else tag=latest; fi
    [ "$check" = 1 ] || take_lock
    # Read before the pull: when IMAGE is an unpinned tag, the pull moves it, and the
    # "current" digest read afterwards would already be the new one.
    cur="$(img_digest "$IMAGE")"
    if [ -z "$cur" ]; then
      cur="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" 2>/dev/null | head -1)"
      cur="${cur#*@}"
    fi
    # What is pulled is what gets recorded: a pinned digest as such, otherwise the tag
    # the new pin will follow — never a bare repo, which docker reads as :latest.
    if [ -n "$(img_digest "$ref")" ]; then pull="$(img_canon "$ref")"; else pull="$repo:$tag"; fi
    echo "pulling   : $pull"
    docker pull -q "$pull" >/dev/null || { echo "update-image: pull failed" >&2; exit 1; }
    d="$(img_digest "$ref")"
    if [ -z "$d" ]; then
      d="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$pull" 2>/dev/null \
           | grep -F "$repo@" | head -1)"
      d="${d#*@}"
    fi
    [ -n "$d" ] || { echo "update-image: $ref has no registry digest" >&2; exit 1; }
    new="$repo:$tag@$d"
    echo "current   : $IMAGE"
    if [ "$d" = "$cur" ]; then
      # Same build; only the followed tag may have changed, which needs no restart.
      if [ "$check" = 0 ] && [ "$new" != "$IMAGE" ]; then
        sed -i "s|^IMAGE=.*|IMAGE=$new|" /etc/default/vps-psiphon
        [ "$(img_repo "$IMAGE"):$(img_tag "$IMAGE")" = "$repo:$tag" ] \
          || echo "following : $repo:$tag from now on"
      fi
      echo "up to date: $new"; exit 0
    fi
    echo "available : $new"
    [ "$check" = 1 ] && exit 0
    old="$IMAGE"
    sed -i "s|^IMAGE=.*|IMAGE=$new|" /etc/default/vps-psiphon
    IMAGE="$new"
    [ "$(img_repo "$old"):$(img_tag "$old")" = "$repo:$tag" ] || echo "following : $repo:$tag from now on"
    echo "switching — the tunnel restarts, live connections drop"
    systemctl restart vps-psiphon.service; sleep 45
    # The old image is the rollback: it is removed only once the new build has carried
    # a request. Otherwise the pin goes back and the old build runs again, so a broken
    # release costs one restart instead of a dead tunnel and a re-pull by digest.
    ok=0
    for _ in 1 2 3; do
      [ "$(curl -s -o /dev/null --max-time 20 "${S[@]}" -w '%{http_code}' \
            https://www.gstatic.com/generate_204 2>/dev/null)" = 204 ] && { ok=1; break; }
      sleep 15
    done
    if [ "$ok" = 0 ]; then
      echo "update-image: the new build carries no traffic — rolling back to $old" >&2
      sed -i "s|^IMAGE=.*|IMAGE=$old|" /etc/default/vps-psiphon
      IMAGE="$old"
      systemctl restart vps-psiphon.service; sleep 45
      status; exit 1
    fi
    # Only a pinned reference is removed: an unpinned tag may by now name the image
    # just switched to.
    [ -n "$(img_digest "$old")" ] && rm_image "$old" && echo "removed   : $(img_canon "$old")"
    status ;;
  routing)
    cat <<R
Paste into the panel's config profile (Remnawave: Config Profiles -> your profile).

OUTBOUND — alongside the existing DIRECT / BLOCK:

    { "tag": "psiphon-out", "protocol": "socks",
      "settings": { "address": "$BIND", "port": $SOCKS_PORT } }

RULES — order matters, first match wins:

    { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" },
    { "type": "field", "network": "udp", "port": "53", "outboundTag": "DIRECT" },
    { "type": "field", "network": "udp", "outboundTag": "BLOCK" },
    { "type": "field", "network": "tcp", "outboundTag": "psiphon-out" }

The two UDP lines are not optional. This SOCKS is TCP-only — psiphon answers UDP
ASSOCIATE with REP=7 COMMAND NOT SUPPORTED. Send UDP at it and DNS dies with
everything else; leave UDP DIRECT and QUIC/HTTP3 keeps succeeding outside the
tunnel, so half the traffic ignores it. Blocking UDP makes clients fall back to
TCP, which is the path that works. DNS is the one exception and goes DIRECT.

To tunnel only some destinations, keep the first two rules and replace the last
two with a pair scoped to the same list — the UDP block included, or QUIC to those
names keeps leaving outside the tunnel — and leave the rest direct:

    { "type": "field", "network": "udp", "outboundTag": "BLOCK",
      "domain": ["geosite:google-gemini"] },
    { "type": "field", "network": "tcp", "outboundTag": "psiphon-out",
      "domain": ["geosite:google-gemini"] }

Prefer the geosite category to a hand-written list of names. A service is more
hosts than its front page: Gemini's chat goes to geminiweb-pa.clients6.google.com,
the Android app to robinfrontend-pa / proactivebackend-pa / geller-pa
.googleapis.com, and a list naming gemini.google.com alone tunnels the page while
the conversation leaves directly from the node — two addresses for one session.
Domain rules need sniffing on the inbound (destOverride http, tls, quic).

Whatever you tunnel, list its front page in PROBE_URLS (--probe-urls) so the
watchdog notices when that service, rather than the tunnel, refuses the exit.

Nothing here is applied for you: the panel owns the node's xray config, and a
config written on the node is overwritten on the next sync.
R
    ;;
  verify)
    rc=0
    # Every listener on the port is judged, not the first one ss happens to print: a
    # second one on a wildcard is exactly the case this command exists to catch. The
    # HTTP proxy is checked too — unauthenticated, it is as open a proxy as the SOCKS.
    check_port() {
      local port="$1" what="$2" required="$3" l a found=0
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        found=1
        echo "listener  : $l   ($what)"
        a="${l%:*}"; a="${a#[}"; a="${a%]}"; a="${a%%%*}"
        case "$a" in
          0.0.0.0|'*'|::|'')
            echo "  !! WILDCARD BIND — this is an OPEN ${what} PROXY, reachable from the"
            echo "     internet by anyone who scans port ${port}. Re-run the installer"
            echo "     with --bind-loopback, or fix BIND in /etc/default/vps-psiphon."
            rc=1 ;;
          127.*|::1)
            echo "            ok — loopback, reachable only from this host" ;;
          10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|f[cd]*|fe[89ab]*)
            echo "            ok — private address, not routable from the internet;"
            echo "            anything on that network (containers on the bridge) reaches it" ;;
          *)
            echo "  !! PUBLIC ADDRESS $a — reachable from the internet unless a firewall"
            echo "     stops it. If that is intended, the access control is yours; otherwise"
            echo "     re-run the installer without --bind."
            rc=1 ;;
        esac
      done <<EOF
$(ss -tlnH 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p {print $4}')
EOF
      if [ "$found" = 0 ]; then
        if [ "$required" = 1 ]; then
          echo "listener  : MISSING — nothing listens on ${port} ($what)"; rc=1
        else
          echo "listener  : nothing listens on ${port} ($what)"
        fi
      fi
    }
    echo "configured: ${BIND}:${SOCKS_PORT}"
    check_port "$SOCKS_PORT" SOCKS5 1
    [ "$PUBLISH_HTTP" = 1 ] && check_port "$HTTP_PORT" HTTP 0
    ip="$(curl -s --max-time 20 "${S[@]}" https://api.ipify.org 2>/dev/null || true)"
    if [ -n "$ip" ]; then echo "socks     : works, exit $ip"; else echo "socks     : NOT WORKING"; rc=1; fi
    echo
    echo "Now confirm it from ANOTHER machine — this one cannot answer the question:"
    echo
    echo "    curl --max-time 20 --socks5-hostname <this-host>:${SOCKS_PORT} https://api.ipify.org"
    echo
    echo "It must fail. Do not judge this with 'nc -z' or any TCP-connect probe:"
    echo "some providers tarpit every port and complete the TCP handshake for ports"
    echo "nothing listens on, so nc reports 'open' for a port that is closed — and"
    echo "would report the same for a port that is genuinely exposed. Only a real"
    echo "SOCKS handshake tells the two apart."
    exit $rc ;;
  watchdog) tail -n "${2:-30}" /var/log/vps-psiphon-watchdog.log ;;
  uninstall)
    # Held to the end so a running check or rotation finishes first, instead of
    # restarting a unit this is removing. The lock file itself stays: unlinking it
    # would let the next command lock a fresh file while an old holder still runs.
    # It lives in /run and is gone at the next boot.
    take_lock
    systemctl disable --now vps-psiphon-watchdog.timer vps-psiphon-watchdog.service \
                            vps-psiphon.service >/dev/null 2>&1
    docker rm -f "$NAME" >/dev/null 2>&1
    rm -f /etc/systemd/system/vps-psiphon.service \
          /etc/systemd/system/vps-psiphon-watchdog.service \
          /etc/systemd/system/vps-psiphon-watchdog.timer
    systemctl daemon-reload
    systemctl reset-failed vps-psiphon.service vps-psiphon-watchdog.service >/dev/null 2>&1
    # Ours to drop: the installer pulled it and a reinstall pulls it again. Docker
    # refuses while anything else references it, which is fine.
    rm_image "$IMAGE"
    rm -f /usr/local/sbin/vps-psiphon-run /usr/local/sbin/vps-psiphon-watchdog \
          /usr/local/sbin/vps-psiphon-advance-region /usr/local/sbin/vps-psiphon-gemini-check \
          /var/lib/vps-psiphon-watchdog.seen /var/lib/vps-psiphon-run.state \
          /etc/default/vps-psiphon /var/lib/vps-psiphon-watchdog.state \
          /var/log/vps-psiphon-watchdog.log /tmp/vpspsi.speed \
          /etc/logrotate.d/vps-psiphon
    [ -n "${METRICS_DIR:-}" ] && rm -f "$METRICS_DIR/vps-psiphon.prom"
    rm -rf /opt/vps-psiphon
    # Safe to unlink while running: bash holds the inode open, so the rest of this
    # branch keeps executing after the name is gone.
    rm -f /usr/local/sbin/vps-psiphon
    # Claiming "removed" is worth nothing unmeasured — look at the disk and say so.
    left=""
    for p in /usr/local/sbin/vps-psiphon /usr/local/sbin/vps-psiphon-run \
             /usr/local/sbin/vps-psiphon-watchdog \
             /usr/local/sbin/vps-psiphon-advance-region /usr/local/sbin/vps-psiphon-gemini-check \
             /var/lib/vps-psiphon-watchdog.seen /var/lib/vps-psiphon-run.state /etc/default/vps-psiphon \
             /etc/systemd/system/vps-psiphon.service \
             /etc/systemd/system/vps-psiphon-watchdog.service \
             /etc/systemd/system/vps-psiphon-watchdog.timer \
             /var/lib/vps-psiphon-watchdog.state \
             /var/log/vps-psiphon-watchdog.log /etc/logrotate.d/vps-psiphon \
             /opt/vps-psiphon ${METRICS_DIR:+"$METRICS_DIR/vps-psiphon.prom"} ; do
      [ -e "$p" ] && left="$left $p"
    done
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME" && left="$left container:$NAME"
    docker image inspect "$(img_canon "$IMAGE")" >/dev/null 2>&1 \
      && echo "note: image $(img_canon "$IMAGE") kept, something else on this host references it"
    [ -n "$left" ] && { echo "removed, but these remain:$left" >&2; exit 1; }
    echo "removed: units, container, image, config, state, log — and this CLI itself" ;;
  *) echo "usage: vps-psiphon {status|verify|routing|rotate|region <CC|auto>|pool '<CC CC …>'|accept '<CC CC …>|any'|update-image [--check] [REF]|gemini [--direct]|notify-test|speed|logs [n]|watchdog [n]|uninstall}" ;;
esac
CLI
# IMAGE is validated to [A-Za-z0-9._/:@-], so it cannot break out of the | delimiter.
sed -i "s|@@IMAGE@@|$IMAGE|" /usr/local/sbin/vps-psiphon
put_shared_funcs /usr/local/sbin/vps-psiphon
chmod 755 /usr/local/sbin/vps-psiphon

# ---- units ------------------------------------------------------------------
# Unquoted: the container name is baked in, so a NAME other than the default is
# still the one ExecStop stops.
cat > /etc/systemd/system/vps-psiphon.service <<U1
[Unit]
Description=vps-psiphon egress tunnel (host-private SOCKS5 for xray)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
ExecStart=/usr/local/sbin/vps-psiphon-run
ExecStop=/usr/bin/docker stop -t 10 $NAME
Restart=always
RestartSec=10
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
U1

cat > /etc/systemd/system/vps-psiphon-watchdog.service <<'U2'
[Unit]
Description=vps-psiphon liveness and burned-exit watchdog
After=vps-psiphon.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-psiphon-watchdog
# A check is a few minutes at worst — the Gemini check alone may take 200 s, a rotation
# another 80. A oneshot that hangs is never started again by its timer, so it is cut
# off rather than left to end the watchdog quietly.
TimeoutStartSec=15min
U2

cat > /etc/systemd/system/vps-psiphon-watchdog.timer <<'U3'
[Unit]
Description=Run the vps-psiphon watchdog every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
AccuracySec=30s

[Install]
WantedBy=timers.target
U3

systemctl daemon-reload
systemctl enable vps-psiphon.service >/dev/null 2>&1
# restart, not "enable --now": on a reinstall the service is already active and
# would keep running with the previous parameters.
if [ "$REGION_CHANGED" = 1 ]; then
  fresh_start || true   # on a CONF_DIR it would not empty it restarts, and says why
else
  systemctl restart vps-psiphon.service
fi
[ "$WATCHDOG" = 1 ] && systemctl enable --now vps-psiphon-watchdog.timer

# ------------------------------------------------------------------- verify --
say "waiting for the tunnel"
# Watch the unit, not just the log. Restart=always means a container that cannot start
# loops rather than dying quietly, and this loop used to wait out all sixty iterations
# against a container `--rm` had already deleted — no output, no error, then a
# success-shaped exit 0. systemd reports an auto-restarting unit as "activating", so
# anything but "active" here is the failure, caught in ~3 s.
TUNNEL_UP=0
for _ in $(seq 1 60); do
  systemctl is-active --quiet vps-psiphon.service || break
  docker logs "$NAME" 2>&1 | grep -q '"noticeType":"Tunnels"' && { TUNNEL_UP=1; break; }
  sleep 2
done

if [ "$TUNNEL_UP" = 0 ] && ! systemctl is-active --quiet vps-psiphon.service; then
  echo >&2
  printf '\033[1;31mERROR:\033[0m the tunnel never started.\n' >&2
  journalctl -u vps-psiphon.service -n 40 --no-pager 2>/dev/null \
    | grep -iE 'error|failed|cannot|denied' | tail -5 | sed 's/^/    /' >&2
  # Stop it rather than leave docker hammered every 10s while you read this.
  systemctl stop vps-psiphon.service >/dev/null 2>&1 || true
  echo >&2
  echo "    The service is stopped, not looping. Fix the cause and re-run this" >&2
  echo "    installer, or 'vps-psiphon uninstall' to remove what was written." >&2
  exit 1
fi

if [ "$TUNNEL_UP" = 0 ]; then
  say "no tunnel after 120s, but the service is alive — leaving it to keep trying"
  say "watch it with:  vps-psiphon logs"
fi
sleep 3
echo
/usr/local/sbin/vps-psiphon status
echo
say "xray outbound (the routing rules matter too — run: vps-psiphon routing):"
cat <<OUT
    { "tag": "psiphon-out", "protocol": "socks",
      "settings": { "address": "$BIND", "port": $SOCKS_PORT } }
OUT
if [ "${BIND_CHANGED:-0}" = 1 ]; then
  printf '\033[1;33m    !! this run MOVED the address (%s -> %s), so the outbound above is\n' "$OLD_BIND" "$BIND"
  printf '       NOT what your panel has. Update it now, or the tunnel carries nothing.\033[0m\n'
fi
say "manage with:  vps-psiphon {status|verify|routing|rotate|region <CC>|pool '<CC CC …>'|accept '<CC CC …>'|update-image|gemini|notify-test|speed|logs|uninstall}"
