#!/usr/bin/env bash
# Run email2codex as a background service that starts at boot/login and restarts on failure.
#   macOS: launchd agent "com.email2codex"      Linux: systemd user service "email2codex"
# The process shows up as "email2codex" in Activity Monitor / ps / top.
# Usage: ./email2codex.sh install|uninstall|start|stop|restart|status|logs
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="email2codex"
LABEL="com.$NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UNIT="$HOME/.config/systemd/user/$NAME.service"
LOG="$DIR/logs/$NAME.log"
DOMAIN="gui/$(id -u)"
# A symlink to the venv's Python named "email2codex", so the process is listed under that name.
LAUNCHER="$DIR/.venv/proc/$NAME"

prepare() {
  local uv
  uv="$(command -v uv)" || { echo "uv not found in PATH" >&2; exit 1; }
  (cd "$DIR" && "$uv" sync -q)
  mkdir -p "$(dirname "$LAUNCHER")" "$DIR/logs"
  ln -sf ../bin/python "$LAUNCHER"
  # The service doesn't load your shell profile, so capture the PATH that finds codex now.
  SERVICE_PATH="$(dirname "$(command -v codex || echo /usr/local/bin/codex)"):$(dirname "$uv"):/usr/local/bin:/usr/bin:/bin"
}

install_macos() {
  prepare
  mkdir -p "$(dirname "$PLIST")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$LAUNCHER</string><string>-m</string><string>$NAME</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$SERVICE_PATH</string><key>PYTHONUNBUFFERED</key><string>1</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
}

install_linux() {
  prepare
  mkdir -p "$(dirname "$UNIT")"
  cat >"$UNIT" <<EOF
[Unit]
Description=$NAME
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$DIR
ExecStart=$LAUNCHER -m $NAME
Environment=PATH=$SERVICE_PATH
Environment=PYTHONUNBUFFERED=1
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable "$NAME"
  loginctl enable-linger "$USER"  # start at boot without logging in
}

macos() {
  case "$1" in
    install) launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; install_macos; launchctl bootstrap "$DOMAIN" "$PLIST" ;;
    uninstall) launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -f "$PLIST" ;;
    start) launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl kickstart "$DOMAIN/$LABEL" ;;
    stop) launchctl bootout "$DOMAIN/$LABEL" ;;
    restart) launchctl kickstart -k "$DOMAIN/$LABEL" ;;
    status) launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "^\s+(state|pid|last exit code) =" || echo "not running" ;;
    logs) tail -n 50 -f "$LOG" ;;
  esac
}

linux() {
  case "$1" in
    install) install_linux; systemctl --user restart "$NAME" ;;
    uninstall) systemctl --user disable --now "$NAME" 2>/dev/null || true; rm -f "$UNIT"; systemctl --user daemon-reload ;;
    start | stop | restart | status) systemctl --user "$1" "$NAME" ;;
    logs) journalctl --user -u "$NAME" -n 50 -f ;;
  esac
}

cmd="${1:-}"
case "$cmd" in
  install | uninstall | start | stop | restart | status | logs) ;;
  *) echo "Usage: $0 install|uninstall|start|stop|restart|status|logs" >&2; exit 1 ;;
esac
case "$(uname -s)" in
  Darwin) macos "$cmd" ;;
  Linux) linux "$cmd" ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
