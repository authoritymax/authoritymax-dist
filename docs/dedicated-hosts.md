# Dedicated hosts

A dedicated host is a cloud VPS that AuthorityMax provisions for one account. That account's bot
computers run there instead of on the control plane, using the same Debian 13 computer image and
sandbox supervisor as a local Docker deployment. The control plane keeps the API, worker, Postgres,
and the web app; each dedicated host only runs computers.

The VPS vendor sits behind the `ComputeHostProvider` contract. Contabo is the first
implementation; nothing outside `packages/adapters/src/contabo-*.ts` knows its API.

## How it works

```text
control plane (operator VPS)                         dedicated host (one per account)
────────────────────────────                         ────────────────────────────────
api / worker ── wg0 10.77.0.1 ══ WireGuard (UDP 51820) ══ wg0 10.77.x.y ── supervisor :7091
web (noVNC proxy) ─────────────────────────────────────────────────────── computer :608x
authoritymax-wg-sync (host timer) ◀── DATA_DIR/wireguard/peers/*.conf
```

1. **Signup.** When a user registers, the API creates their personal workspace and, if dedicated
   hosts are enabled, a `DedicatedHost` row in `pending` plus a `dedicated-host.provision` job.
2. **Provision.** The worker allocates a tunnel address from `DEDICATED_HOST_TUNNEL_CIDR`,
   generates a WireGuard key pair and a supervisor token for the host, renders cloud-init user
   data, and asks the compute-host provider for a VM. The tunnel peer is written to
   `DEDICATED_HOST_PEER_DIR` so the control-plane host can add it to `wg0`. The job polls the
   provider, then the supervisor's `/health` endpoint through the tunnel, until the host is `ready`.
3. **Use.** With `SANDBOX_PROVIDER=dedicated-host`, every computer call for a workspace is routed to
   that workspace's supervisor over the tunnel. The Docker provider, the supervisor, workspace
   checkpoints, and the signed noVNC screen proxy all work unchanged because the host lives in a
   private range. Until the host is ready, computer actions fail with
   "Your dedicated computer is still being set up."
4. **Delete.** Deleting an account stops and cancels the hosts of the workspaces that user solely
   owned and removes their tunnel peers. A host is released only *after* its workspace is actually
   deleted — the reconciler sweeps orphaned hosts — never before, so a delete that fails partway
   cannot cancel the VPS of an account that still exists.

Host status is visible under **Account settings** on web, and available to every client through
`dedicatedHost.status` / `dedicatedHost.retry` in the shared RPC contract.

### What runs on a dedicated host

cloud-init installs WireGuard and Docker CE, writes `wg0.conf`, and starts one Compose service —
the published `supervisor` image on the host network bound to the tunnel address — which pulls the
published `computer` image and creates computer containers on demand. UFW denies everything inbound
except WireGuard, allows the supervisor port and the noVNC range only on `wg0`, and allows SSH only
when `DEDICATED_HOST_ALLOW_SSH=1`. Computer containers publish their screen ports on the tunnel
address only, so Docker's own firewall rules cannot expose them publicly.

Bot homes live under `/data` on the host. Checkpoints still flow back to the control plane's
`DATA_DIR` at the usual boundaries, so a lost host is rebuilt from AuthorityMax's copy.

## Control-plane setup

Run once on the control-plane host, as root, from the checkout:

```bash
sudo bash infra/dedicated-host/setup-control-plane.sh
```

It installs WireGuard, creates `wg0` (`10.77.0.1/16`, UDP 51820), opens the port in UFW, installs
`/usr/local/sbin/authoritymax-wg-sync` with a systemd timer that applies new peers every 30
seconds, and prints two lines for `.env`:

```env
DEDICATED_HOST_WG_PUBLIC_KEY=…
DEDICATED_HOST_WG_ENDPOINT=<control-plane-ip>:51820
```

`infra/contabo/bootstrap-control-plane.sh` runs this as part of a fresh Contabo installation; see
[Self-hosting → Contabo VPS](./self-host.md#contabo-vps-debian-13-or-ubuntu-22042404).

The peer sync script reads peer files from the `appdata` Compose volume
(`<project>_appdata/wireguard/peers`), or from `AUTHORITYMAX_PEER_DIR` when set. Each file holds one
public key and one `/32`; anything else is ignored with a warning.

## Configuration

These two must be set together: `COMPUTE_HOST_PROVIDER` is ignored, and no VPS is ordered, unless
`SANDBOX_PROVIDER=dedicated-host` — otherwise every signup would bill a host nothing routes to.

```env
SANDBOX_PROVIDER=dedicated-host
COMPUTE_HOST_PROVIDER=contabo            # contabo | fake | empty (dedicated hosts disabled)

CONTABO_CLIENT_ID=
CONTABO_CLIENT_SECRET=
CONTABO_API_USER=
CONTABO_API_PASSWORD=
CONTABO_REGION=EU
CONTABO_PRODUCT_ID=                      # product id of the 8 GB Cloud VPS tier
CONTABO_IMAGE_ID=                        # optional; defaults to the standard Debian 13 image
CONTABO_SSH_KEY_SECRET_IDS=              # optional comma-separated Contabo secret ids

DEDICATED_HOST_WG_PUBLIC_KEY=
DEDICATED_HOST_WG_ENDPOINT=
DEDICATED_HOST_TUNNEL_CIDR=10.77.0.0/16
DEDICATED_HOST_PEER_DIR=                 # default $DATA_DIR/wireguard/peers
DEDICATED_HOST_IMAGE_REPOSITORY=ghcr.io/authoritymax/authoritymax-dist
DEDICATED_HOST_IMAGE_TAG=edge
DEDICATED_HOST_ALLOW_SSH=0
DEDICATED_HOST_SSH_AUTHORIZED_KEYS=       # optional comma-separated public keys for operator SSH
DEDICATED_HOST_MAX_HOSTS=
DEDICATED_HOST_PROVISION_TIMEOUT_MS=1800000
```

Contabo's API credential is the client id and secret from the Customer Control Panel plus the API
user and API password. Product and image identifiers are not stable public constants; look them up
once and put them in `.env`:

```bash
pnpm tsx scripts/contabo-catalog.ts --name debian
```

lists the standard images the credential can see. `CONTABO_PRODUCT_ID` is the id of the 8 GB Cloud
VPS tier in your Contabo catalog (product ids look like `V…`).

`DEDICATED_HOST_IMAGE_REPOSITORY` / `DEDICATED_HOST_IMAGE_TAG` select the published `computer` and
`supervisor` images the host pulls. A fork publishes into its own GHCR namespace; point the
repository there. The packages must be pullable anonymously (public) or the host cannot start.

`COMPUTE_HOST_PROVIDER=fake` provisions in-memory hosts for development and tests; nothing is
created anywhere.

### Serving images from the control plane (no public registry)

GHCR is the default: hosts pull the public `computer` and `supervisor` images from
`authoritymax-dist`. Use this alternative only when no published images exist yet — a private fork,
or a control plane standing up before CI has ever run.

```bash
sudo bash infra/dedicated-host/setup-tunnel-registry.sh
```

Run it on the control plane after `setup-control-plane.sh`. It starts a `registry:2` container
published **only** on the tunnel address, builds both images from the checkout, pushes them, and
prints the two values to set:

```env
DEDICATED_HOST_IMAGE_REPOSITORY=10.77.0.1:5000/authoritymax
DEDICATED_HOST_IMAGE_TAG=local
```

`DEDICATED_HOST_CONTROL_PLANE_ADDRESS`, `REGISTRY_PORT`, `AUTHORITYMAX_DEPLOY_DIR`, and `IMAGE_TAG`
override the defaults. Re-run it after changing either image; the script is idempotent.

The registry speaks plain HTTP, so the control plane and every dedicated host get an
`insecure-registries` entry for that one tunnel address — added by merging into
`/etc/docker/daemon.json` here, and written into cloud-init on each host. Nothing is weakened for
any other registry, and the traffic never leaves WireGuard: the container is published on the
tunnel address rather than `0.0.0.0`, and UFW allows the port on `wg0` only. The registry is
unauthenticated, so reaching it at all requires the tunnel — check `docker port
authoritymax-registry` if you ever need to confirm what it is bound to.

Switching back to GHCR is just restoring `DEDICATED_HOST_IMAGE_REPOSITORY` and recreating `api` and
`worker`; hosts provisioned earlier keep pulling from wherever their cloud-init pointed them.

## Operations

- **Status.** `dedicated_hosts.status` moves `pending → provisioning → ready`; `error` keeps
  `last_error`. Retry from Account settings or `dedicatedHost.retry`; a retry creates a new VM and
  abandons the failed one after stopping and cancelling it. A host that ends in `error` is
  **stopped, not cancelled**, so you can still inspect it — which means it keeps billing until it is
  retried or the account is deleted. List them with:

  ```sql
  SELECT id, workspace_id, last_error FROM dedicated_hosts WHERE status = 'error';
  ```
- **Stuck provisioning.** A host still `provisioning` after `DEDICATED_HOST_PROVISION_TIMEOUT_MS`
  becomes `error`. The job reconciler re-enqueues hosts that stop making progress, so a worker
  restart does not strand them.
- **Image updates.** Hosts pull images only at bootstrap. To roll a new computer image, publish it,
  then on each host run `docker compose -f /etc/authoritymax/docker-compose.yml pull && docker
  compose -f /etc/authoritymax/docker-compose.yml up -d` (SSH must be enabled) or reprovision.
- **Peers.** `wg show wg0` on the control plane lists connected hosts. A host that never handshakes
  usually means the cloud-init run failed; enable SSH for the next host and read
  `/var/log/cloud-init-output.log`.
- **Cost.** Every signup creates a monthly-billed VPS. Keep `SIGNUP_ALLOWLIST` tight and set
  `DEDICATED_HOST_MAX_HOSTS` so a signup wave cannot exhaust the account. Contabo cancels at the end
  of the contract period; deprovisioning stops the instance immediately and files the cancellation.

## Security

- Supervisor and screen traffic never leave the WireGuard tunnel. Hosts expose only UDP 51820 (and
  SSH when enabled).
- The host's WireGuard private key and supervisor token are generated on the control plane, stored
  encrypted with `ENCRYPTION_KEY`, and delivered once inside cloud-init user data over the
  provider's HTTPS API.
- The control plane's `api` and `worker` containers keep `cap_drop: ALL`. Only the root-owned
  `authoritymax-wg-sync` timer changes `wg0`, and it accepts nothing from peer files except a public
  key and a single `/32`.
- Contabo credentials are deployment-wide secrets in `.env`; they are never stored in the database
  or written to logs.

## Limitations

- The control plane must run with `DATA_DIR=/data` (the production Compose default). The
  supervisor on a host only accepts a bot home under its own `/data/homes/<bot-id>`, and the API
  sends the path it uses locally, so the two must agree even though no filesystem is shared.
- One host per workspace; there is no pooling or sharing of hosts across accounts.
- Provisioning takes several minutes (VM creation plus Docker and image pulls). Accounts can sign
  in and configure bots meanwhile; computer actions wait for the host.
- Host disks are not backed up by AuthorityMax. Workspace checkpoints on the control plane are the
  durable copy.
