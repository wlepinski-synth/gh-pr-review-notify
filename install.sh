#!/usr/bin/env bash
#
# install.sh — set up the GitHub PR-review desktop notifier as a launchd agent.
# Prompts for how often to check (in minutes); runs that often and at login.
#
# Safe to re-run: it boots out any existing agent before reloading, and
# defaults the prompt to the interval you're already using.

set -euo pipefail

# Resolve this script's directory so paths work no matter where it's run from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$SCRIPT_DIR/gh-pr-review-notify.sh"

USER_NAME="$(id -un)"
UID_NUM="$(id -u)"
LABEL="com.${USER_NAME}.pr-review-notify"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_FILE="$HOME/Library/Logs/gh-pr-review-notify.log"

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
# Poll interval (seconds). Precedence:
#   1) GH_PR_NOTIFY_INTERVAL env var (in seconds — for non-interactive runs)
#   2) interactive prompt, asked in minutes
#   3) the interval this machine is already using, else 15 minutes
# ---------------------------------------------------------------------------

# Minutes -> whole seconds (accepts decimals like 0.5). Prints 0 if invalid/<=0.
mins_to_secs() {
  awk -v m="$1" 'BEGIN {
    if (m ~ /^[0-9]+([.][0-9]+)?$/ && m + 0 > 0) printf "%d", (m * 60) + 0.5
    else print 0
  }'
}

# Default offered at the prompt: the current install's interval, else 15 min.
default_min=15
if [[ -f "$PLIST" ]]; then
  existing="$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$PLIST" 2>/dev/null || true)"
  if [[ "$existing" =~ ^[0-9]+$ && "$existing" -ge 1 ]]; then
    default_min="$(awk -v s="$existing" 'BEGIN { m = s / 60; printf (m == int(m) ? "%d" : "%g"), m }')"
  fi
fi

if [[ -n "${GH_PR_NOTIFY_INTERVAL:-}" ]]; then
  INTERVAL="$GH_PR_NOTIFY_INTERVAL"
  info "Using interval from GH_PR_NOTIFY_INTERVAL: ${INTERVAL}s"
elif [[ -t 0 ]]; then
  INTERVAL=""
  while :; do
    printf '\033[1;34m==>\033[0m How often should it check GitHub? Interval in minutes [%s]: ' "$default_min"
    read -r reply || reply=""
    reply="${reply:-$default_min}"
    secs="$(mins_to_secs "$reply")"
    if [[ "$secs" -ge 1 ]]; then
      INTERVAL="$secs"
      [[ "$secs" -lt 60 ]] && warn "Under a minute (${secs}s) — that's frequent, but allowed."
      break
    fi
    warn "Enter a positive number of minutes (e.g. 1, 5, 15, or 0.5)."
  done
else
  INTERVAL="$(mins_to_secs "$default_min")"
  info "Non-interactive shell; defaulting to ${default_min} min. Set GH_PR_NOTIFY_INTERVAL (seconds) to override."
fi
info "Polling every ${INTERVAL}s ($(awk -v s="$INTERVAL" 'BEGIN { printf "%g", s / 60 }') min)."

# ---------------------------------------------------------------------------
# Review scope: notify on direct requests only, or also team requests?
# GitHub's `review-requested:@me` matches BOTH PRs requested from you directly
# and from teams you belong to; `user-review-requested:@me` is direct-only.
# Precedence: GH_PR_NOTIFY_QUERY env > interactive prompt > current/default.
# ---------------------------------------------------------------------------
DIRECT_QUERY="user-review-requested:@me --state=open"
TEAM_QUERY="--review-requested=@me --state=open"

# Default the prompt to the scope already installed, else direct-only.
default_scope=1
if [[ -f "$PLIST" ]]; then
  existing_q="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:GH_PR_NOTIFY_QUERY' "$PLIST" 2>/dev/null || true)"
  [[ "$existing_q" == "$TEAM_QUERY" ]] && default_scope=2
fi

if [[ -n "${GH_PR_NOTIFY_QUERY:-}" ]]; then
  REVIEW_QUERY="$GH_PR_NOTIFY_QUERY"
  info "Using review scope from GH_PR_NOTIFY_QUERY: $REVIEW_QUERY"
elif [[ -t 0 ]]; then
  info "Which review requests should notify you?"
  printf '      1) Only when you are requested directly (default)\n'
  printf "      2) Also when a team you're on is requested\n"
  REVIEW_QUERY=""
  while :; do
    printf '\033[1;34m==>\033[0m Choose [1/2] (%s): ' "$default_scope"
    read -r ans || ans=""
    ans="${ans:-$default_scope}"
    case "$ans" in
      1) REVIEW_QUERY="$DIRECT_QUERY"; break ;;
      2) REVIEW_QUERY="$TEAM_QUERY";   break ;;
      *) warn "Enter 1 or 2." ;;
    esac
  done
else
  REVIEW_QUERY="$DIRECT_QUERY"
  [[ "$default_scope" == 2 ]] && REVIEW_QUERY="$TEAM_QUERY"
  info "Non-interactive shell; review scope defaulted. Set GH_PR_NOTIFY_QUERY to override."
fi
if [[ "$REVIEW_QUERY" == "$TEAM_QUERY" ]]; then
  info "Review scope: direct + team requests."
else
  info "Review scope: direct requests only."
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
        <key>GH_PR_NOTIFY_QUERY</key>
        <string>${REVIEW_QUERY}</string>
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
