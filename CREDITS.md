# Credits

This project is not original work. It is a derivative of one upstream project,
with ideas taken from two others. All three deserve the credit; the bugs are ours.

## Base — [Chara-Freedom/vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon) (MIT)

Effectively all of the code here is theirs. We kept the filename
`psiphon_install.sh` deliberately, so that diffing this copy against upstream
stays a one-line command and improvements can flow back.

What we did not change, because it is the best thing about that project: the
watchdog does not merely ask *is the tunnel alive* — it asks *is this exit still
worth having*. It weighs Google's country verdict on the address, captcha
presence, a deny-list of sanctioned regions, a separate accept-list, and a
throughput floor, and rotates on the answer.

That distinction is not academic. While deploying across three nodes we twice
drew exits that Google geolocates to **RU** — on a fast, healthy, perfectly
reachable tunnel. For anyone running a VPN out of that country, such an exit is
worse than no tunnel. Liveness probes call it healthy. This watchdog rotated it.

## Hardening ideas — [DenFiord/remnascripts](https://github.com/DenFiord/remnascripts) (MIT)

A markedly more engineered project (bats tests, CI, `SECURITY.md`, a "container
contract" verified before start and stop). We took two of its habits:

- **pin the image by digest instead of `:latest`** — so the code running on the
  node cannot change under you on a pull, silently;
- **cap the container** — `--memory`, `--pids-limit`, and log rotation, none of
  which the base project sets.

We did not adopt its health model: its HealthGuard probes reachability
(`generate_204`, cloudflare trace, github) and rotates after two failures. That
is a liveness check, and it would have kept both RU exits described above.

## Routing recipe — [Vinton777/remnawave-psiphon-installer](https://github.com/Vinton777/remnawave-psiphon-installer)

A full node bootstrap that wires Remnawave through the panel API, and a consumer
of vps-psiphon rather than a competitor to it. Its routing block is the piece
both other projects leave to the reader, and getting it wrong produces an
internet that half works:

```json
{ "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" },
{ "type": "field", "network": "udp", "port": "53", "outboundTag": "DIRECT" },
{ "type": "field", "network": "udp", "outboundTag": "BLOCK" },
{ "type": "field", "network": "tcp", "outboundTag": "psiphon-out" }
```

`vps-psiphon routing` now prints it, with the reasoning attached.

## Upstream software

- [Psiphon-Labs/psiphon-tunnel-core](https://github.com/Psiphon-Labs/psiphon-tunnel-core) — the client
- [swarupsengupta2007/psiphon-docker](https://github.com/swarupsengupta2007/psiphon-docker) — the image, built from source in CI

Psiphon is a third-party network operated by Psiphon Inc. Traffic routed through
it is carried by their infrastructure under their terms of service and privacy
policy. That is a deliberate choice you are making on behalf of your users.
