# psiphon-egress

Psiphon as a second exit for an xray / Remnawave node — for destinations that
refuse datacenter addresses.

The tunnel runs as a container, its SOCKS5 is published on a host-private
address, and xray reaches it through a four-line outbound. systemd owns the
lifecycle. A watchdog rotates the exit when it stops being *usable* — which is
not the same question as whether it is still *up*.

> Русская версия: [README.ru.md](README.ru.md)

> Derived from [Chara-Freedom/vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon)
> (MIT). Almost all the code is theirs — see [CREDITS.md](CREDITS.md) for what
> came from where and what we changed.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mtvworks/psiphon-egress/main/psiphon_install.sh) \
  --no-http --bind-loopback --region 'DE,NL,FR,AT,CH,SE'
```

Requirements: root, docker, curl, `ss` (iproute2), `flock` (util-linux).

Every value is checked before anything is written: country codes (any case,
comma- or space-separated), ports, an IPv4 `--bind`, memory and pid limits.
Bad input stops the run instead of landing in a file that root sources.

Those flags are not decoration:

- `--bind-loopback` publishes SOCKS on `127.0.0.1`. Correct when xray runs in the
  **host** network namespace (`docker inspect --format '{{.HostConfig.NetworkMode}}' remnanode`
  says `host`). If it does not, drop the flag and the installer binds the docker0
  gateway instead, which bridged containers can reach.
- `--no-http` skips the HTTP proxy entirely. Nothing in this setup consumes it,
  and on a Remnawave node port 8080 is frequently already taken — CrowdSec's
  local API sits there by default.
- `--region 'DE,NL,…'` makes a rotation pool. Without it the installer picks the
  fastest exit anywhere on earth, which for a European node has meant Singapore.

### Reinstalling

Re-running the installer keeps what the last run settled on: ports and the
address they are published on, the region and pool (including where rotations
have moved it), deny/accept lists, watchdog tuning and its targets, the container
ceilings, the image, alerts and metrics, and the Gemini, `--impersonate` and
in-proxy switches. An explicit flag always wins; `--region ''` goes back to auto.

The address matters most: xray's outbound in the panel dials it, so a bare re-run
of a node installed with `--bind-loopback` must not move it to the gateway
default. Older versions did, and the tunnel then read healthy while carrying
nothing until the outbound was edited by hand.

## After installing, do the routing

The installer prints the outbound. **The outbound alone carries nothing** — the
panel owns the node's xray config, so the rules go in the panel, not on the node:

```bash
vps-psiphon routing
```

The two UDP rules it prints are not optional. This SOCKS is TCP-only: psiphon
answers UDP ASSOCIATE with `REP=7 COMMAND NOT SUPPORTED`. Point UDP at it and DNS
dies along with everything else; leave UDP direct and QUIC/HTTP3 keeps succeeding
*outside* the tunnel, so a large share of traffic quietly ignores it. Blocking
UDP — with DNS as the single exception — pushes clients onto TCP, which is the
path that works.

To tunnel one service rather than everything, scope **both** the UDP block and the
TCP rule to the same list, and prefer the geosite category to hand-written names —
`geosite:google-gemini` rather than `gemini.google.com`. A service is more hosts
than its front page: Gemini's chat goes to `geminiweb-pa.clients6.google.com`, the
Android app to `robinfrontend-pa` / `proactivebackend-pa` / `geller-pa.googleapis.com`.
A list naming the page alone tunnels the page while the conversation leaves
directly from the node, two addresses for one session. `routing` prints the
scoped pair.

## Checking the services the exit is for

A tunnel can be alive, fast and in an accepted country and still be useless:
Google refuses single Psiphon exits per service. On 2026-10-19
`gemini.google.com` answered **403** through an AT exit for hours while every
check here read green, until a rotation was made by hand.

So the watchdog also fetches the services the exit is for, listed in
`PROBE_URLS` (`--probe-urls 'https://… https://…'`, default
`https://gemini.google.com/app`, `''` turns it off, kept across reinstalls):

- through the tunnel, on every check, as a GET cut off at 64 KB — a check costs
  the head of a page, not the page;
- a **403 or 451** from any of them is a failure like a wrong country: it counts
  towards the same window, alerts once, and rotates;
- nothing else is judged — not a timeout, a 5xx or a redirect. The target can be
  down for reasons of its own, and a dead tunnel is caught by the other checks.

`vps-psiphon status` fetches the same URLs and prints a `target` line for each.

## Asking Gemini itself

A status code cannot see Gemini's own geo-check: where Gemini declines an
address, its page still answers **200**, and the refusal — error **1060**,
"Gemini isn't available in your region yet" — only arrives in the answer to a
message. So at every check the watchdog runs `vps-psiphon-gemini-check`, ported
from [vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon) 1.2:

1. fetch `gemini.google.com/app` through the tunnel for its session fields;
2. send one logged-out message and hold the answer open — Gemini can take a
   minute or more, and Psiphon's servers cut a connection on which no byte has
   moved for 30 s, so a second request on the same HTTP/2 connection trickles one
   byte every 2 s until the answer is in (two minutes at most);
3. **1060 → rotate at once**, without waiting for the failure window (the
   cooldown still applies). A reply → ok. Anything else is *inconclusive* and
   never rotates.

About 1 MB per check. `--no-gemini-check` turns it off; `vps-psiphon gemini`
runs it by hand, `vps-psiphon gemini --direct` from the host's own address — to
tell a burned exit from a refusal that follows the whole host.

Where this copy differs from upstream, and why:

- **A reply without a place is ok.** Upstream calls a reply ok only when Gemini
  names the place it puts the exit in. Measured from a US datacenter on
  2026-11-05, Gemini answered "Hello! How can I help you today?" run after run
  and never named one — under upstream's rule a served exit stays inconclusive
  forever. Here a response candidate with text is enough, and its first words go
  into the log, so an answer that is itself an error reads as one.
- **An older curl costs precision, not the check.** Holding the answer open
  needs curl with `--parallel` (7.66) and HTTP/2. Without them the message goes
  alone: a refusal that arrives within 30 s is still read, and the log line says
  that slower answers are lost.
- **A stale check alerts.** Upstream's check once stopped working for days when
  Gemini changed the frame of its refusal: every refusal read as
  "inconclusive", and nothing rotated. A check that settles nothing for 18
  checks in a row (3 hours) now raises one alert (`GEMINI_STALE_CHECKS`).

### Browser captcha: `--impersonate`

Where Gemini leaves through the tunnel while `www.google.com` leaves from
another address, Google can flag the exit **for browsers only**: Gemini sends a
browser to `www.google.com/sorry`, the captcha is bound to the tunnel's address,
and opened from the other one it offers nothing to solve. Plain curl gets the
page through the same exit, so no check sees it.

`--impersonate` installs [curl-impersonate](https://github.com/lexiforest/curl-impersonate)
under `/opt/vps-psiphon/curl-impersonate`, and the Gemini check fetches its page
as the newest Chrome the build knows; a redirect to `/sorry` rotates at once.
The latest release is checked against the sha256 GitHub publishes for it; if
that cannot be read or fails, a pinned release (v2.3.2, digests in the
installer) is taken. A first install with `--impersonate` stops before changing
anything if neither works; a reinstall keeps the build it has, and one that was
not asked for again on this run is never blocked by the download. Off by
default: where all of Google goes through the tunnel the captcha can be solved,
and rotating would lose a usable exit. `--no-impersonate` removes the build.

## In-proxy and Psiphon's tactics

Psiphon's servers send every client *tactics* — settings applied on top of its
config — and they put **in-proxy** first: the first dials of each tunnel go
through a volunteer's device over WebRTC. That is built for users whose networks
block Psiphon; an exit carries a whole host's traffic, and upstream measured such
tunnels dying within minutes or crawling at a few hundred KB/s, while direct ones
carried megabytes a second for hours.

So the launcher writes `"DisableTactics": true` and a `LimitTunnelProtocols`
list without the three `INPROXY-WEBRTC` protocols into `psiphon.config` at every
start (seeding the file from the image first, so even the first tunnel after an
install gets it). The watchdog logs every tunnel the client brings up with its
protocol — `tunnel up: QUIC-OSSH (connected at …)` — which is where the
exclusion shows. `--inproxy` lets Psiphon choose again.

**Safe mode.** Psiphon refuses to start on a protocol name its build does not
know, so an image newer or older than that list would loop on a dead tunnel.
After three restarts in a row that each come less than 90 s after the previous
one, the launcher starts without its settings — Psiphon's defaults — and says so
in the journal, in `vps-psiphon status` and in one alert. A start that lives
past 90 s ends the streak, so a crash with another cause leaves nothing behind.

## When rotations do not help

A rotation drops every live connection. When the fault follows the host rather
than the exit — Google refusing the node's whole pool, an upstream outage, a
check gone stale — rotating every cooldown changes nothing but that. After
**three rotations in a row with no passing check between them**, the cooldown
doubles with each further one up to `ROTATE_COOLDOWN_MAX` (default 7200 s), and
one alert says so; the first passing check ends it. Set `ROTATE_COOLDOWN_MAX`
equal to `ROTATE_COOLDOWN` to turn it off.

Failures also belong to the tunnel they were counted on: a tunnel started by
anything — the watchdog, `rotate`, `region`, the installer, a crash — begins
with an empty failure window (upstream's fix, ported), and a check during which
the tunnel restarted is not judged at all.

## Verifying it is not an open proxy

```bash
vps-psiphon verify
```

Checks every listener on the SOCKS port — and on the HTTP proxy port, which is
just as open — flags wildcard *and* public addresses, checks that SOCKS actually
works, and prints the one external test that means anything.

**Do not use `nc -z`, or any TCP-connect probe, to decide whether the port is
exposed.** Some providers tarpit every port and complete the TCP handshake for
ports nothing listens on. On such a host `nc -z` reports "open" for a port that
is firmly closed — and reports exactly the same for one that is genuinely
exposed, so it cannot distinguish the safe case from the dangerous one. Only a
real SOCKS handshake can:

```bash
# from another machine — it must FAIL
curl --max-time 20 --socks5-hostname <host>:1080 https://api.ipify.org
```

This matters because the failure mode is severe. Published on a wildcard address,
this is an open SOCKS5 proxy: port 1080 is scanned continuously, open ones are
found within hours, and they land in public proxy lists and from there in
reputation blocklists — being an open proxy is grounds for listing on its own.
After that, other people's traffic runs on your bandwidth, inside your tunnel,
where egress port filtering cannot see it.

## Managing it

```
vps-psiphon status                  exit IP, country, captcha, throughput, targets
vps-psiphon verify                  exposure + functional check
vps-psiphon routing                 panel rules, with the reasoning
vps-psiphon rotate                  new tunnel, new exit, advances the pool
vps-psiphon region DE               pin one country
vps-psiphon pool 'DE NL FR'         set the rotation pool
vps-psiphon accept 'DE NL'          which verdicts are acceptable
vps-psiphon update-image [--check]  move the pinned digest to the followed tag's build
vps-psiphon gemini [--direct]       ask Gemini now, through the tunnel or from the host
vps-psiphon notify-test             send a test Telegram alert
vps-psiphon speed                   throughput through the tunnel
vps-psiphon logs / watchdog         container log / watchdog journal
vps-psiphon uninstall               removes everything it wrote, including itself
```

`rotate`, `region`, `pool`, `accept` and `update-image` share a lock with the
watchdog and the installer, so a manual command never lands in the middle of a
check or a reinstall.

## Keeping the image current

The image is pinned by digest so it cannot change under you — which also means it
never picks up a fix on its own. `IMAGE` is stored as `repo:tag@sha256:…`: the
digest is what runs, the tag is what updates follow. The default follows
`:latest`; a node installed with `--image repo:v2` keeps following `:v2`.

- `vps-psiphon update-image --check` pulls the followed tag and shows whether the
  digest moved; nothing changes.
- `vps-psiphon update-image` switches to the new digest, restarts the tunnel (live
  connections drop) and removes the old image.
- `vps-psiphon update-image repo:v3` switches **and makes `:v3` the followed tag**
  from then on. A bare digest (`repo@sha256:…`) pins that build and keeps the
  current tag.

A reinstall keeps the pinned digest and the followed tag. `--image repo@sha256:…`
(no tag) on a reinstall keeps the tag followed so far.

## Alerts and metrics

Both are off unless configured.

- **Telegram**: `--tg-token <bot token> --tg-chat <chat id>` (or `VPSPSI_TG_TOKEN=<bot token>` in the environment instead of `--tg-token`, which keeps the token out of `ps` and the shell history). The watchdog sends
  an alert on every rotation (reason, old → new exit, region step), the first
  time an exit is seen in a denied country or refused by a target, and when a
  rotation did not bring the tunnel back; once each when rotations start backing
  off, when the Gemini check has settled nothing for three hours, when the
  launcher enters safe mode, and when `--impersonate` is on without a build. Alerts go directly, not through the tunnel. The token is kept in
  `/etc/default/vps-psiphon` (mode 0600) and never passed on a command line.
  `vps-psiphon notify-test` checks the setup.
- **Prometheus**: if `/var/lib/node_exporter/textfile_collector` exists (or
  `--metrics-dir` points elsewhere), the watchdog writes `vps-psiphon.prom` there
  after every check: `vps_psiphon_up`, `vps_psiphon_check_ok`,
  `vps_psiphon_throughput_kbps`, `vps_psiphon_window_failures`,
  `vps_psiphon_rotations_total`, `vps_psiphon_last_rotate_timestamp_seconds`,
  `vps_psiphon_captcha`, `vps_psiphon_target_refused`,
  `vps_psiphon_country_info{gl="XX"}`, `vps_psiphon_last_check_timestamp_seconds`,
  `vps_psiphon_gemini_result` (0 ok, 1 refused, 2 inconclusive, 3 captcha),
  `vps_psiphon_gemini_inconclusive_streak`, `vps_psiphon_rotation_cooldown_seconds`,
  `vps_psiphon_safe_mode`.

The watchdog log is rotated weekly through `/etc/logrotate.d/vps-psiphon`.

## What this copy changed

| | |
|---|---|
| **Digest-pinned default image** | upstream ships `:latest`, which re-resolves on every pull — the code on your node can change with no local edit and no announcement. `--image` still accepts a moving tag, with a warning. |
| **Container ceilings** | `--memory 512m`, `--pids-limit 256`, log rotation caps. On a 1 GB node the OOM killer reaches for the largest process, and that is xray, not psiphon. Overridable via `--memory` / `--pids-limit`. |
| **`routing`** | prints the panel rules the outbound is useless without, UDP handling included. |
| **`verify`** | answers "is this reachable from outside" in a way TCP-connect probes cannot. |
| **Input checks** | every flag is validated before anything is written; country codes are normalised. |
| **Reinstall keeps state** | region, published address, container ceilings, image, tuning and alerts survive a re-run instead of silently resetting. |
| **Watchdog fixes** | a timed-out transfer is judged as slow, not as a dead tunnel; `status` applies the deny-list like the watchdog does; one lock for the watchdog and manual commands. |
| **Target checks** | the services the exit is for (`PROBE_URLS`) are fetched through it; a 403/451 rotates — Google refuses single exits per service while the other checks read green. |
| **From upstream 1.2** | the Gemini check with the 1060 refusal and the held-open answer, `--impersonate`, the in-proxy exclusion with tactics off, failures counted per tunnel — see the sections above, and [CREDITS.md](CREDITS.md). |
| **Fault tolerance around them** | a reply without a place counts as served; an older curl degrades the check instead of breaking it; a stale Gemini check alerts; the launcher's safe mode; back-off for futile rotations; a reinstall is not blocked by a curl-impersonate download it did not ask for; the watchdog unit is cut off after 15 min instead of hanging its timer. |
| **`update-image`, alerts, metrics** | moving the digest pin in the open; Telegram alerts; node_exporter metrics; log rotation. |
| **Tests and CI** | `bats tests` and `tests/lint.sh` (shellcheck, generated scripts included) run on every push. |

The exit-quality watchdog itself — the reason to choose this family of scripts at
all — is upstream's design; the changes above fix and extend it. The one new
judgement, target refusals, asks upstream's own question — is this exit still worth
having — of the services it is actually used for.

## Choosing an exit country

Psiphon does not operate exits everywhere. The regions actually on offer can be
read from the server list the client itself downloads:

```bash
strings -a /opt/vps-psiphon/config/ca.psiphon.PsiphonTunnel.tunnel-core/datastore/psiphon.boltdb \
  | grep -oE '"region":"[A-Z]{2}"' | sort | uniq -c | sort -rn
```

At the time of writing that yields 26 countries — `CA US DE GB NL FR SE IT PL IN
JP SG RS AU AT BE IE ES CH DK CZ NO RO LT ID BR`. Asking for one that is not
there leaves the watchdog rotating forever without ever matching. Notably absent:
the Caucasus and Central Asia, so Armenia, Georgia and Kazakhstan are not
reachable this way.

## Warnings worth repeating

**Do not install this inside the country you are bypassing censorship from.** The
Psiphon client emits recognisable circumvention traffic. Under DPI it is both
blockable itself and a way to fingerprint the server hosting it. It belongs on a
foreign node you already reach by some other transport.

**Running the image by hand is not equivalent, and the difference is called an
open proxy.** Inside the container psiphon binds `0.0.0.0`, so a plain
`docker run -p 1080:1080` publishes SOCKS5 — and the HTTP proxy with it — on every
address of the host, unauthenticated. This installer never publishes on a
wildcard; a `--bind` you type yourself is honoured as given, and defending that
address is then yours to do.

## Development

```bash
bash tests/lint.sh   # shellcheck: the installer and the scripts it generates
bats tests           # no root, docker or systemd needed — everything is stubbed
```

## License

MIT — see [LICENSE](LICENSE). Original copyright retained, as it requires.
