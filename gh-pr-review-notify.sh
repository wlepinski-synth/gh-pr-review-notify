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
#   GH_PR_NOTIFY_QUERY       Search args passed to `gh search prs`.
#                            Default: "user-review-requested:@me --state=open"
#                            (direct requests only). For team requests too, use
#                            "--review-requested=@me --state=open".
#   GH_PR_NOTIFY_LIMIT       Max PRs to fetch per run. Default: 50
#   GH_PR_NOTIFY_STATE_DIR   Where dedup state is kept.
#                            Default: ${XDG_STATE_HOME:-$HOME/.local/state}/gh-pr-review-notify
#   GH_PR_NOTIFY_EXCLUDE_TITLE  Case-insensitive regex of PR titles to skip.
#                            Default: "DO NOT REVIEW|WIP". Set empty to disable.
#   GH_PR_NOTIFY_INCLUDE_DRAFTS  Set to 1 to notify about draft PRs too.
#                            Default: drafts are skipped.
#   GH_PR_NOTIFY_SUMMARY_THRESHOLD  When more than this many PRs are newly
#                            pending in one run, send a single summary banner
#                            instead of one per PR. Default: 5. Set 0 to always
#                            send per-PR banners.
#
# Exit codes: 0 = ran fine; 1 = a precondition/transient failure (logged, and
# in the failure case the dedup state is left untouched so recovery doesn't
# replay every PR as "new").

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
QUERY="${GH_PR_NOTIFY_QUERY:-user-review-requested:@me --state=open}"
LIMIT="${GH_PR_NOTIFY_LIMIT:-50}"
STATE_DIR="${GH_PR_NOTIFY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gh-pr-review-notify}"
STATE_FILE="$STATE_DIR/notified.tsv"
EXCLUDE_TITLE="${GH_PR_NOTIFY_EXCLUDE_TITLE-DO NOT REVIEW|WIP}"
INCLUDE_DRAFTS="${GH_PR_NOTIFY_INCLUDE_DRAFTS:-0}"
SUMMARY_THRESHOLD="${GH_PR_NOTIFY_SUMMARY_THRESHOLD:-5}"

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
# Human-friendly age from an ISO-8601 UTC timestamp ("2026-06-05T14:57:42Z").
# Uses BSD `date` (macOS). Prints "" if the timestamp can't be parsed.
# ---------------------------------------------------------------------------
human_age() {
  local created="$1" created_s now diff
  created_s=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null) || { printf ''; return; }
  now=$(date +%s)
  diff=$(( now - created_s ))
  (( diff < 0 )) && diff=0
  if   (( diff < 3600 ));  then printf '%dm' $(( diff / 60 ))
  elif (( diff < 86400 )); then printf '%dh' $(( diff / 3600 ))
  else                          printf '%dd' $(( diff / 86400 ))
  fi
}

# ---------------------------------------------------------------------------
# Build the github.com/pulls URL that mirrors $QUERY, so the summary banner
# lands on the same set of PRs it counted (direct-only vs direct+team, etc.).
# Translates the gh search args we know about; falls back to direct requests.
# ---------------------------------------------------------------------------
review_queue_url() {
  local q="$1" parts="is:pr is:open" tok enc
  for tok in $q; do
    case "$tok" in
      --state=open)            ;;                                       # already is:open
      --state=closed)          parts="is:pr is:closed" ;;
      --review-requested=*)    parts="$parts review-requested:${tok#*=}" ;;
      user-review-requested:*) parts="$parts $tok" ;;
      review-requested:*)      parts="$parts $tok" ;;
      *)                       ;;                                       # ignore unmapped flags/terms
    esac
  done
  # Ensure there's a review qualifier; default to direct if the query was custom.
  case "$parts" in *review-requested:*) ;; *) parts="$parts user-review-requested:@me" ;; esac
  enc=$(printf '%s' "$parts" | sed -e 's#/#%2F#g' -e 's/ /+/g' -e 's/:/%3A/g' -e 's/@/%40/g')
  printf 'https://github.com/pulls?q=%s' "$enc"
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
      --json url,title,repository,updatedAt,author,createdAt,isDraft \
      --jq '.[] | [.url, .updatedAt, .repository.nameWithOwner, (.author.login // ""), .createdAt, (.isDraft|tostring), .title] | @tsv' \
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
total=0
skipped=0
to_notify=()   # TSV-encoded entries (repo, author, age, title, url) to notify

if [[ -n "$current" ]]; then
  while IFS=$'\t' read -r url updated repo author created isdraft title; do
    [[ -z "$url" ]] && continue

    # Skip drafts unless explicitly included.
    if [[ "$isdraft" == "true" && "$INCLUDE_DRAFTS" != "1" ]]; then
      skipped=$((skipped + 1)); continue
    fi
    # Skip titles matching the exclude pattern (case-insensitive).
    if [[ -n "$EXCLUDE_TITLE" ]]; then
      shopt -s nocasematch
      if [[ "$title" =~ $EXCLUDE_TITLE ]]; then
        shopt -u nocasematch; skipped=$((skipped + 1)); continue
      fi
      shopt -u nocasematch
    fi

    total=$((total + 1))
    printf '%s\t%s\n' "$url" "$updated" >> "$new_state"
    if ! already_notified "$url" "$updated"; then
      to_notify+=("$repo"$'\t'"$author"$'\t'"$(human_age "$created")"$'\t'"$title"$'\t'"$url")
    fi
  done <<< "$current"
fi

# Atomically replace state with only the currently-open (non-skipped) PRs, so
# closed/merged drop out (and re-notify if reopened) and the file stays bounded.
# A draft that later becomes review-ready is absent here, so it surfaces as new.
mv "$new_state" "$STATE_FILE"

n=${#to_notify[@]}
if (( n == 0 )); then
  :
elif (( SUMMARY_THRESHOLD > 0 && n > SUMMARY_THRESHOLD )); then
  # Too many at once — one summary banner that opens your review queue.
  notify "PR reviews requested" "" "${n} PRs awaiting your review" "$(review_queue_url "$QUERY")"
else
  for entry in "${to_notify[@]}"; do
    IFS=$'\t' read -r repo author age title url <<< "$entry"
    subtitle="$repo"
    [[ -n "$author" ]] && subtitle="$subtitle — @$author"
    [[ -n "$age" ]]    && subtitle="$subtitle · $age"
    notify "PR review requested" "$subtitle" "$title" "$url"
  done
fi

log "OK: ${total} PR(s) awaiting review, ${n} new notification(s), ${skipped} skipped (draft/excluded)."
exit 0
