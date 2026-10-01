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

Re-running the installer keeps what the last run settled on: ports, the region
and pool (including where rotations have moved it), deny/accept lists, watchdog
tuning, the image, alerts and metrics. An explicit flag always wins;
`--region ''` goes back to auto.

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
vps-psiphon status                  exit IP, country, captcha, throughput
vps-psiphon verify                  exposure + functional check
vps-psiphon routing                 panel rules, with the reasoning
vps-psiphon rotate                  new tunnel, new exit, advances the pool
vps-psiphon region DE               pin one country
vps-psiphon pool 'DE NL FR'         set the rotation pool
vps-psiphon accept 'DE NL'          which verdicts are acceptable
vps-psiphon update-image [--check]  move the pinned digest to the followed tag's build
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

- **Telegram**: `--tg-token <bot token> --tg-chat <chat id>`. The watchdog sends
  an alert on every rotation (reason, old → new exit, region step), the first
  time an exit is seen in a denied country, and when a rotation did not bring the
  tunnel back. Alerts go directly, not through the tunnel. The token is kept in
  `/etc/default/vps-psiphon` (mode 0600) and never passed on a command line.
  `vps-psiphon notify-test` checks the setup.
- **Prometheus**: if `/var/lib/node_exporter/textfile_collector` exists (or
  `--metrics-dir` points elsewhere), the watchdog writes `vps-psiphon.prom` there
  after every check: `vps_psiphon_up`, `vps_psiphon_check_ok`,
  `vps_psiphon_throughput_kbps`, `vps_psiphon_window_failures`,
  `vps_psiphon_rotations_total`, `vps_psiphon_last_rotate_timestamp_seconds`,
  `vps_psiphon_captcha`, `vps_psiphon_country_info{gl="XX"}`,
  `vps_psiphon_last_check_timestamp_seconds`.

The watchdog log is rotated weekly through `/etc/logrotate.d/vps-psiphon`.

## What this copy changed

| | |
|---|---|
| **Digest-pinned default image** | upstream ships `:latest`, which re-resolves on every pull — the code on your node can change with no local edit and no announcement. `--image` still accepts a moving tag, with a warning. |
| **Container ceilings** | `--memory 512m`, `--pids-limit 256`, log rotation caps. On a 1 GB node the OOM killer reaches for the largest process, and that is xray, not psiphon. Overridable via `--memory` / `--pids-limit`. |
| **`routing`** | prints the panel rules the outbound is useless without, UDP handling included. |
| **`verify`** | answers "is this reachable from outside" in a way TCP-connect probes cannot. |
| **Input checks** | every flag is validated before anything is written; country codes are normalised. |
| **Reinstall keeps state** | region, image, tuning and alerts survive a re-run instead of silently resetting. |
| **Watchdog fixes** | a timed-out transfer is judged as slow, not as a dead tunnel; `status` applies the deny-list like the watchdog does; one lock for the watchdog and manual commands. |
| **`update-image`, alerts, metrics** | moving the digest pin in the open; Telegram alerts; node_exporter metrics; log rotation. |
| **Tests and CI** | `bats tests` and `tests/lint.sh` (shellcheck, generated scripts included) run on every push. |

The exit-quality watchdog itself — the reason to choose this family of scripts at
all — is upstream's design; the changes above fix and extend it without changing
what it judges.

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
