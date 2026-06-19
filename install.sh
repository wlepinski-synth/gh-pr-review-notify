#!/usr/bin/env bash
#
# install.sh — set up the GitHub PR-review desktop notifier as a launchd agent
# that runs every 15 minutes (and at login).
#
# Safe to re-run: it boots out any existing agent before reloading.

set -euo pipefail

# Resolve this script's directory so paths work no matter where it's run from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$SCRIPT_DIR/gh-pr-review-notify.sh"

USER_NAME="$(id -un)"
UID_NUM="$(id -u)"
LABEL="com.${USER_NAME}.pr-review-notify"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_FILE="$HOME/Library/Logs/gh-pr-review-notify.log"
INTERVAL="${GH_PR_NOTIFY_INTERVAL:-900}"   # seconds; 900 = 15 min

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[[ "$(uname)" == "Darwin" ]] || fail "This installer targets macOS (launchd)."
[[ -f "$POLLER" ]] || fail "Poller script not found at $POLLER"
chmod +x "$POLLER"

command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) not found. Install it first: brew install gh"

if ! gh auth status >/dev/null 2>&1; then
  fail "gh is not authenticated. Run 'gh auth login' and re-run this installer."
fi
info "gh found and authenticated."

# ---------------------------------------------------------------------------
# terminal-notifier (optional — enables clickable banners). Fall back quietly.
# ---------------------------------------------------------------------------
if command -v terminal-notifier >/dev/null 2>&1; then
  info "terminal-notifier already installed."
elif command -v brew >/dev/null 2>&1; then
  info "Installing terminal-notifier via Homebrew..."
  brew install terminal-notifier || warn "brew install failed; will use osascript fallback (non-clickable banners)."
else
  warn "Homebrew not found. Notifications will use the osascript fallback (non-clickable)."
fi

# ---------------------------------------------------------------------------
# Build a PATH for the agent that includes wherever gh and terminal-notifier
# actually live (asdf shim, Homebrew, or system) — no hardcoded paths.
# ---------------------------------------------------------------------------
agent_path=""
add_dir() {
  local d="$1"
  [[ -n "$d" ]] || return 0
  case ":$agent_path:" in
    *":$d:"*) return 0 ;;   # already present
  esac
  agent_path="${agent_path:+$agent_path:}$d"
}
# Resolve the *real* gh binary first. If gh is an asdf shim, the shim re-execs
# `asdf exec gh`, which means the agent would also need `asdf` on PATH and a
# resolvable version at runtime — brittle. Pointing PATH straight at the
# installed binary's dir avoids that whole layer. The shim dir is kept as a
# fallback in case the pinned version is later removed by an upgrade.
real_gh=""
if command -v asdf >/dev/null 2>&1; then
  real_gh="$(asdf which gh 2>/dev/null || true)"
  add_dir "$(dirname "$(command -v asdf)")"   # so the shim fallback can find asdf
fi
[[ -n "$real_gh" ]] && add_dir "$(dirname "$real_gh")"   # real binary (robust)
add_dir "$(dirname "$(command -v gh)")"                  # shim dir (fallback)
if command -v terminal-notifier >/dev/null 2>&1; then
  add_dir "$(dirname "$(command -v terminal-notifier)")"
fi
add_dir "/opt/homebrew/bin"
add_dir "/usr/local/bin"
add_dir "/usr/bin"
add_dir "/bin"
info "Agent PATH: $agent_path"

# ---------------------------------------------------------------------------
# Generate the launchd plist.
# ---------------------------------------------------------------------------
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${POLLER}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${agent_path}</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>StartInterval</key>
    <integer>${INTERVAL}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
PLIST_EOF
info "Wrote launchd plist: $PLIST"

# ---------------------------------------------------------------------------
# (Re)load the agent.
# ---------------------------------------------------------------------------
# Boot out any prior instance (ignore errors if not loaded).
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true

if launchctl bootstrap "gui/${UID_NUM}" "$PLIST" 2>/dev/null; then
  info "Agent loaded via launchctl bootstrap."
else
  # Fallback for older launchctl semantics.
  launchctl load -w "$PLIST" || fail "Failed to load launchd agent."
  info "Agent loaded via launchctl load."
fi

info "Done. It will check every ${INTERVAL}s and at login."
info "Run now:        launchctl kickstart -k gui/${UID_NUM}/${LABEL}"
info "View log:       tail -f \"$LOG_FILE\""
info "Uninstall:      $SCRIPT_DIR/uninstall.sh"
