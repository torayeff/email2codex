#!/usr/bin/env bash
# Install email2codex as a service that starts at boot/login and restarts on failure.
#   macOS: launchd agent (~/Library/LaunchAgents), logs in ./logs/
#   Linux: systemd user service, logs via `journalctl --user -u email2codex -f`
# Usage: ./install-service.sh [uninstall]
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
UV="$(command -v uv || true)"
[[ -n "$UV" ]] || { echo "uv not found in PATH" >&2; exit 1; }
# The service doesn't load your shell profile, so capture the PATH that finds uv and codex now.
SERVICE_PATH="$(dirname "$UV"):$(dirname "$(command -v codex || echo /usr/local/bin/codex)"):/usr/local/bin:/usr/bin:/bin"

case "$(uname -s)" in
Darwin)
  LABEL="com.email2codex"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  if [[ "${1:-}" == "uninstall" ]]; then rm -f "$PLIST"; echo "Removed $PLIST"; exit 0; fi
  mkdir -p "$DIR/logs" "$(dirname "$PLIST")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$UV</string><string>run</string><string>email2codex</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$SERVICE_PATH</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$DIR/logs/email2codex.log</string>
  <key>StandardErrorPath</key><string>$DIR/logs/email2codex.log</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Installed $PLIST; logs: tail -f $DIR/logs/email2codex.log"
  echo "Note: launchd agents start when you log in; enable automatic login for unattended reboots."
  ;;
Linux)
  UNIT="$HOME/.config/systemd/user/email2codex.service"
  systemctl --user disable --now email2codex 2>/dev/null || true
  if [[ "${1:-}" == "uninstall" ]]; then rm -f "$UNIT"; systemctl --user daemon-reload; echo "Removed $UNIT"; exit 0; fi
  mkdir -p "$(dirname "$UNIT")"
  cat >"$UNIT" <<EOF
[Unit]
Description=email2codex
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$DIR
ExecStart=$UV run email2codex
Environment=PATH=$SERVICE_PATH
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now email2codex
  loginctl enable-linger "$USER"  # start at boot without logging in
  echo "Installed $UNIT; logs: journalctl --user -u email2codex -f"
  ;;
*)
  echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
