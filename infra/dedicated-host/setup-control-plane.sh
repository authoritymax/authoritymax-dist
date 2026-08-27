#!/usr/bin/env bash

# Prepare the control plane for dedicated hosts: a WireGuard interface every account VPS dials
# home to, plus the timer that applies the peer files the application writes.
#
# Safe to re-run. Existing keys and an existing wg0.conf are never rewritten, so re-running after a
# deployment change cannot invalidate the peers already configured on user hosts.

set -Eeuo pipefail

CONTROL_PLANE_ADDRESS="${DEDICATED_HOST_CONTROL_PLANE_ADDRESS:-10.77.0.1}"
TUNNEL_CIDR="${DEDICATED_HOST_TUNNEL_CIDR:-10.77.0.0/16}"
WG_PORT="${DEDICATED_HOST_WG_PORT:-51820}"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo --preserve-env=DEDICATED_HOST_CONTROL_PLANE_ADDRESS,DEDICATED_HOST_TUNNEL_CIDR,DEDICATED_HOST_WG_PORT,DEDICATED_HOST_PUBLIC_IP \
    bash "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="$(cd -- "${SCRIPT_DIR}/../systemd" && pwd)"

TUNNEL_PREFIX="${TUNNEL_CIDR#*/}"
if [[ ! "${TUNNEL_PREFIX}" =~ ^[0-9]{1,2}$ ]]; then
  echo "DEDICATED_HOST_TUNNEL_CIDR must look like 10.77.0.0/16" >&2
  exit 1
fi
if [[ ! "${WG_PORT}" =~ ^[0-9]{1,5}$ ]]; then
  echo "DEDICATED_HOST_WG_PORT must be a port number" >&2
  exit 1
fi

missing=()
command -v wg >/dev/null 2>&1 || missing+=(wireguard)
command -v ufw >/dev/null 2>&1 || missing+=(ufw)
if [[ "${#missing[@]}" -gt 0 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${missing[@]}"
fi

install -d -m 700 /etc/wireguard

if [[ ! -f /etc/wireguard/wg0.conf ]]; then
  if [[ ! -f /etc/wireguard/wg0.key ]]; then
    (
      umask 077
      wg genkey >/etc/wireguard/wg0.key
    )
    chmod 600 /etc/wireguard/wg0.key
  fi
  wg pubkey </etc/wireguard/wg0.key >/etc/wireguard/wg0.pub
  chmod 644 /etc/wireguard/wg0.pub

  # SaveConfig stays false: authoritymax-wg-sync owns the peer set and rewrites it from the peer
  # files, so a live `wg set` must never be written back over this file.
  (
    umask 077
    {
      echo "[Interface]"
      echo "Address = ${CONTROL_PLANE_ADDRESS}/${TUNNEL_PREFIX}"
      echo "ListenPort = ${WG_PORT}"
      echo "PrivateKey = $(cat /etc/wireguard/wg0.key)"
      echo "SaveConfig = false"
    } >/etc/wireguard/wg0.conf
  )
  chmod 600 /etc/wireguard/wg0.conf
fi

if [[ ! -f /etc/wireguard/wg0.pub ]]; then
  wg pubkey </etc/wireguard/wg0.key >/etc/wireguard/wg0.pub
  chmod 644 /etc/wireguard/wg0.pub
fi

# The firewall policy itself belongs to harden-host.sh; only the tunnel port is added here.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${WG_PORT}/udp" comment 'WireGuard tunnel for dedicated hosts' >/dev/null
fi

systemctl enable --now "wg-quick@wg0"

install -m 755 "${SCRIPT_DIR}/wg-sync.sh" /usr/local/sbin/authoritymax-wg-sync
install -m 644 "${SYSTEMD_DIR}/authoritymax-wg-sync.service" /etc/systemd/system/authoritymax-wg-sync.service
install -m 644 "${SYSTEMD_DIR}/authoritymax-wg-sync.timer" /etc/systemd/system/authoritymax-wg-sync.timer
systemctl daemon-reload
systemctl enable --now authoritymax-wg-sync.timer

public_ip="${DEDICATED_HOST_PUBLIC_IP:-}"
if [[ -z "${public_ip}" ]]; then
  public_ip="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
fi
if [[ -z "${public_ip}" ]]; then
  public_ip="$(hostname -I | awk '{print $1}')"
fi

echo
echo "WireGuard control plane ready on ${CONTROL_PLANE_ADDRESS}/${TUNNEL_PREFIX}, UDP ${WG_PORT}."
echo "Add these two lines to .env, then recreate the api and worker services:"
echo
echo "DEDICATED_HOST_WG_PUBLIC_KEY=$(cat /etc/wireguard/wg0.pub)"
echo "DEDICATED_HOST_WG_ENDPOINT=${public_ip}:${WG_PORT}"
