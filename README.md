# GitHub PR-review desktop notifier

A small background tool for macOS that checks GitHub every minute for open
pull requests where **your review has been requested**, and pops a native
desktop notification for any PR you haven't already been told about. With
`terminal-notifier` installed, the banner is **clickable** and opens the PR in
your browser.

It runs as a `launchd` user agent, so it works in the background even when your
terminal (or Claude Code) isn't open, and starts automatically at login.

## How it works

```
launchd (every 60s) ──▶ gh-pr-review-notify.sh
                              │
                              ├─ gh search prs user-review-requested:@me --state=open
                              ├─ skip drafts + excluded titles (DO NOT REVIEW / WIP)
                              ├─ dedup against a small state file
                              └─ notify (per-PR, or one summary banner when many)
```

- **No credentials are stored.** The script uses the GitHub CLI's own auth
  (`gh auth login`) — there are no tokens in this repo, the script, or the
  launchd plist.
- **Dedup:** a state file (`notified.tsv`) tracks each PR URL and its last
  `updatedAt`. You're notified when a PR is newly requested, or when it gets a
  new update — never repeatedly for the same unchanged PR. Closed/merged PRs
  drop out automatically.
- **Noise control:** draft PRs and titles matching `DO NOT REVIEW`/`WIP` are
  skipped by default. A draft that later becomes review-ready then shows up as
  new. (A draft turning ready re-notifies once it's no longer a draft.)
- **Calm banners:** each PR's banner shows the repo, author, and age
  (e.g. `repo — @alice · 2d`). When more than a threshold of PRs are newly
  pending at once, you get a single summary banner instead of a flood.

## Prerequisites

- macOS
- [GitHub CLI](https://cli.github.com/) installed **and authenticated**:
  ```sh
  brew install gh      # if needed
  gh auth login
  ```
- Homebrew (optional) — only needed for clickable banners via
  `terminal-notifier`. Without it, the tool falls back to non-clickable
  `osascript` notifications.

## Install

```sh
git clone <this-folder>   # or copy the folder anywhere
cd gh-pr-review-notify
./install.sh
```

`install.sh` will:
1. Verify `gh` is installed and authenticated.
2. Install `terminal-notifier` via Homebrew (if available).
3. **Ask how often to check GitHub, in minutes** (e.g. `1`, `5`, `15`, or
   `0.5`). The prompt defaults to the interval you're already running, or 15
   minutes on a first install. Press Enter to accept the default.
4. **Ask which review requests should notify you** — (1) only when you're
   requested directly, or (2) also when a team you're on is requested. Defaults
   to direct-only. (GitHub's `review-requested:@me` matches both; the
   direct-only choice uses `user-review-requested:@me`.)
5. Generate a per-user launchd plist (`com.<you>.pr-review-notify`) with a
   `PATH` pointing at wherever your `gh` actually lives (asdf / Homebrew /
   system — auto-detected) and your chosen review scope.
6. Load the agent. It then runs immediately and on your chosen interval.

Re-run `./install.sh` anytime to change the interval or scope.

> For unattended installs (no terminal/CI), skip the prompts by setting
> `GH_PR_NOTIFY_INTERVAL` (seconds) and/or `GH_PR_NOTIFY_QUERY` before running.

## Configuration

All optional, via environment variables. For the **script** at runtime:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GH_PR_NOTIFY_QUERY` | `user-review-requested:@me --state=open` | Search args for `gh search prs`. Default is direct requests only; for team requests too use `--review-requested=@me --state=open`. (`install.sh` sets this from the scope prompt.) |
| `GH_PR_NOTIFY_LIMIT` | `50` | Max PRs fetched per run. |
| `GH_PR_NOTIFY_STATE_DIR` | `$XDG_STATE_HOME/gh-pr-review-notify` (or `~/.local/state/...`) | Where dedup state lives. |
| `GH_PR_NOTIFY_EXCLUDE_TITLE` | `DO NOT REVIEW\|WIP` | Case-insensitive regex of PR titles to skip. Set empty to disable. |
| `GH_PR_NOTIFY_INCLUDE_DRAFTS` | `0` | Set `1` to notify about draft PRs too. |
| `GH_PR_NOTIFY_SUMMARY_THRESHOLD` | `5` | If more than this many PRs are newly pending in one run, send a single summary banner instead of one per PR. `0` = always per-PR. |
| `GH_PR_NOTIFY_ICON` | bundled `gh-mark.png` | Image shown on the banner (path or URL). Empty for none. |

For the **installer**:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GH_PR_NOTIFY_INTERVAL` | _(prompted)_ | Poll interval in **seconds**. When set, the installer skips the interactive minutes prompt and uses this value — handy for unattended installs. |

To change runtime config permanently, set the variable in the plist's
`EnvironmentVariables` dict (or edit the script defaults) and re-run
`./install.sh`.

## Everyday commands

```sh
# Run a check right now (don't wait for the next tick)
launchctl kickstart -k gui/$(id -u)/com.$(id -un).pr-review-notify

# Watch the log
tail -f ~/Library/Logs/gh-pr-review-notify.log

# Confirm the agent is loaded
launchctl list | grep pr-review-notify

# Run the poller directly (useful for debugging)
./gh-pr-review-notify.sh
```

## Troubleshooting

- **No banners at all** — macOS notification permission. The first run may
  prompt you to allow notifications. Otherwise enable it in
  *System Settings → Notifications → terminal-notifier* (or *Script Editor* for
  the osascript fallback).
- **"GitHub CLI not authenticated" banner** — run `gh auth login`. The tool
  surfaces this instead of silently doing nothing when a token expires.
- **"GitHub CLI missing" banner** — `brew install gh`, then re-run
  `./install.sh`.
- **Rate limit / network errors** — logged to the log file; the run exits
  without touching the dedup state, so you won't get a flood of "new" banners
  when connectivity returns.
- **Banners not clickable** — `terminal-notifier` isn't installed. Install it
  (`brew install terminal-notifier`) and re-run `./install.sh`.

## Uninstall

```sh
./uninstall.sh
```

Or manually:

```sh
launchctl bootout gui/$(id -u)/com.$(id -un).pr-review-notify
rm ~/Library/LaunchAgents/com.$(id -un).pr-review-notify.plist
rm -rf ~/.local/state/gh-pr-review-notify
```

## License

[MIT](LICENSE) © William Lepinski
