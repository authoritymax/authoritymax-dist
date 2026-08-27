# AuthorityMax distribution

This repository is the public distribution channel for AuthorityMax. The source code lives in a
private repository; everything an operator, a desktop client, or a provisioned computer host needs
to fetch without credentials is published here.

| What | Where |
| --- | --- |
| Server images: `app` (api, worker, web), `updater` | `ghcr.io/authoritymax/authoritymax-dist/app`, `…/updater` |
| Computer host images: `computer` (Debian 13 desktop), `supervisor` | `ghcr.io/authoritymax/authoritymax-dist/computer`, `…/supervisor` |
| Desktop installers and auto-update feeds | [Releases](https://github.com/authoritymax/authoritymax-dist/releases) |
| Release manifests (version → source commit → image tags) | [`releases/`](./releases) |
| Self-host files: Compose stack, Caddy, hardening, backups, dedicated-host tunnel, Contabo bootstrap | [`infra/`](./infra) |
| Computer OS image sources | [`infra/sandboxes/computer/`](./infra/sandboxes/computer) |
| Operator documentation | [`docs/self-host.md`](./docs/self-host.md), [`docs/dedicated-hosts.md`](./docs/dedicated-hosts.md) |

Files under `infra/`, `docs/`, and `.env.example` are synchronised automatically from the source
repository on every change to its `main` branch; `SOURCE_COMMIT` records the commit they came from.
Pull requests against those files cannot be accepted here — they are overwritten on the next sync.
Report problems through [Issues](https://github.com/authoritymax/authoritymax-dist/issues).

## Self-hosting from this repository

```bash
git clone https://github.com/authoritymax/authoritymax-dist.git /srv/authoritymax
cd /srv/authoritymax
cp .env.example .env   # fill in production values; set AUTHORITYMAX_IMAGE_TAG=latest
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml pull
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml up -d --wait --pull never
```

A fresh Debian 13 VPS can be prepared end to end with `sudo bash infra/contabo/bootstrap-control-plane.sh`.
See [`docs/self-host.md`](./docs/self-host.md) for the full procedure and
[`docs/dedicated-hosts.md`](./docs/dedicated-hosts.md) for per-account computer hosts.

## Image tags

| Tag | Meaning |
| --- | --- |
| `vX.Y.Z`, `vX.Y` | a release |
| `latest` | the newest stable release |
| `sha-<commit>` | the exact source commit; what the updater deploys |
| `edge` | the newest build of the source `main` branch |

Every image is built and attested by the source repository's CI and pushed here; the packages are
linked to this repository so they stay publicly pullable.

## Security

Report vulnerabilities as described in [SECURITY.md](./SECURITY.md).
