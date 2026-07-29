# dnsmasq-lab

## Disclaimer
This project or the binary files available in the `Releases` area are `NOT` delivered and/or released by Red Hat. This is an independent project to help deploy `OCP/SNO` environment where you have no control over your `DNS`.

---

Podman lab that runs **dnsmasq** in a container and accepts external zone updates with the real **`nsupdate`** tool, authenticated by a **TSIG key**.

This is a great project, in case you are looking for to be working with [deploy-ocp](https://github.com/QikfixAI/deploy_ocp) to provision you own SNO. This project will allow you to answer properly the DNS calls, using the proper FQDN. 

dnsmasq does not speak RFC 2136 itself. This image pairs dnsmasq (queries on `:53`) with a small companion, `ddnsd` (updates on `:5353`), that validates TSIG, applies the UPDATE, rewrites dnsmasq config, and signals dnsmasq with `SIGHUP`.

Defaults: zone **`example.com`**, addresses on **`192.168.0.0/24`**.

## Layout

```
dnsmasq-lab/
├── Containerfile
├── compose.yaml
├── config/dnsmasq.conf
├── keys/                 # TSIG key (generated; not committed)
├── data/                 # dynamic zone state + dnsmasq drop-in
├── mgmt-scripts/
│   ├── cleanup.sh
│   └── test.sh
└── scripts/
    ├── generate-tsig-key.sh
    ├── start.sh / stop.sh
    ├── example-nsupdate.sh
    ├── ddnsd.py
    └── entrypoint.sh
```

## Prerequisites

- [Podman](https://podman.io/)
- Host tools for the demos: `nsupdate`, `dig` (`bind-utils` on RHEL/Fedora, `dnsutils` on Debian/Ubuntu)
- Optional: `podman compose` / `docker-compose` if you prefer Compose over `start.sh`
- Optional: if **firewalld** is running, `./scripts/start.sh` opens host ports
  `${DNS_PORT:-53}` and `${UPDATE_PORT:-5353}` (tcp+udp) permanently when they
  are not already allowed (requires privileges for `firewall-cmd`)

## Quick start

```bash
./scripts/generate-tsig-key.sh   # creates keys/update.key
./scripts/start.sh               # build + run with Podman
```

Default published ports:

| Host port | Role |
|-----------|------|
| `53/tcp+udp` | DNS queries (dnsmasq) |
| `5353/tcp+udp` | Dynamic updates (`nsupdate`) |

If the host cannot bind port 53 (rootless Podman, or another resolver), remap DNS only and leave updates on 5353:

```bash
DNS_PORT=1053 ./scripts/start.sh
# dig @127.0.0.1 -p 1053 …
# nsupdate still uses: server 127.0.0.1 5353
```

### Compose

```bash
./scripts/generate-tsig-key.sh
podman compose up -d --build
# or: podman-compose up -d --build
```

## Query

```bash
dig @127.0.0.1 static.example.com +short
# 192.168.0.10

# Reverse lookup (192.168.0.0/24 → 0.168.192.in-addr.arpa)
dig @127.0.0.1 -x 192.168.0.10 +short
# static.example.com.
```

Static bootstrap names:

| Name | Address | PTR |
|------|---------|-----|
| `gateway.example.com` | `192.168.0.1` | `1.0.168.192.in-addr.arpa` |
| `static.example.com` | `192.168.0.10` | `10.0.168.192.in-addr.arpa` |
| `ns1.example.com` | `192.168.0.53` | `53.0.168.192.in-addr.arpa` |

## Update the zone with nsupdate + key

```bash
./scripts/example-nsupdate.sh
# or interactively:

nsupdate -k keys/update.key
> server 127.0.0.1 5353
> zone example.com.
> update add app.example.com. 300 A 192.168.0.80
> update add app.example.com. 300 TXT "hello-from-nsupdate"
> send
> quit

dig @127.0.0.1 app.example.com A +short
dig @127.0.0.1 app.example.com TXT +short
```

Inline secret (lab only):

```bash
nsupdate -y "$(cat keys/update.secret)"
```

Delete a record:

```bash
nsupdate -k keys/update.key <<'EOF'
server 127.0.0.1 5353
zone example.com.
update delete app.example.com. A
send
EOF
```

Supported update types: **A**, **AAAA**, **TXT**, **CNAME**, **PTR**.

Wildcard A/AAAA names (`*.apps.example.com`) are stored as dnsmasq
`address=/apps.example.com/...` so queries like `foo.apps.example.com` resolve.

```bash
nsupdate -k keys/update.key <<'EOF'
server 127.0.0.1 5353
zone example.com.
update add *.apps.ocpcluster.example.com. 86400 A 192.168.0.101
send
EOF

dig @127.0.0.1 console-openshift-console.apps.ocpcluster.example.com +short
# 192.168.0.101
```

Note: `nslookup` queries both A and AAAA. For wildcards, ddnsd also adds
`address=/…/::` so AAAA is `NOERROR` instead of `NXDOMAIN` (a dnsmasq quirk
when `local=/example.com/` is set). Prefer `dig` for clear A-only checks.

A/AAAA entries in `192.168.0.0/24` are reverse-resolvable via the hosts file. Explicit PTR updates use the reverse zone:

```bash
nsupdate -k keys/update.key <<'EOF'
server 127.0.0.1 5353
zone 0.168.192.in-addr.arpa.
update add 80.0.168.192.in-addr.arpa. 300 PTR app.example.com.
send
EOF
```

## How it works

1. Client runs `nsupdate -k keys/update.key` against host port **5353**.
2. `ddnsd` verifies the TSIG signature; unsigned or wrong-key updates are refused.
3. Accepted changes are stored in `data/zone.json`, rendered to `data/dynamic.hosts` (A/AAAA) and `data/dynamic.conf` (TXT/CNAME).
4. `ddnsd` sends `SIGHUP` to dnsmasq for host changes, or restarts it when the conf drop-in changes, so records are served on **:53**.

## Stop

```bash
./scripts/stop.sh
```

## Cleanup

Remove the container, lab image, Alpine base image, TSIG keys, and dynamic zone data (source files are kept):

```bash
./mgmt-scripts/cleanup.sh
# or non-interactive:
./mgmt-scripts/cleanup.sh -y
```

## Full test

Runs dependency checks, cleanup, start, writes add/delete nsupdate files under
`data/`, applies adds and verifies with `nslookup`, then applies deletes and
verifies the records are gone. Requires DNS on host port **53**.

```bash
./mgmt-scripts/test.sh
```

Delete files written by the test (also usable manually):

```bash
nsupdate -k keys/update.key data/nsupdate-forward-delete.txt
nsupdate -k keys/update.key data/nsupdate-reverse-delete.txt
```

## Notes

- Zone name defaults to `example.com` (see `config/dnsmasq.conf` and `DDNS_ZONE`).
- Keep `keys/update.key` private; anyone with it can change the lab zone.
- Regenerating the key: `FORCE=1 ./scripts/generate-tsig-key.sh`, then restart the container.
