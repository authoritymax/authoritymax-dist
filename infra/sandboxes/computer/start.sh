#!/usr/bin/env bash
set -uo pipefail
# Browser subprocess crashes would otherwise leave multi-MB core.* files in the workspace.
ulimit -c 0 2>/dev/null || true
export DISPLAY="${DISPLAY:-:1}"
export HOME="${HOME:-/home/authoritymax}"
AGENT_HOME="$HOME"
mkdir -p "$AGENT_HOME" "$AGENT_HOME/.local/bin" "$AGENT_HOME/.config" /tmp/authoritymax /tmp/.X11-unix /tmp/fluxbox-home
export PATH="$AGENT_HOME/.local/bin:/usr/local/bin:$PATH"
export NPM_CONFIG_PREFIX="$AGENT_HOME/.local"
export PIP_USER=1
cd "$AGENT_HOME"

rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

Xvfb :1 -screen 0 1280x800x24 -ac +extension RANDR +render -noreset >/tmp/authoritymax/xvfb.log 2>&1 &
XVFB_PID=$!

ready=0
for _ in $(seq 1 100); do
  if xdpyinfo -display :1 >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" -ne 1 ]]; then
  echo "Xvfb failed to start" >&2
  cat /tmp/authoritymax/xvfb.log >&2 || true
  exit 1
fi

if command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax)"
fi

hsetroot -fill /usr/share/authoritymax/wallpaper.png >/dev/null 2>&1 || true
mkdir -p /tmp/fluxbox-home/.fluxbox
cp /etc/authoritymax/fluxbox/init /tmp/fluxbox-home/.fluxbox/init
cp /etc/authoritymax/fluxbox/apps /tmp/fluxbox-home/.fluxbox/apps 2>/dev/null || true
cp /etc/authoritymax/fluxbox/menu /tmp/fluxbox-home/.fluxbox/menu 2>/dev/null || true
cat > /tmp/fluxbox-home/.fluxbox/startup <<'EOF'
#!/bin/sh
hsetroot -fill /usr/share/authoritymax/wallpaper.png
exec fluxbox -rc /tmp/fluxbox-home/.fluxbox/init
EOF
chmod +x /tmp/fluxbox-home/.fluxbox/startup
HOME=/tmp/fluxbox-home /tmp/fluxbox-home/.fluxbox/startup >/tmp/authoritymax/fluxbox.log 2>&1 &
hsetroot -fill /usr/share/authoritymax/wallpaper.png >/dev/null 2>&1 || true
# The bar reserves its strut before the browser maximizes, so Chrome stays above it.
tint2 -c /etc/authoritymax/tint2rc >/tmp/authoritymax/tint2.log 2>&1 &
for _ in $(seq 1 40); do
  xdotool search --class tint2 >/dev/null 2>&1 && break
  sleep 0.1
done

# A previous container can leave Chromium's singleton lock behind in the persistent
# profile; it names a hostname that no longer exists, so Chromium would refuse the profile.
mkdir -p "$AGENT_HOME/.browser-profiles/chromium"
rm -f "$AGENT_HOME/.browser-profiles/chromium/SingletonLock" \
  "$AGENT_HOME/.browser-profiles/chromium/SingletonCookie" \
  "$AGENT_HOME/.browser-profiles/chromium/SingletonSocket"
# The supervisor's per-call browser liveness check matches this exact launch line
# (display, then the profile flag) to tell a live keep loop from a dead one.
HOME="$AGENT_HOME" authoritymax-browser-keep :1 --user-data-dir="$AGENT_HOME/.browser-profiles/chromium" >/tmp/authoritymax/browser.log 2>&1 &
browser_up=0
for _ in $(seq 1 60); do
  for cls in chromium Chromium Google-chrome google-chrome; do
    if xdotool search --onlyvisible --class "$cls" >/dev/null 2>&1; then browser_up=1; break; fi
  done
  [[ "$browser_up" -eq 1 ]] && break
  sleep 0.25
done
if [[ "$browser_up" -ne 1 ]]; then
  echo "browser failed to start" >&2
  cat /tmp/authoritymax/browser.log >&2 || true
fi
# Persistent terminal for this display (tmux session + xterm), placed under the browser.
authoritymax-terminal-tty :1 >/dev/null 2>&1 || echo "terminal failed to start" >&2
if [[ "$browser_up" -eq 1 ]]; then
  for cls in chromium Chromium Google-chrome google-chrome; do
    xdotool search --onlyvisible --class "$cls" windowactivate --sync >/dev/null 2>&1 && break
  done
fi

x11vnc -display :1 -forever -shared -viewonly -nopw -listen 127.0.0.1 -rfbport 5900 -xkb -ncache 0 >/tmp/authoritymax/x11vnc.log 2>&1 &

NOVNC_ROOT=/usr/share/novnc
if [[ ! -d "$NOVNC_ROOT" ]]; then
  echo "noVNC is missing from the computer image" >&2
  exit 1
fi
if [[ ! -f "$NOVNC_ROOT/embed.html" ]]; then
  echo "noVNC embed.html is missing from the computer image" >&2
  exit 1
fi
websockify --heartbeat=30 --web="$NOVNC_ROOT" 0.0.0.0:6080 127.0.0.1:5900 >/tmp/authoritymax/novnc.log 2>&1 &

while kill -0 "$XVFB_PID" 2>/dev/null; do
  sleep 2
done
echo "Xvfb exited" >&2
exit 1
