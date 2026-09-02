# Self-hosting AuthorityMax

The signed-in product is a long-running API, a Graphile Worker, Postgres, and a computer provider (Docker supervisor, E2B, Daytona, or Box). It is not a static site. The marketing site in `apps/www` can be hosted separately.

## Local (source checkout)

Same as the README quick start: `.env` from `.env.example`, Postgres via Compose, `pnpm sandbox:build`, `pnpm dev`, then [http://127.0.0.1:5173](http://127.0.0.1:5173). Electron: `pnpm --filter @authoritymax/desktop dev` while that stack is up.

## Docker Compose (single machine)

1. Copy `.env.example` to `.env` and set `BETTER_AUTH_SECRET` and `ENCRYPTION_KEY` to long random strings. AuthorityMax refuses placeholder or missing secrets outside `development` / `test` (or when `AUTHORITYMAX_ALLOW_DEV_SECRETS=1` is set).
2. Set `OPENROUTER_API_KEY` (and `COMPOSIO_API_KEY` if you want Plugins).
3. Build the computer image: `pnpm sandbox:build` (Compose also builds it via the `computer` service).
4. `docker compose --env-file .env -f infra/compose/docker-compose.yml up --build`
5. Open the web origin (`http://127.0.0.1:5173` by default). The first registered user becomes the deployment owner.

On Windows, if an older clone with `core.autocrlf=true` leaves the computer pane hung on boot (`bash\r` in sandbox logs): from a clean worktree, set `git config core.autocrlf false`, run `git add --renormalize . && git checkout -- .`, then rebuild with `pnpm sandbox:build`.

Compose runs Postgres, the sandbox supervisor (Docker socket), API, worker, and a Vite preview of the web app. Bot computers are sibling containers (`authoritymax/computer:local`). The API process does not get an unrestricted Docker socket; the supervisor owns the lifecycle.

Postgres is published on **loopback only** (`127.0.0.1:5433` on the host). Do not expose that port on a public VPS. Change `POSTGRES_PASSWORD` and keep Postgres on an internal network when you deploy remotely.

The Docker supervisor is not published. It is authenticated and stays on the internal Compose network because access to it is equivalent to control of the Docker host. It uses `BETTER_AUTH_SECRET` as its shared service credential by default; advanced deployments can set the same independent `SANDBOX_SUPERVISOR_TOKEN` value on the API, worker, and supervisor.

On a VPS, put TLS in front of `:5173` (or serve the web build behind your proxy) and set:

```env
BETTER_AUTH_URL=https://app.example.com
WEB_ORIGIN=https://app.example.com
API_URL=https://app.example.com
```

Cookies and CORS follow those origins. Keep `SIGNUPS_ENABLED` / `SIGNUP_ALLOWLIST` tight on a public host.

Optional:

```env
SIGNUPS_ENABLED=true
SIGNUP_ALLOWLIST=you@example.com,@company.com
SANDBOX_PROVIDER=docker   # or e2b, daytona, box. Keep fake only for pnpm test.
AGENT_RUNTIME=pi          # Keep scripted only for pnpm test.
WAKEUP_DRIVER=graphile
SANDBOX_IDLE_MS=600000    # pause the bot computer after 10 minutes idle
SANDBOX_IDLE_MS_BOX=180000            # idle tail for Box computers (per-second billing)
SANDBOX_IDLE_MS_DEDICATED_HOST=       # idle tail for dedicated-host computers; defaults to SANDBOX_IDLE_MS
# All three idle tails have a 30-second floor: a smaller value is ignored and the default applies.
COMPUTE_HOST_PROVIDER=                # contabo | box | fake; see docs/dedicated-hosts.md and docs/box-hosts.md
BOX_API_KEY=                          # when COMPUTE_HOST_PROVIDER=box
BOX_API_URL=                          # optional; defaults to https://ascii.dev/api/box/v1
BOX_HOST_TEMPLATE=                    # optional named snapshot; unset = base image
BOX_HOST_SIZE=default                 # small | default | large
DEDICATED_HOST_TUNNEL_CIDR_BOX=       # per-provider tunnel range; required for box, must not overlap 10.77.0.0/16
DEDICATED_HOST_WAKE_TIMEOUT_MS=90000  # box only: how long a wake may take before the host resets to asleep
COMPUTER_LEASE_WAIT_MS=30000          # how long a tool waits for a busy team computer before the run is requeued
SANDBOX_COMMAND_TIMEOUT_MS=300000 # stop a shell command after 5 minutes
# Time limits below are optional (defaults shown, 0 disables): they stop a run from
# staying "working" forever when a model or the computer stops answering.
MODEL_RESPONSE_TIMEOUT_MS=90000   # model must answer with response headers in time
RUN_IDLE_TIMEOUT_MS=600000        # fail a turn after 10 minutes with no model activity
RUN_MAX_DURATION_MS=7200000       # hard ceiling on one run attempt (2 hours)
SANDBOX_REQUEST_TIMEOUT_MS=30000  # supervisor control calls (files, input, stop)
SANDBOX_PROVISION_TIMEOUT_MS=120000 # provisioning: image pull, container start, screen
SANDBOX_SCREEN_TIMEOUT_MS=20000   # observe/screen calls; action batches add their waits
SANDBOX_EXEC_GRACE_MS=15000       # added to a command's timeout for the exec round trip
MAX_TOOL_CALLS_PER_TURN=  # optional Pi turn tool-call fuse; unset/0 = unlimited
E2B_API_KEY=              # when SANDBOX_PROVIDER=e2b
DAYTONA_API_KEY=          # when SANDBOX_PROVIDER=daytona
BOX_API_KEY=              # when SANDBOX_PROVIDER=box
```

### Account email (password reset)

"Forgot password?" only appears once an email provider is configured; without one, users can still
change their password from Settings while signed in. Reset links point at `WEB_ORIGIN/reset-password`
and expire after an hour.

```env
EMAIL_PROVIDER=smtp       # smtp | resend | console (console prints the mail to the API log; dev only)
EMAIL_FROM=AuthorityMax <no-reply@example.com>
SMTP_URL=smtp://user:password@mail.example.com:587   # when EMAIL_PROVIDER=smtp (smtps:// for implicit TLS)
RESEND_API_KEY=           # when EMAIL_PROVIDER=resend
```

To use an operator-controlled OpenAI-compatible server such as Ollama, LM Studio, llama.cpp, or
MLX, list its model IDs and an endpoint that both the API and worker processes can reach:

```env
AUTHORITYMAX_LOCAL_MODELS=qwen3:4b,llama3.1:8b
AUTHORITYMAX_LOCAL_MODELS_URL=http://127.0.0.1:11434/v1
AUTHORITYMAX_LOCAL_CONTEXT_WINDOW=32768
AUTHORITYMAX_LOCAL_MAX_TOKENS=4096
```

The loopback default is suitable when running AuthorityMax from a source checkout. In Docker Compose,
use the model server's Compose service name or another address reachable from the containers.
Only configure an endpoint you control: prompts, attachments, and tool results sent to that model
leave AuthorityMax through this URL. Leave `AUTHORITYMAX_LOCAL_MODELS` blank to disable the provider.

Each user can also connect their own OpenAI-compatible endpoint from **Connect a model** /
**Settings → Models** on web and mobile. Choose **OpenAI-compatible**, enter the server base URL
(for example `http://127.0.0.1:8000/v1` for Rapid-MLX, Ollama, LM Studio, llama.cpp, or vLLM),
the exact model id from that server, and an optional API key. By default AuthorityMax only allows
loopback, RFC1918, and `host.docker.internal` targets. To permit public hostnames, set
`AUTHORITYMAX_OPENAI_COMPAT_ALLOW_PUBLIC=1` in the deployment environment. Public hostnames must resolve
only to public addresses; redirects and DNS answers that reach private or link-local networks are
rejected.

Do not commit `.env`. Never put `COMPOSIO_API_KEY`, OpenRouter keys, or provider tokens in git, logs, or chat.

## Choosing which apps Integrations offers

Integrations lists only the apps enabled for this deployment, not the connector provider's whole directory. With Composio, an app is enabled when its toolkit has at least one enabled auth config in your Composio project (what you set up under Integrations in the Composio dashboard; read through `GET /api/v3/auth_configs`). Apps a user already connected stay listed. A project with nothing enabled yet offers the featured apps (Gmail, Google Calendar, Google Drive, Slack, Notion) so the screen is not empty. The enabled set is cached for an hour, like the app directory.

To narrow the list further, set `INTEGRATIONS_ALLOWLIST` to comma-separated app slugs, for example `INTEGRATIONS_ALLOWLIST=gmail,google-calendar,slack`. Matching ignores case and separators, and the allowlist applies to every managed connector provider. It only restricts; it cannot offer an app the provider has not enabled. Search on the Integrations screen only looks within the offered apps. MCP, OpenAPI, and Treg tool sources under Advanced are not affected.

## Choosing a computer provider

The Electron desktop app is a client of the same API. Docker and E2B still apply. On first launch, Electron asks the deployment owner whether bots should keep using Docker or run on this Mac as you. `SANDBOX_PROVIDER=desktop` is a separate, explicit provider that always runs commands on the service host.

- **Docker** is the default for local use and the quickest self-hosted setup. Workspace bots share a persistent Team Computer by default; Private computers are optional. Keep the supervisor private, as the included Compose file does.
- **E2B** runs bot computers away from the AuthorityMax host and is the recommended choice for public or multi-user production deployments. AuthorityMax checkpoints the portable workspace and browser-profile directory to `DATA_DIR`; the E2B disk is a runtime cache, not the durable source of truth.
- **Daytona** provides the same remote-computer contract through Daytona sandboxes. Configure `DAYTONA_API_KEY` and optionally `DAYTONA_API_URL` / `DAYTONA_TARGET`.
- **Box by ASCII** provides a managed Linux desktop through `BOX_API_KEY` and optionally `BOX_API_URL`. AuthorityMax always creates or resumes boxes with `noEnv: true`, keeps the portable workspace under `/home/user/authoritymax-home`, and refreshes a two-hour TTL. A Box currently exposes one shared desktop, so concurrent Team bots can still use shell and files but only one can use graphical tools at a time.
- **Desktop provider** / **This Mac** runs commands on the API/worker host. Docker stays the default. The Electron app asks once; if you choose This Mac, bots can use working directories under your home folder. Do not enable it on a public or shared service. macOS does not show its own permission dialog for this.
- **Dedicated host** (`SANDBOX_PROVIDER=dedicated-host`) gives every account its own VPS running the Docker computer image; see [docs/dedicated-hosts.md](./dedicated-hosts.md).
- **Fake** is only an emulator for verification.

## Backup

```bash
./scripts/backup.sh
```

This dumps Postgres (`pg_dump`) and archives `data/` into `backups/<stamp>/`.

## Deploying from the distribution repository

The source repository is private. Everything an operator needs is published to
[`authoritymax/authoritymax-dist`](https://github.com/authoritymax/authoritymax-dist): the Compose
stack, the systemd units, the Contabo and dedicated-host scripts, the computer image, `.env.example`,
and this document. It carries no application source, so it deploys the published images rather than
building them.

```bash
git clone https://github.com/authoritymax/authoritymax-dist.git /srv/authoritymax
cd /srv/authoritymax
cp .env.example .env && chmod 600 .env
# Set AUTHORITYMAX_HOST, POSTGRES_PASSWORD, BETTER_AUTH_SECRET, ENCRYPTION_KEY, and
# AUTHORITYMAX_IMAGE_TAG=latest — `local` builds from source, which is not present here.
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml pull api worker web
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml up -d --wait --pull missing
```

`SOURCE_COMMIT` at the root of that repository records the source revision the operator files came
from. `infra/contabo/deploy-main.sh` detects which checkout it is running in and pulls instead of
building; it refuses to deploy a distribution checkout pinned to `AUTHORITYMAX_IMAGE_TAG=local`.

## Public single-VM deployment

`infra/compose/docker-compose.prod.yml` runs the hosted product with Postgres, the API, worker, web app,
and automatic HTTPS through Caddy. It uses E2B for bot computers, so the VM never exposes a Docker
supervisor or browser containers. The root-equivalent updater sidecar is an explicit opt-in profile.

Before deploying to a new Ubuntu host, create and verify a key-only `deploy` account, then apply the
idempotent host-hardening baseline. It disables SSH passwords and root login, rate-limits SSH, allows
only SSH/HTTP/HTTPS through UFW, enables fail2ban, unattended security updates, AppArmor, audit rules,
and conservative kernel/network protections. Keep the provider console open until a fresh SSH login
succeeds after the script reloads SSH.

```bash
sudo DEPLOY_USER=deploy FAIL2BAN_IGNORE_IPS="203.0.113.10" bash infra/compose/harden-host.sh
```

Set `FAIL2BAN_IGNORE_IPS` to your own address (space- or comma-separated, IPv4/IPv6, CIDR allowed) so
you can never be banned from your own host — a handful of connection probes while sshd restarts is
enough to trip the jail, and the ban time doubles each repeat. If it does happen, unban from another
machine with `sudo fail2ban-client set sshd unbanip <ip>`.

The production host also uses `infra/compose/docker-daemon.json` to enable live restore, bounded local
container logs, default no-new-privileges, and the kernel NAT path instead of Docker's userland proxy.

1. Point an `A`/`AAAA` record such as `app.example.com` at the VM and allow inbound TCP 80/443 and
   UDP 443. If you use Cloudflare, enable the proxy with **Full (strict)** TLS and copy
   `Caddyfile.cloudflare.example` to an operator-controlled path outside the public checkout. Set
   `CADDYFILE_PATH` to that absolute path. The example drops application requests that do not come
   from Cloudflare's [published IP ranges](https://www.cloudflare.com/ips/); reconcile those ranges
   whenever Cloudflare publishes a change. A Cloudflare Tunnel can replace the public web listeners.
2. Clone the repository on the VM and create a root `.env` with production-only values. At minimum set
   `POSTGRES_PASSWORD`, `BETTER_AUTH_SECRET`, `ENCRYPTION_KEY`, `E2B_API_KEY`, `OPENROUTER_API_KEY`,
   `AUTHORITYMAX_HOST`, and the three public origins. Set `AUTHORITYMAX_DEPLOY_DIR` when the checkout is not at
   the supported Linux default, `/srv/authoritymax`. Use URL-safe random values for database credentials.
   If you enable the `updater` profile, also set a dedicated `AUTHORITYMAX_UPDATER_TOKEN` (at least 32
   characters) that differs from `BETTER_AUTH_SECRET` and `SANDBOX_SUPERVISOR_TOKEN`.
3. Keep registration allowlisted while the service is private:

```env
NODE_ENV=production
AUTHORITYMAX_HOST=app.example.com
# Optional operator-owned override, for example the Cloudflare allowlist file:
# CADDYFILE_PATH=/etc/authoritymax/Caddyfile.prod
BETTER_AUTH_URL=https://app.example.com
WEB_ORIGIN=https://app.example.com
API_URL=https://app.example.com
SIGNUPS_ENABLED=true
SIGNUP_ALLOWLIST=owner@example.com,reviewer@example.com
SANDBOX_PROVIDER=e2b
AGENT_RUNTIME=pi
WAKEUP_DRIVER=graphile
DATA_DIR=/data
# Absolute path of this checkout as the Docker daemon sees it. /srv/authoritymax is the Linux default;
# set this explicitly for every other layout. See "The deploy directory must be one path" below.
AUTHORITYMAX_DEPLOY_DIR=/srv/authoritymax
AUTHORITYMAX_IMAGE_TAG=local
# Optional: required only with `--profile updater`.
# AUTHORITYMAX_UPDATER_TOKEN=replace-with-32-plus-character-updater-token
```

4. Build the images from your checkout and start the stack, then verify its public health endpoint:

```bash
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml \
  build --build-arg GIT_SHA=$(git rev-parse HEAD)
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml \
  up -d --wait --pull missing
curl --fail https://app.example.com/health
```

**Build, do not pull, for a first deployment.** `AUTHORITYMAX_IMAGE_TAG` ships as `local`, a tag no
registry serves, so the commands above build `api`, `worker`, and `web` from the checkout you just
cloned. The opt-in command under [Updater sidecar](#updater-sidecar) builds `updater` when needed.
Running `docker compose … pull` first — as earlier versions of this page told you to — fails outright
with `error from registry: denied` whenever the tag you are on has not been published, and there is
nothing to fall back to.

`--pull missing` fetches only images that are not on the host yet, so it never re-pulls or moves an
image you just built. It has to be `missing` rather than `never`: `build` builds `api`, `worker`, and
`web`, but `postgres` and `caddy` are digest-pinned upstream images that nothing builds, and `never`
would fail a first deployment with `No such image: postgres:16@sha256:…`.

Passing `GIT_SHA` is what makes `GET /health` report a `"revision"`; a locally built image has no
other way to know its commit. Prebuilt images from the registry bake it in at publish time, so when
you switch to a release tag you should leave `GIT_SHA` unset — a value in `.env` would override what
the image already knows.

Once a release has been published you can switch this host to prebuilt images by setting
`AUTHORITYMAX_IMAGE_TAG` to that release tag and running `pull` followed by `up -d --wait --pull missing`.
See [Published images and tags](#published-images-and-tags) for the tag contract.

The root `.env` is excluded from both Git and the Docker build context. The database, application data,
and Caddy certificates live in named Docker volumes.

The production Compose file pins Postgres and Caddy to multi-architecture manifest digests, and the
published application/updater builds pin their base-image digests. Refresh those pins deliberately
when taking upstream security updates; changing only the visible major tag does not change the
content while a digest is present.

For the single-VM production layout, install `infra/compose/backup-prod.sh` as
`/usr/local/sbin/authoritymax-backup` and enable the supplied `authoritymax-backup.timer`. It creates a verified
Postgres custom-format dump plus an application-data archive under `/var/backups/authoritymax`, with mode
`0600` and seven-day rotation. These local snapshots help with operator mistakes but are not a
substitute for an encrypted off-host backup or provider snapshot.

When `/etc/wireguard` exists, the same snapshot also archives it as `wireguard.tar.gz`. That is the
control-plane WireGuard identity: every dedicated host pins the control plane's public key when it
first boots and nothing re-keys it afterwards, so losing these files strands every host that is
already running. The archive contains the control plane's private key, so treat the whole snapshot
as a secret and keep the off-host copy encrypted.

## Contabo VPS (Debian 13 or Ubuntu 22.04/24.04)

`infra/contabo/bootstrap-control-plane.sh` turns a fresh Contabo Cloud VPS into an AuthorityMax
control plane on Debian 13 or Ubuntu 22.04/24.04, including the dedicated-host machinery from
[docs/dedicated-hosts.md](./dedicated-hosts.md).

1. Order a Contabo Cloud VPS (4+ GB is enough for the control plane itself) with the Debian 13 or
   Ubuntu 22.04/24.04 image, and point an `A`/`AAAA` record such as `app.example.com` at it.
2. As root, install `git`, clone the repository to `/srv/authoritymax`, and run the bootstrap
   script:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/authoritymax/authoritymax-dist.git /srv/authoritymax
cd /srv/authoritymax
sudo bash infra/contabo/bootstrap-control-plane.sh
```

   It installs Docker CE from `download.docker.com` for `trixie`, applies
   `infra/compose/harden-host.sh` for the `deploy` user, installs the backup timer, runs
   `infra/dedicated-host/setup-control-plane.sh` (WireGuard `wg0`, the peer-sync timer, and the two
   `DEDICATED_HOST_WG_*` values printed at the end), and installs `deploy-main` — the exact command
   CI's `deploy-production` job runs over SSH to ship a new revision. It does not create `.env` or
   start the stack; you supply production values first.
3. Create `/srv/authoritymax/.env` with the values from [Public single-VM
   deployment](#public-single-vm-deployment) above, plus:

```env
SANDBOX_PROVIDER=dedicated-host
COMPUTE_HOST_PROVIDER=contabo
CONTABO_CLIENT_ID=
CONTABO_CLIENT_SECRET=
CONTABO_API_USER=
CONTABO_API_PASSWORD=
CONTABO_PRODUCT_ID=
DEDICATED_HOST_WG_PUBLIC_KEY=      # printed by setup-control-plane.sh
DEDICATED_HOST_WG_ENDPOINT=        # printed by setup-control-plane.sh
DEDICATED_HOST_IMAGE_REPOSITORY=ghcr.io/authoritymax/authoritymax-dist
DEDICATED_HOST_IMAGE_TAG=edge
```

   See `.env.example`'s "Dedicated hosts" block and [docs/dedicated-hosts.md](./dedicated-hosts.md)
   for the full variable list, including how to look up `CONTABO_PRODUCT_ID` and
   `CONTABO_IMAGE_ID` with `pnpm tsx scripts/contabo-catalog.ts`.

   If no public `computer` and `supervisor` images exist yet, `infra/dedicated-host/setup-tunnel-registry.sh`
   serves them from the control plane over the tunnel instead — see [Serving images from the control
   plane](./dedicated-hosts.md#serving-images-from-the-control-plane-no-public-registry).
4. Start the stack, then verify it. The clone above is the distribution repository, which has no
   application source, so set the published tags in `.env` and pull rather than build:

```env
AUTHORITYMAX_IMAGE_TAG=latest
AUTHORITYMAX_UPDATER_IMAGE_TAG=latest
```

```bash
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml pull
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml \
  up -d --wait --pull missing
curl --fail https://app.example.com/health
```

   From a source checkout instead, leave `AUTHORITYMAX_IMAGE_TAG=local` and replace the `pull` with
   `build --build-arg GIT_SHA=$(git rev-parse HEAD)`; the `up` line is the same.

   The first registered user becomes the deployment owner. Because every signup provisions a
   billed Contabo VPS, keep `SIGNUP_ALLOWLIST` tight and consider setting
   `DEDICATED_HOST_MAX_HOSTS` before opening registration.

Once the control plane is live, CI's `deploy-production` job ships new revisions by running
`deploy-main` over SSH as the `deploy` user — the same command `infra/contabo/deploy-main.sh`
installs during bootstrap.

## Restore

```bash
./scripts/restore.sh backups/<stamp>
```

Rebuilding a control plane that runs dedicated hosts: unpack `wireguard.tar.gz` from the snapshot
into `/etc` **before** running `infra/contabo/bootstrap-control-plane.sh` or
`infra/dedicated-host/setup-control-plane.sh`. Both generate a key pair only when
`/etc/wireguard/wg0.conf` is absent, so restoring first preserves the original identity and the
existing hosts reconnect on their own. Run them first and the new host gets a new public key that
no already-provisioned host will ever accept — those hosts are then unreachable for good, since the
control plane's key is baked into their cloud-init at creation.

```bash
tar -xzf /var/backups/authoritymax/<stamp>/wireguard.tar.gz -C /etc
```

## Upgrade

A Compose deployment on a published release tag upgrades by moving that tag:

```bash
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml pull api worker web
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml \
  up -d --wait --pull missing api worker web
```

A deployment on the default `local` tag has no registry to pull from, so it upgrades by rebuilding
the checkout instead:

```bash
git pull
GIT_SHA=$(git rev-parse HEAD) docker compose --env-file .env -f infra/compose/docker-compose.prod.yml \
  up -d --wait --pull missing --build api worker web
```

`up --wait` does not report success until the new API is healthy and the worker and web containers
are running. The API's start command runs `prisma migrate deploy` before it serves, so migration
failure keeps health red. A failed CLI recreate does not auto-roll back; recover with the previous
`AUTHORITYMAX_IMAGE_TAG` (or rebuild `local`) and `up -d --wait --pull missing`.

The updater sidecar has its own image and tag so an update never recreates the process performing
it. Move it deliberately by setting `AUTHORITYMAX_UPDATER_IMAGE_TAG` to the full `sha-<commit>` tag, then
running `docker compose … pull updater && docker compose … up -d --wait --pull missing updater`.
Sidecar `/apply` and `/rollback` recover a failed recreate by redeploying the previously cached
image when possible; if that also fails, they report a possible mixed-version runtime.

Source checkouts (not Compose) still upgrade the old way: pull, rebuild with
`GIT_SHA=$(git rev-parse HEAD)`, run `pnpm --filter @authoritymax/db migrate`, then restart API and worker.
Product contracts stay compatible across cloud and self-hosted.

### Published images and tags

`.github/workflows/publish-server-image.yml` publishes into the public distribution namespace,
`ghcr.io/${DIST_REPOSITORY}/…`, because the source repository is private and packages inherit the
visibility of the repository they are linked to:

| Image | Contents |
| --- | --- |
| `ghcr.io/authoritymax/authoritymax-dist/app` | api, worker, and web — one image, three commands |
| `ghcr.io/authoritymax/authoritymax-dist/updater` | the updater sidecar, plus the Docker CLI |
| `ghcr.io/authoritymax/authoritymax-dist/computer` | the Debian 13 desktop a bot drives |
| `ghcr.io/authoritymax/authoritymax-dist/supervisor` | the sandbox supervisor a dedicated host runs |

Two settings on the private repository control this, and an operator of the official deployment
never changes them:

| Setting | Kind | Purpose |
| --- | --- | --- |
| `DIST_REPO_TOKEN` | secret | Fine-grained token with **Contents: write** on the distribution repository and org **write:packages**. `GITHUB_TOKEN` cannot write to another repository. |
| `DIST_REPOSITORY` | variable | Overrides the destination; defaults to `authoritymax/authoritymax-dist`. |

Pull-request builds validate the images without pushing and never see that secret. If you deploy
from your own fork, set `AUTHORITYMAX_IMAGE` and `AUTHORITYMAX_UPDATER_IMAGE` to your namespace —
your CI cannot publish into someone else's.

| Tag | Published on | Moves? |
| --- | --- | --- |
| `local` | nothing — built locally by `up --build` | rebuilt in place |
| `local-<full-commit>` | nothing — built on the server by a fork update | never |
| `vX.Y.Z`, `vX.Y` | release tags | conventionally no / on patch releases |
| `latest` | stable `vX.Y.Z` tags only (not prereleases) | yes, to the newest stable release |
| `sha-<full-commit>` | every push and manual run | source-addressed; used by the updater sidecar |
| `edge` | pushes to main | yes, to the newest main build |

The updater resolves the newest stable `vX.Y.Z` source tag but deploys its `sha-<full-commit>` image,
not `latest` or a moving minor tag. A registry tag is not an OCI digest and GHCR package writers can
replace it, so the trust boundary remains this repository's publishing credentials. The workflow
reduces that boundary by using SHA-pinned actions, read-only pull-request jobs, digest-pinned base
images, SBOM/provenance output, and a GitHub build attestation. GitHub persists attestations for a
private source repository only on a paid plan; a fork publishing from a free-plan organization sets the
`IMAGE_ATTESTATIONS` repository variable to `false` to skip that one step and keep the rest. Operators
who require registry-level content addressing can pin `AUTHORITYMAX_IMAGE` outside the automatic updater
to a verified digest.

Rollback never contacts the registry: it redeploys the previous tag from the local Docker cache,
so a later tag move cannot change rollback content. Do not prune the previous application image
until the next update has been accepted. If it is missing, rollback fails closed instead of pulling
new content under an old tag.

To populate the registry the first time, run the workflow manually (`workflow_dispatch`) or push a
`v*` tag. A manual run produces `sha-<full-commit>`; only a stable `vX.Y.Z` tag (no prerelease
suffix) produces `latest`, and any `v*` tag produces semver tags. The updater ignores prereleases
and refuses the official path until a stable `vX.Y.Z` exists.

### Updater sidecar

Compose production deployments offer an opt-in `updater` profile on a private `control` network.
Normal deployments do not start it or require its credential. To enable it, set a dedicated
`AUTHORITYMAX_UPDATER_TOKEN` and explicitly start the profile:

```bash
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml \
  --profile updater up -d --build updater
```

It exposes `/health`, `/state`, `/plan`, `/apply`, and `/rollback` at `http://updater:7092` with
`AUTHORITYMAX_UPDATER_TOKEN`. Operator CLI upgrades above do not need it; the sidecar is for automated
apply/rollback over that private HTTP API.

The API cannot update itself — its image has no `.git`, and nothing inside the container would
restart it — so the work happens in a separate `updater` container that outlives the recreate:

- *Official repository:* resolves the newest stable release and its source commit with
  `git ls-remote --tags`, pins the corresponding full `sha-<commit>` image tag in `.env`, keeps the
  outgoing tag in `AUTHORITYMAX_IMAGE_TAG_PREVIOUS`, explicitly pulls the new image, then runs
  `up -d --wait --pull never`. No build runs on the server.
- *Fork (Advanced):* a fork has no published images, so the sidecar fast-forwards the checkout in
  `AUTHORITYMAX_DEPLOY_DIR` and runs `up -d --build`. This builds on the server and takes minutes rather
  than seconds. Point it only at a fork you control and have reviewed — the sidecar runs that
  Compose file through a root-equivalent Docker socket.

Updates and rollbacks run one at a time. A failed pull leaves running services alone; a failed recreate restores the previous environment
pin and attempts to redeploy the cached previous image. A failed fork build also restores the
pre-update branch and commit (including when checkout succeeded but merge did not) so a later
manual `--build` cannot deploy the rejected or unintended revision. Database migrations are not
reversed. The sidecar never recreates itself, never touches Postgres or Caddy, and never runs
migrations — that ordering belongs to the API start command.

Only `https://` and `ssh://` git remotes are accepted. Merges are fast-forward only. A dirty or
untracked source tree fails closed before anything runs (the application Dockerfile uses `COPY . .`).

### The deploy directory must be one path

`AUTHORITYMAX_DEPLOY_DIR` is bind-mounted into the updater at the same path it is read from
(`${AUTHORITYMAX_DEPLOY_DIR}:${AUTHORITYMAX_DEPLOY_DIR}`), and that is load-bearing rather than tidy. Production
Compose defaults both sides to `/srv/authoritymax`; set the variable for any other layout. When the
updater runs `docker compose -p <project> --file $AUTHORITYMAX_DEPLOY_DIR/infra/compose/docker-compose.prod.yml up -d`,
the Compose CLI *inside* the container expands this file's relative bind mounts — `../../.env`,
`./Caddyfile.prod` — against that path and hands the results to the daemon. The daemon has to be
able to resolve the same strings, or it silently creates empty directories where your `.env` and
Caddyfile should be. Compose makes the effective `-p` value available for interpolation but does
not automatically put it in a container's environment, so the production file explicitly assigns
`COMPOSE_PROJECT_NAME` to the updater. A standalone sidecar can instead set
`AUTHORITYMAX_COMPOSE_PROJECT_NAME`; the final fallback is `authoritymax-prod`. Without that propagation, a
stack started with `-p something-else` would be left alone while a second project with a new empty
Postgres volume came up beside it.

The value therefore has to be the path **the daemon** sees, which is not always the path your shell
sees:

- **Linux.** The daemon shares the host filesystem, so the checkout path is the answer:
  `/srv/authoritymax` is the default and supported production layout. Set `AUTHORITYMAX_DEPLOY_DIR` explicitly
  when the checkout is elsewhere.
- **Docker Desktop (Windows/macOS).** The daemon runs in a VM that mounts your drive somewhere else.
  On Windows, `C:` appears at `/run/desktop/mnt/host/c`, so a checkout at `C:\Users\you\authoritymax` is
  `AUTHORITYMAX_DEPLOY_DIR=/run/desktop/mnt/host/c/Users/you/authoritymax`. Host Git may use `core.autocrlf=true`; the updater ignores CR-only diffs so that does not block `/apply`. Verify the mount before deploying:

```bash
docker compose --env-file .env -f infra/compose/docker-compose.prod.yml \
  --profile updater run --rm updater git -C "$AUTHORITYMAX_DEPLOY_DIR" log --oneline -1
```

  That must print your checkout's HEAD. The two tempting wrong answers both fail: a native Windows
  path is rejected by the daemon (`mount denied: … too many colons`, because the drive letter's
  colon collides with the bind-mount separator), and `/mnt/c/...` fails *silently* — the container
  starts, the mount is an empty directory, and the updater simply reports no checkout.

### The updater's privileges

The updater holds the Docker socket, which is root-equivalent on the host. It is scoped as narrowly
as that allows:

- No `ports`, so nothing is published on the host.
- Only on the dedicated `control` network shared with the API. Caddy is not attached, so the
  reverse proxy has no route to the updater.
- Every route except `/health` requires the shared bearer token, compared in constant time.
- The process environment carries only updater settings (`AUTHORITYMAX_UPDATER_TOKEN`, deploy path,
  image name, project name). Application secrets stay in the bind-mounted `.env` that Compose
  reads for interpolation; they are not loaded into this container.
- The Docker CLI lives only in the updater image. The api, worker, and web containers keep
  `cap_drop: ALL` and no socket.

Enabling the `updater` profile requires `AUTHORITYMAX_UPDATER_TOKEN` to be a dedicated random value (at
least 32 characters in production). It must differ from `BETTER_AUTH_SECRET` and
`SANDBOX_SUPERVISOR_TOKEN`. Leave the profile disabled if you would rather not grant the capability.

## What “AuthorityMax Cloud” still needs

The product cannot be “pushed live” as a Vercel serverless app. Graphile Worker, Postgres `LISTEN`, Pi runs, and Docker computers need durable processes and a sandbox host.

To run a hosted product (same codebase):

1. Push `main` (this checkout may be ahead of GitHub).
2. Provision managed Postgres 16 and run `pnpm db:migrate`.
3. Run **API** and **worker** as always-on Node 22 services (Fly machines, a VM, ECS, k8s). Not lambda-style request handlers.
4. Persist and back up `DATA_DIR` (bot homes, browser profiles, artifacts). Today the concrete store is a local filesystem (`LocalAgentHomeStore`), so attach an AuthorityMax-owned durable volume shared by API and worker processes. The storage contract is separate from the computer-provider contract, but an object-storage implementation is not wired yet.
5. Choose computers: **`SANDBOX_PROVIDER=e2b`**, `daytona`, or `box` with the matching provider key for a public or multi-user production service. Each Team or Private Computer reconnects to its sandbox id (`providerRef`), while workspace state is checkpointed outside the provider at run completion, explicit stop, and idle suspension. If that sandbox is gone—or the deployment changes providers—the replacement is hydrated from AuthorityMax's copy. A run only provisions its computer once a computer-bound tool runs or the bot requests a takeover; chat and integration turns never boot one. Idle computers pause after `SANDBOX_IDLE_MS` (default 10 minutes) and resume on the next message or Take control; Box computers use the shorter `SANDBOX_IDLE_MS_BOX` (default 3 minutes) to limit per-second billing, and dedicated-host computers use `SANDBOX_IDLE_MS_DEDICATED_HOST` (defaults to `SANDBOX_IDLE_MS`). All three have a 30-second floor: anything below it is treated as unset and the default applies, so a computer is never torn down mid-boot. Docker remains the local and trusted single-machine default.
6. A Hetzner CX22 (2 vCPU / 4 GB) is enough for API + worker + Postgres when E2B owns the desktops. 2 GB works for a quiet box; 8 GB is only needed if you also run Docker computers on that same machine.
7. Set public HTTPS `WEB_ORIGIN` / `BETTER_AUTH_URL` / `API_URL`, secrets, and an OpenRouter (or other Pi) deployment key if you want to skip per-user model keys.
8. Put the web app behind the same origin as `/api` and `/rpc` (Vite preview proxy, or a reverse proxy). Docker noVNC connections use short-lived signed `/novnc/*` capabilities; do not replace that route with an unrestricted port proxy.
9. Deploy `apps/www` to your public website and point `app.example.com` (or similar) at the product origin.
10. Turn on `SIGNUP_ALLOWLIST` until you want open registration. There is no AuthorityMax-managed model billing in version 1 — users bring keys.

Expo / desktop installers are clients of that origin. Both default to the hosted service (`https://bots.authoritymax.ai`) so a fresh install connects with no configuration, and web deploys reach installed desktop apps immediately because the desktop app loads the web UI straight from the server.

Self-hosters point the clients at their own origin:

- **Desktop.** Open **Change AuthorityMax Server…** (⌘/Ctrl+Shift+K), choose **Custom server URL**, and enter your origin. `AUTHORITYMAX_WEB_URL` overrides the target for a single launch without changing the saved choice. Set `AUTHORITYMAX_BUNDLED_RENDERER=1` to serve the web build packaged inside the app instead of loading it from the server (useful for fully offline or air-gapped installs); it is off by default.
- **Mobile.** On the sign-in screen, tap **Use a custom server** and enter the same HTTPS origin as `WEB_ORIGIN` (for example `https://app.example.com`). Store builds default to `EXPO_PUBLIC_API_URL` when it is set at build time, otherwise the hosted service; the in-app setting is a per-device override. Changing the server signs the device out of any previous session.
