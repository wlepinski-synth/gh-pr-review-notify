#!/usr/bin/env bash
#
# gh-pr-review-notify.sh
#
# Polls GitHub for open pull requests where your review has been requested and
# fires a native macOS notification for any PR you haven't been notified about
# yet. Designed to be run on a schedule (see install.sh / launchd agent).
#
# No credentials are stored or required by this script — it relies entirely on
# the GitHub CLI's existing authentication (`gh auth login`). Nothing here is
# specific to a single user or machine, so it can be shared as-is.
#
# Configuration (all optional, via environment variables):
#   GH_PR_NOTIFY_QUERY      Search args passed to `gh search prs`.
#                           Default: "--review-requested=@me --state=open"
#                           Example to skip drafts: add " --draft=false"
#   GH_PR_NOTIFY_LIMIT      Max PRs to fetch per run. Default: 50
#   GH_PR_NOTIFY_STATE_DIR  Where dedup state is kept.
#                           Default: ${XDG_STATE_HOME:-$HOME/.local/state}/gh-pr-review-notify
#
# Exit codes: 0 = ran fine; 1 = a precondition/transient failure (logged, and
# in the failure case the dedup state is left untouched so recovery doesn't
# replay every PR as "new").

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
QUERY="${GH_PR_NOTIFY_QUERY:---review-requested=@me --state=open}"
LIMIT="${GH_PR_NOTIFY_LIMIT:-50}"
STATE_DIR="${GH_PR_NOTIFY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gh-pr-review-notify}"
STATE_FILE="$STATE_DIR/notified.tsv"

# Banner image, shown on the right of the notification via terminal-notifier's
# -contentImage. (The left app icon can't be changed by a flag on modern macOS,
# so we attach the GitHub mark as the content image instead.) Defaults to the
# mark shipped next to this script; override with GH_PR_NOTIFY_ICON (path or
# URL), or set it empty to show no image.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICON="${GH_PR_NOTIFY_ICON-$SCRIPT_DIR/gh-mark.png}"

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# Logging — everything goes to stderr so launchd captures it in the log file.
# ---------------------------------------------------------------------------
log() {
  # ISO-8601 local timestamp without relying on GNU date flags
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

# ---------------------------------------------------------------------------
# Notification — prefer terminal-notifier (clickable), fall back to osascript.
# Args: title, subtitle, message, url(optional)
# ---------------------------------------------------------------------------
notify() {
  local title="$1" subtitle="$2" message="$3" url="${4:-}"

  if command -v terminal-notifier >/dev/null 2>&1; then
    local args=(-title "$title" -subtitle "$subtitle" -message "$message" -sound default)
    if [[ -n "$url" ]]; then
      args+=(-open "$url" -group "$url")
    fi
    # Attach the GitHub mark as the content image (right side), when configured
    # and reachable (local file or http(s) URL).
    if [[ -n "$ICON" && ( -f "$ICON" || "$ICON" == http* ) ]]; then
      args+=(-contentImage "$ICON")
    fi
    terminal-notifier "${args[@]}" >/dev/null 2>&1 || log "WARN: terminal-notifier failed for: $message"
    return
  fi

  # Fallback: osascript banner (not clickable). Escape double quotes.
  local esc_title esc_message
  esc_title=$(printf '%s' "$title — $subtitle" | sed 's/"/\\"/g')
  esc_message=$(printf '%s' "$message" | sed 's/"/\\"/g')
  osascript -e "display notification \"$esc_message\" with title \"$esc_title\"" >/dev/null 2>&1 \
    || log "WARN: osascript notification failed for: $message"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

# 1) gh on PATH?
if ! command -v gh >/dev/null 2>&1; then
  log "ERROR: GitHub CLI (gh) not found on PATH."
  notify "PR notifier error" "GitHub CLI missing" "Install it: brew install gh"
  exit 1
fi

# 2) gh actually runnable? (Catches a broken asdf shim — e.g. 'exec: asdf: not
#    found' — which otherwise looks like a generic failure. Distinct from #1.)
if ! gh --version >/dev/null 2>&1; then
  log "ERROR: 'gh' is on PATH but failed to run (likely asdf/version/PATH issue)."
  notify "PR notifier error" "GitHub CLI not runnable" "Check gh/asdf install — see log"
  exit 1
fi

# 3) authenticated?
if ! gh auth status >/dev/null 2>&1; then
  log "ERROR: gh is not authenticated."
  notify "PR notifier error" "GitHub CLI not authenticated" "Run: gh auth login"
  exit 1
fi

# ---------------------------------------------------------------------------
# Fetch PRs. Capture stderr so we can classify failures; never let a transient
# error nuke the dedup state.
# ---------------------------------------------------------------------------
gh_stderr=$(mktemp)
# shellcheck disable=SC2086  # QUERY intentionally expands to multiple args
if ! current=$(gh search prs $QUERY \
      --limit "$LIMIT" \
      --json url,title,repository,updatedAt \
      --jq '.[] | [.url, .updatedAt, .repository.nameWithOwner, .title] | @tsv' \
      2>"$gh_stderr"); then
  err=$(cat "$gh_stderr"); rm -f "$gh_stderr"
  if printf '%s' "$err" | grep -qi 'rate limit'; then
    log "ERROR: GitHub API rate limit hit. Will retry next run. Detail: $err"
  else
    log "ERROR: gh search prs failed (network/API?). State left untouched. Detail: $err"
  fi
  exit 1
fi
rm -f "$gh_stderr"

# ---------------------------------------------------------------------------
# Dedup + notify.
#   Previous state: lines of "url<TAB>updatedAt".
#   Notify when a url is new, or its updatedAt changed since last time.
#   (Uses a plain state file + grep so it works on macOS's stock bash 3.2 —
#   no associative arrays.)
# ---------------------------------------------------------------------------
already_notified() {
  # Whole-line fixed-string match: differs if the url is new OR updatedAt changed.
  [[ -f "$STATE_FILE" ]] && grep -Fxq -- "$1"$'\t'"$2" "$STATE_FILE"
}

new_state=$(mktemp)
notified=0
total=0

if [[ -n "$current" ]]; then
  while IFS=$'\t' read -r url updated repo title; do
    [[ -z "$url" ]] && continue
    total=$((total + 1))
    printf '%s\t%s\n' "$url" "$updated" >> "$new_state"
    if ! already_notified "$url" "$updated"; then
      notify "PR review requested" "$repo" "$title" "$url"
      notified=$((notified + 1))
    fi
  done <<< "$current"
fi

# Atomically replace state with only the currently-open PRs (closed/merged drop
# out so they re-notify if reopened; file stays bounded).
mv "$new_state" "$STATE_FILE"

log "OK: ${total} PR(s) awaiting review, ${notified} new notification(s)."
exit 0
