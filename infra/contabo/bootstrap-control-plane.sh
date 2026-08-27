#!/usr/bin/env bash

# Turn a fresh Debian 13 or Ubuntu 22.04/24.04 VPS into the AuthorityMax control plane: Docker CE,
# host hardening, the checkout at /srv/authoritymax, the backup timer, the WireGuard control plane
# for dedicated hosts, and the deploy-main entry point CI calls over SSH.
#
# Run as root on a box you have just created. Every step is idempotent, so re-running after a
# failure resumes rather than duplicates. It deliberately does not create .env or start the stack;
# the operator supplies production values first.
#
# Environment:
#   DEPLOY_USER                     unprivileged owner of the checkout (default: deploy)
#   DEPLOY_SSH_AUTHORIZED_KEYS      public keys for that user; defaults to root's authorized_keys
#   AUTHORITYMAX_REPO_URL           repository to clone
#   AUTHORITYMAX_GIT_REF            branch or tag to check out (default: main)
#   AUTHORITYMAX_DEPLOY_DIR         checkout location (default: /srv/authoritymax)

set -Eeuo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_DIR="${AUTHORITYMAX_DEPLOY_DIR:-/srv/authoritymax}"
# The distribution repository is public and carries the operator files plus the published image
# tags; the source repository is private and not what a control plane needs.
REPO_URL="${AUTHORITYMAX_REPO_URL:-https://github.com/authoritymax/authoritymax-dist.git}"
GIT_REF="${AUTHORITYMAX_GIT_REF:-main}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this as root on the target VPS" >&2
  exit 1
fi

# --- Platform check ---------------------------------------------------------

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot read /etc/os-release; this script targets Debian 13 or Ubuntu 22.04/24.04" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
case "${ID:-}" in
  debian)
    if [[ "${VERSION_ID:-}" != "13" ]]; then
      echo "Warning: expected Debian 13, found ${VERSION_ID:-unknown}; continuing" >&2
    fi
    CODENAME="${CODENAME:-trixie}"
    ;;
  ubuntu)
    if [[ "${VERSION_ID:-}" != "22.04" && "${VERSION_ID:-}" != "24.04" ]]; then
      echo "Warning: expected Ubuntu 22.04 or 24.04, found ${VERSION_ID:-unknown}; continuing" >&2
    fi
    ;;
  *)
    echo "This script targets Debian 13 or Ubuntu 22.04/24.04 (found ID=${ID:-unknown})" >&2
    exit 1
    ;;
esac
if [[ -z "${CODENAME}" ]]; then
  echo "Cannot determine VERSION_CODENAME from /etc/os-release" >&2
  exit 1
fi
# Docker publishes separate repositories per distribution; both live under the same host.
DOCKER_REPO="https://download.docker.com/linux/${ID}"
DOCKER_LIST="/etc/apt/sources.list.d/docker.list"

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing base packages"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg git

# --- Docker CE --------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker CE for ${ID} ${CODENAME}"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --proto '=https' --tlsv1.2 "${DOCKER_REPO}/gpg" \
    -o /etc/apt/keyrings/docker.asc.tmp
  # Never point apt at a keyring that is missing or is not actually a key.
  if ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /etc/apt/keyrings/docker.asc.tmp; then
    rm -f /etc/apt/keyrings/docker.asc.tmp
    echo "Downloaded Docker signing key is not a PGP public key" >&2
    exit 1
  fi
  mv /etc/apt/keyrings/docker.asc.tmp /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] %s %s stable\n' \
    "$(dpkg --print-architecture)" "${DOCKER_REPO}" "${CODENAME}" >"${DOCKER_LIST}"
  apt-get update
  apt-get install -y --no-install-recommends \
    containerd.io \
    docker-buildx-plugin \
    docker-ce \
    docker-ce-cli \
    docker-compose-plugin
fi

# A Docker that came with the image — common on Ubuntu — often has no Compose v2 plugin, and the
# whole deployment is `docker compose`. Prefer the Docker repository when this host uses it.
if ! docker compose version >/dev/null 2>&1; then
  echo "==> Installing the Docker Compose plugin"
  if [[ -f "${DOCKER_LIST}" ]]; then
    apt-get install -y --no-install-recommends docker-compose-plugin
  elif [[ "${ID}" == "ubuntu" ]]; then
    apt-get install -y --no-install-recommends docker-compose-v2
  else
    echo "docker compose is missing and ${DOCKER_LIST} is not configured" >&2
    exit 1
  fi
  docker compose version >/dev/null
fi

systemctl enable --now docker

# --- Deploy user ------------------------------------------------------------

if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
  echo "==> Creating the ${DEPLOY_USER} user"
  adduser --disabled-password --gecos "" "${DEPLOY_USER}"
fi
usermod -aG docker "${DEPLOY_USER}"

install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
authorized_keys="/home/${DEPLOY_USER}/.ssh/authorized_keys"
if [[ -n "${DEPLOY_SSH_AUTHORIZED_KEYS:-}" ]]; then
  printf '%s\n' "${DEPLOY_SSH_AUTHORIZED_KEYS}" >"${authorized_keys}"
elif [[ ! -s "${authorized_keys}" && -s /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "${authorized_keys}"
fi
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${authorized_keys}" 2>/dev/null || true
chmod 600 "${authorized_keys}" 2>/dev/null || true

# Hardening disables root and password logins, so this is the last chance to catch a lockout.
if [[ ! -s "${authorized_keys}" ]]; then
  echo "Refusing to harden: ${authorized_keys} is empty. Set DEPLOY_SSH_AUTHORIZED_KEYS and re-run." >&2
  exit 1
fi

# --- Checkout ---------------------------------------------------------------

# git refuses to work in a repository owned by another user ("detected dubious ownership"), so the
# checkout is created and updated as its owner rather than as root. HOME has to come along: root's
# home is 0700, and git aborts when it cannot read the global config it is pointed at.
DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
DEPLOY_HOME="${DEPLOY_HOME:-/home/${DEPLOY_USER}}"
as_deploy() {
  runuser -u "${DEPLOY_USER}" -- env "HOME=${DEPLOY_HOME}" "$@"
}

install -d -m 755 "$(dirname "${DEPLOY_DIR}")"
install -d -m 755 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${DEPLOY_DIR}"
# A checkout left by an interrupted run — or by an earlier version of this script, which cloned as
# root — is handed back before git touches it, so re-running always resumes instead of aborting.
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_DIR}"

if [[ -d "${DEPLOY_DIR}/.git" ]]; then
  echo "==> Updating ${DEPLOY_DIR}"
  as_deploy git -C "${DEPLOY_DIR}" fetch --tags --prune origin
  as_deploy git -C "${DEPLOY_DIR}" pull --ff-only
else
  echo "==> Cloning ${REPO_URL} into ${DEPLOY_DIR}"
  as_deploy git clone "${REPO_URL}" "${DEPLOY_DIR}"
  as_deploy git -C "${DEPLOY_DIR}" checkout "${GIT_REF}"
fi

# --- Docker daemon configuration --------------------------------------------

if [[ ! -f /etc/docker/daemon.json ]]; then
  echo "==> Applying the Docker daemon configuration"
  install -d -m 755 /etc/docker
  install -m 644 "${DEPLOY_DIR}/infra/compose/docker-daemon.json" /etc/docker/daemon.json
  systemctl restart docker
fi

# --- Hardening --------------------------------------------------------------

echo "==> Hardening the host"
DEPLOY_USER="${DEPLOY_USER}" bash "${DEPLOY_DIR}/infra/compose/harden-host.sh"

# --- Backups ----------------------------------------------------------------

echo "==> Installing the nightly backup timer"
install -m 755 "${DEPLOY_DIR}/infra/compose/backup-prod.sh" /usr/local/sbin/authoritymax-backup
install -m 644 "${DEPLOY_DIR}/infra/systemd/authoritymax-backup.service" \
  /etc/systemd/system/authoritymax-backup.service
install -m 644 "${DEPLOY_DIR}/infra/systemd/authoritymax-backup.timer" \
  /etc/systemd/system/authoritymax-backup.timer
install -d -m 755 /etc/systemd/system/authoritymax-backup.service.d
printf '[Service]\nEnvironment=AUTHORITYMAX_DEPLOY_DIR=%s\n' "${DEPLOY_DIR}" \
  >/etc/systemd/system/authoritymax-backup.service.d/10-deploy-dir.conf
systemctl daemon-reload
systemctl enable --now authoritymax-backup.timer

# --- Dedicated host control plane -------------------------------------------

echo "==> Setting up the WireGuard control plane"
bash "${DEPLOY_DIR}/infra/dedicated-host/setup-control-plane.sh"

# --- Deploy entry point -----------------------------------------------------

install -m 755 "${DEPLOY_DIR}/infra/contabo/deploy-main.sh" /usr/local/bin/deploy-main

# The distribution checkout has no application source, so it deploys the published images; a source
# checkout builds them. SOURCE_COMMIT is what the sync writes, and what deploy-main keys off too.
if [[ -f "${DEPLOY_DIR}/SOURCE_COMMIT" ]]; then
  IMAGE_TAG_STEP="  2. Set the published image tags in .env — there is no application source here to build:
       AUTHORITYMAX_IMAGE_TAG=latest
       AUTHORITYMAX_UPDATER_IMAGE_TAG=latest
     then: docker compose --env-file .env -f infra/compose/docker-compose.prod.yml pull"
else
  IMAGE_TAG_STEP="  2. docker compose --env-file .env -f infra/compose/docker-compose.prod.yml \\
       build --build-arg GIT_SHA=\"\$(git rev-parse HEAD)\""
fi

cat <<NEXT

Bootstrap complete. Remaining steps, as ${DEPLOY_USER} in ${DEPLOY_DIR}:

  1. cp .env.example .env && chmod 600 .env
     Fill in production values: AUTHORITYMAX_HOST, POSTGRES_PASSWORD, BETTER_AUTH_SECRET,
     ENCRYPTION_KEY, SANDBOX_PROVIDER=dedicated-host, COMPUTE_HOST_PROVIDER=contabo, the CONTABO_*
     credentials, and the two DEDICATED_HOST_WG_* values printed above.
${IMAGE_TAG_STEP}
  3. docker compose --env-file .env -f infra/compose/docker-compose.prod.yml up -d --wait --pull missing
  4. curl --fail "https://\$AUTHORITYMAX_HOST/health"

Later deploys run /usr/local/bin/deploy-main, which is what CI invokes over SSH.
NEXT
