#!/usr/bin/env bash

# Serve the computer and supervisor images to dedicated hosts from the control plane itself, over
# the WireGuard tunnel.
#
# The normal path is GHCR: hosts pull public images from the distribution repository. This script
# is the fallback for a deployment that has no published images yet — a private fork, or a control
# plane standing up before CI has ever run. It starts a registry that listens ONLY on the tunnel
# address, builds both images from this checkout, and pushes them there.
#
# The registry speaks plain HTTP, so each daemon that talks to it needs an `insecure-registries`
# entry. That is narrow on purpose: the entry names one tunnel address, and nothing outside
# WireGuard can reach it, so the traffic never crosses a network the tunnel does not already carry.
#
# Run as root on the control plane, after setup-control-plane.sh has brought wg0 up.
#
# Environment:
#   DEDICATED_HOST_CONTROL_PLANE_ADDRESS   tunnel address to serve on (default: 10.77.0.1)
#   REGISTRY_PORT                          port to serve on (default: 5000)
#   AUTHORITYMAX_DEPLOY_DIR                checkout to build from (default: /srv/authoritymax)
#   IMAGE_TAG                              tag to build and push (default: local)

set -Eeuo pipefail

ADDRESS="${DEDICATED_HOST_CONTROL_PLANE_ADDRESS:-10.77.0.1}"
PORT="${REGISTRY_PORT:-5000}"
DEPLOY_DIR="${AUTHORITYMAX_DEPLOY_DIR:-/srv/authoritymax}"
IMAGE_TAG="${IMAGE_TAG:-local}"
CONTAINER="authoritymax-registry"
VOLUME="authoritymax-registry"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this as root on the control plane" >&2
  exit 1
fi

if [[ ! "${PORT}" =~ ^[0-9]{1,5}$ ]] || ((PORT < 1 || PORT > 65535)); then
  echo "REGISTRY_PORT must be a port number, got ${PORT}" >&2
  exit 1
fi
if [[ ! "${IMAGE_TAG}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "IMAGE_TAG must be a valid Docker tag, got ${IMAGE_TAG}" >&2
  exit 1
fi
if [[ ! -d "${DEPLOY_DIR}/infra/sandboxes/computer" ]]; then
  echo "No checkout at ${DEPLOY_DIR}: set AUTHORITYMAX_DEPLOY_DIR" >&2
  exit 1
fi

REGISTRY="${ADDRESS}:${PORT}"

# --- The tunnel has to be up ------------------------------------------------

if ! ip link show wg0 >/dev/null 2>&1; then
  echo "wg0 is not up. Run infra/dedicated-host/setup-control-plane.sh first." >&2
  exit 1
fi
# Publishing on the tunnel address only works if the address is actually assigned to it, and that
# is the whole security property here: the registry must never be reachable from the internet.
if ! ip -4 -oneline addr show dev wg0 | grep -qw "${ADDRESS}"; then
  echo "wg0 does not carry ${ADDRESS}." >&2
  echo "Set DEDICATED_HOST_CONTROL_PLANE_ADDRESS to the address in /etc/wireguard/wg0.conf." >&2
  exit 1
fi

# --- Trust the tunnel registry ----------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends python3
fi

# Merged rather than overwritten: daemon.json already carries the log, live-restore, and
# no-new-privileges settings from infra/compose/docker-daemon.json, and losing those would quietly
# undo the host hardening. Written through a temporary file so an interrupted run cannot leave a
# truncated daemon.json behind, which would stop Docker from starting at all.
daemon_state="$(python3 - "${REGISTRY}" <<'PYTHON'
import json
import os
import sys
from pathlib import Path

path = Path("/etc/docker/daemon.json")
entry = sys.argv[1]

data = {}
if path.exists() and path.read_text().strip():
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise SystemExit(f"{path} does not contain a JSON object")

registries = list(data.get("insecure-registries", []))
if entry in registries:
    print("unchanged")
    raise SystemExit(0)

registries.append(entry)
data["insecure-registries"] = sorted(set(registries))

path.parent.mkdir(parents=True, exist_ok=True)
temporary = path.with_suffix(".json.tmp")
temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
os.replace(temporary, path)
print("changed")
PYTHON
)"

if [[ "${daemon_state}" == "changed" ]]; then
  echo "==> Added ${REGISTRY} to /etc/docker/daemon.json; restarting Docker"
  systemctl restart docker
else
  echo "==> /etc/docker/daemon.json already trusts ${REGISTRY}"
fi

# --- Firewall ---------------------------------------------------------------

# Only on wg0: the registry is unauthenticated, so reaching it must require the tunnel.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow in on wg0 to any port "${PORT}" proto tcp comment 'Tunnel image registry' >/dev/null
fi

# --- Registry ---------------------------------------------------------------

publish="${ADDRESS}:${PORT}:5000"
existing="$(docker ps -a --filter "name=^${CONTAINER}$" --format '{{.Names}}')"
if [[ -n "${existing}" ]]; then
  # Recreate when the address or port moved; otherwise the container would still be published
  # somewhere else, possibly on every interface.
  current="$(docker inspect -f '{{range $p, $conf := .HostConfig.PortBindings}}{{range $conf}}{{.HostIp}}:{{.HostPort}}{{end}}{{end}}' "${CONTAINER}")"
  if [[ "${current}" != "${ADDRESS}:${PORT}" ]]; then
    echo "==> Recreating ${CONTAINER}: published on ${current:-nothing}, want ${ADDRESS}:${PORT}"
    docker rm -f "${CONTAINER}" >/dev/null
    existing=""
  fi
fi

if [[ -z "${existing}" ]]; then
  echo "==> Starting ${CONTAINER} on ${REGISTRY}"
  docker run -d \
    --name "${CONTAINER}" \
    --restart unless-stopped \
    -p "${publish}" \
    -v "${VOLUME}:/var/lib/registry" \
    registry:2 >/dev/null
else
  docker start "${CONTAINER}" >/dev/null
  echo "==> ${CONTAINER} already serving ${REGISTRY}"
fi

echo "==> Waiting for the registry"
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! curl -fsS --max-time 5 "http://${REGISTRY}/v2/" >/dev/null; then
  echo "The registry did not come up on ${REGISTRY}." >&2
  docker logs --tail 20 "${CONTAINER}" >&2 || true
  exit 1
fi

# --- Images -----------------------------------------------------------------

COMPUTER_IMAGE="${REGISTRY}/authoritymax/computer:${IMAGE_TAG}"
SUPERVISOR_IMAGE="${REGISTRY}/authoritymax/supervisor:${IMAGE_TAG}"

echo "==> Building ${COMPUTER_IMAGE}"
docker build -t "${COMPUTER_IMAGE}" "${DEPLOY_DIR}/infra/sandboxes/computer"

# The supervisor needs the whole workspace: its Dockerfile copies the shared packages it depends on.
echo "==> Building ${SUPERVISOR_IMAGE}"
docker build -f "${DEPLOY_DIR}/infra/sandboxes/supervisor/Dockerfile" -t "${SUPERVISOR_IMAGE}" "${DEPLOY_DIR}"

echo "==> Pushing"
docker push "${COMPUTER_IMAGE}"
docker push "${SUPERVISOR_IMAGE}"

for repository in computer supervisor; do
  if ! curl -fsS --max-time 10 "http://${REGISTRY}/v2/authoritymax/${repository}/tags/list" |
    grep -q "\"${IMAGE_TAG}\""; then
    echo "${repository}:${IMAGE_TAG} is not in the registry after pushing." >&2
    exit 1
  fi
  echo "==> ${REGISTRY}/authoritymax/${repository}:${IMAGE_TAG} is served"
done

echo
echo "Set these in ${DEPLOY_DIR}/.env, then recreate the api and worker services:"
echo
echo "DEDICATED_HOST_IMAGE_REPOSITORY=${REGISTRY}/authoritymax"
echo "DEDICATED_HOST_IMAGE_TAG=${IMAGE_TAG}"
