#!/usr/bin/env bash
#
# uninstall.sh — unload and remove the GitHub PR-review notifier launchd agent.
# Leaves the script/README folder in place so you can reinstall later.

set -euo pipefail

USER_NAME="$(id -un)"
UID_NUM="$(id -u)"
LABEL="com.${USER_NAME}.pr-review-notify"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
STATE_DIR="${GH_PR_NOTIFY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gh-pr-review-notify}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Unload (ignore errors if it isn't loaded).
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null \
  || launchctl unload -w "$PLIST" 2>/dev/null \
  || true
info "Agent unloaded (if it was loaded)."

if [[ -f "$PLIST" ]]; then
  rm -f "$PLIST"
  info "Removed $PLIST"
fi

if [[ -d "$STATE_DIR" ]]; then
  rm -rf "$STATE_DIR"
  info "Removed dedup state $STATE_DIR"
fi

info "Uninstalled. The tool folder and logs were left in place."
