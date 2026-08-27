#!/usr/bin/env bash

set -Eeuo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SSH_PORT="${SSH_PORT:-22}"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo --preserve-env=DEPLOY_USER,SSH_PORT,DEDICATED_HOST_WG_PORT bash "$0" "$@"
fi

if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
  echo "Deploy user ${DEPLOY_USER} does not exist" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  apparmor \
  apparmor-utils \
  auditd \
  audispd-plugins \
  fail2ban \
  needrestart \
  python3-systemd \
  ufw \
  unattended-upgrades

install -d -m 755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-authoritymax-hardening.conf <<EOF
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
HostbasedAuthentication no
GSSAPIAuthentication no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
GatewayPorts no
PermitTunnel no
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 4
MaxStartups 10:30:30
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
LogLevel VERBOSE
AllowUsers ${DEPLOY_USER}
EOF
chmod 600 /etc/ssh/sshd_config.d/99-authoritymax-hardening.conf
sshd -t

# backend = systemd needs python3-systemd, which --no-install-recommends leaves out above.
cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT}
maxretry = 3
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
banaction = ufw
EOF

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat >/etc/apt/apt.conf.d/52authoritymax-unattended-upgrades <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat >/etc/sysctl.d/99-authoritymax-hardening.conf <<'EOF'
fs.protected_fifos = 2
fs.protected_hardlinks = 1
fs.protected_regular = 2
fs.protected_symlinks = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.perf_event_paranoid = 3
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.default.accept_source_route = 0
EOF
sysctl --system >/dev/null

install -d -m 750 /etc/audit/rules.d
cat >/etc/audit/rules.d/50-authoritymax.rules <<'EOF'
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
EOF
augenrules --load >/dev/null

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw limit "${SSH_PORT}/tcp" comment 'Rate-limited SSH'
ufw allow 80/tcp comment 'HTTP for ACME redirect'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'HTTP/3'

# The reset above drops every rule, so a re-run on a live control plane would silently cut the
# dedicated-host tunnel. Restore the port wg0 actually listens on; DEDICATED_HOST_WG_PORT covers a
# host prepared before setup-control-plane.sh has written wg0.conf.
WG_PORT=""
if [[ -r /etc/wireguard/wg0.conf ]]; then
  WG_PORT="$(sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*\([0-9]\{1,5\}\)[[:space:]]*$/\1/p' \
    /etc/wireguard/wg0.conf | head -n 1)"
  WG_PORT="${WG_PORT:-${DEDICATED_HOST_WG_PORT:-51820}}"
else
  WG_PORT="${DEDICATED_HOST_WG_PORT:-}"
fi
if [[ -n "${WG_PORT}" ]]; then
  if [[ "${WG_PORT}" =~ ^[0-9]{1,5}$ ]] && ((WG_PORT >= 1 && WG_PORT <= 65535)); then
    ufw allow "${WG_PORT}/udp" comment 'WireGuard tunnel for dedicated hosts'
  else
    echo "Ignoring invalid WireGuard listen port: ${WG_PORT}" >&2
  fi
fi

ufw --force enable

systemctl enable --now apparmor auditd fail2ban unattended-upgrades
systemctl restart fail2ban
# Debian 13 socket-activates SSH, so ssh.service is not running and cannot be reloaded; each new
# connection reads the config afresh. Reload only the unit that is actually up.
if systemctl is-active --quiet ssh.service; then
  systemctl reload ssh.service
elif systemctl is-active --quiet sshd.service; then
  systemctl reload sshd.service
fi

echo "AuthorityMax host hardening applied. Verify a fresh SSH session before closing the current one."
