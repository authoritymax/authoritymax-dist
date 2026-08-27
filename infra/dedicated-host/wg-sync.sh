#!/usr/bin/env bash

# Apply the dedicated-host peer files the control plane writes to the wg0 interface.
#
# The application container writes one `<hostId>.conf` per dedicated host into the appdata volume;
# this timer-driven script is the only thing that touches WireGuard, so the containers keep
# `cap_drop: ALL`. Peer files are untrusted input: every line is matched against a strict allowlist
# (one `[Peer]`, one `PublicKey`, one `/32` `AllowedIPs`) and duplicate keys or addresses are
# dropped, so a peer file can never widen its own routes or claim another host's tunnel address.
#
# The peer set is replaced wholesale on every run, so deprovisioning a host — which deletes its peer
# file — revokes its tunnel access within one tick, down to the last host. A missing peer directory
# means the stack is not running dedicated hosts and is left alone.

set -euo pipefail

INTERFACE="wg0"
INTERFACE_CONFIG="/etc/wireguard/${INTERFACE}.conf"
RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/authoritymax-wg}"
STAGED_CONFIG="${RUNTIME_DIR}/${INTERFACE}.conf"
COMPOSE_PROJECT="${AUTHORITYMAX_COMPOSE_PROJECT_NAME:-authoritymax-prod}"

warn() {
  echo "authoritymax-wg-sync: $*" >&2
}

resolve_peer_dir() {
  if [[ -n "${AUTHORITYMAX_PEER_DIR:-}" ]]; then
    printf '%s\n' "${AUTHORITYMAX_PEER_DIR}"
    return 0
  fi
  local mountpoint
  mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "${COMPOSE_PROJECT}_appdata" 2>/dev/null || true)"
  [[ -n "${mountpoint}" ]] || return 0
  printf '%s\n' "${mountpoint}/wireguard/peers"
}

PEER_DIR="$(resolve_peer_dir)"
if [[ -z "${PEER_DIR}" || ! -d "${PEER_DIR}" ]]; then
  exit 0
fi

shopt -s nullglob
peer_files=("${PEER_DIR}"/*.conf)
shopt -u nullglob

if [[ ! -r "${INTERFACE_CONFIG}" ]]; then
  warn "${INTERFACE_CONFIG} is missing; run infra/dedicated-host/setup-control-plane.sh first"
  exit 1
fi

# Standard base64 of a 32-byte X25519 key, and a single-address route.
key_pattern='^[A-Za-z0-9+/]{43}=$'
octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
address_pattern="^${octet}\.${octet}\.${octet}\.${octet}/32$"

declare -A seen_keys=()
declare -A seen_addresses=()
peer_block=""

for peer_file in "${peer_files[@]}"; do
  [[ -f "${peer_file}" ]] || continue
  public_key=""
  allowed_ips=""
  value=""
  header_seen=0
  rejected=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    # Trim surrounding whitespace without a subshell.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]] && continue
    if [[ "${line}" == "[Peer]" ]]; then
      if [[ "${header_seen}" -eq 1 ]]; then
        warn "ignoring ${peer_file}: more than one [Peer] section"
        rejected=1
        break
      fi
      header_seen=1
      continue
    fi
    if [[ "${line}" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      # A nested match would clobber BASH_REMATCH, so read the capture first.
      value="${BASH_REMATCH[1]}"
      if [[ -n "${public_key}" ]] || [[ ! "${value}" =~ ${key_pattern} ]]; then
        warn "ignoring ${peer_file}: bad or repeated PublicKey"
        rejected=1
        break
      fi
      public_key="${value}"
      continue
    fi
    if [[ "${line}" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      if [[ -n "${allowed_ips}" ]] || [[ ! "${value}" =~ ${address_pattern} ]]; then
        warn "ignoring ${peer_file}: AllowedIPs must be a single IPv4 /32"
        rejected=1
        break
      fi
      allowed_ips="${value}"
      continue
    fi
    warn "ignoring ${peer_file}: unexpected directive"
    rejected=1
    break
  done <"${peer_file}"

  [[ "${rejected}" -eq 1 ]] && continue
  if [[ "${header_seen}" -eq 0 || -z "${public_key}" || -z "${allowed_ips}" ]]; then
    warn "ignoring ${peer_file}: incomplete peer"
    continue
  fi
  if [[ -n "${seen_keys[${public_key}]:-}" ]]; then
    warn "ignoring ${peer_file}: duplicate PublicKey"
    continue
  fi
  if [[ -n "${seen_addresses[${allowed_ips}]:-}" ]]; then
    warn "ignoring ${peer_file}: ${allowed_ips} already claimed by another peer"
    continue
  fi
  seen_keys["${public_key}"]=1
  seen_addresses["${allowed_ips}"]=1
  peer_block+=$'[Peer]\n'"PublicKey = ${public_key}"$'\n'"AllowedIPs = ${allowed_ips}"$'\n\n'
done

install -d -m 700 "${RUNTIME_DIR}"
umask 077
# `wg syncconf` replaces the peer set wholesale, so the staged file carries the live [Interface]
# section unchanged followed by exactly the validated peers. wg-quick strip needs the file to be
# named after the interface.
{
  awk '/^\[Peer\]/ { exit } { print }' "${INTERFACE_CONFIG}"
  printf '\n%s' "${peer_block}"
} >"${STAGED_CONFIG}"
chmod 600 "${STAGED_CONFIG}"

wg syncconf "${INTERFACE}" <(wg-quick strip "${STAGED_CONFIG}")
