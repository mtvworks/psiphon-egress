# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub:
**Security → Report a vulnerability** on this repository
(<https://github.com/mtvworks/psiphon-egress/security/advisories/new>).
Do not open a public issue for them.

Useful to include: the installer commit you ran, the host OS, the flags used,
and what an attacker could reach (the SOCKS port, the host, the alert channel).

## Supported versions

Only the latest commit on `main` gets fixes. Nodes should install the
installer pinned by commit SHA and verified by sha256, as the README shows.
