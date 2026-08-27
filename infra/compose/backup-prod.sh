#!/usr/bin/env bash
set -euo pipefail

# Keeps the historical default; hosts that use another layout (Compose defaults to
# /srv/authoritymax) pass AUTHORITYMAX_DEPLOY_DIR through the systemd unit.
PROJECT_DIR="${AUTHORITYMAX_DEPLOY_DIR:-/opt/authoritymax}"
COMPOSE_FILE="${PROJECT_DIR}/infra/compose/docker-compose.prod.yml"
ENV_FILE="${PROJECT_DIR}/.env"
BACKUP_ROOT="/var/backups/authoritymax"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAPSHOT_DIR="${BACKUP_ROOT}/${STAMP}"

install -d -m 700 "${BACKUP_ROOT}" "${SNAPSHOT_DIR}"

compose=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")

"${compose[@]}" exec -T postgres sh -c \
  'pg_dump --format=custom --no-owner --no-privileges -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  > "${SNAPSHOT_DIR}/authoritymax.dump"

"${compose[@]}" exec -T api tar -czf - -C /data . \
  > "${SNAPSHOT_DIR}/appdata.tgz"

artifacts=("${SNAPSHOT_DIR}/authoritymax.dump" "${SNAPSHOT_DIR}/appdata.tgz")

# The control-plane WireGuard identity. Every dedicated host pins this public key when it first
# boots and nothing re-keys it afterwards, so a control plane rebuilt without these files can never
# be reached by the hosts already running. The archive holds a private key: the snapshot is a secret.
if [[ -d /etc/wireguard ]]; then
  tar -czf "${SNAPSHOT_DIR}/wireguard.tar.gz" -C /etc wireguard
  chmod 600 "${SNAPSHOT_DIR}/wireguard.tar.gz"
  artifacts+=("${SNAPSHOT_DIR}/wireguard.tar.gz")
fi

"${compose[@]}" exec -T postgres pg_restore --list \
  < "${SNAPSHOT_DIR}/authoritymax.dump" >/dev/null
tar -tzf "${SNAPSHOT_DIR}/appdata.tgz" >/dev/null
if [[ -f "${SNAPSHOT_DIR}/wireguard.tar.gz" ]]; then
  tar -tzf "${SNAPSHOT_DIR}/wireguard.tar.gz" >/dev/null
fi

sha256sum "${artifacts[@]}" > "${SNAPSHOT_DIR}/SHA256SUMS"
chmod 600 "${SNAPSHOT_DIR}"/*

# Keep seven daily snapshots. BACKUP_ROOT is intentionally fixed above so this
# cleanup can never expand to an environment-controlled or broad path.
find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +6 -exec rm -rf -- {} +

echo "Verified AuthorityMax backup written to ${SNAPSHOT_DIR}"
