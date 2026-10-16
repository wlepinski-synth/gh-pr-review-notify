# PR Reviews

A macOS menu bar app that keeps track of open pull requests waiting on your
review. Your pending reviews are split into a **Direct** tab (you were asked by
name) and a **Team** tab (a team you're on was asked), and you get a banner
when someone requests you directly.

It uses the GitHub CLI's own login (`gh auth login`). No tokens are stored
anywhere.

## What it does

The menu bar shows the GitHub mark followed by two counters: a person icon with
your direct requests and a two-person icon with your team requests. Click it to
open the list.

- **Direct tab**: PRs matching `user-review-requested:@me`.
- **Team tab**: PRs matching `review-requested:@me` that aren't direct. Each row
  shows which of your teams was asked (e.g. `growth`).
- Click a row to open the PR. The footer has refresh, open-on-GitHub, settings
  and quit buttons.
- Drafts and titles matching `DO NOT REVIEW|WIP` are hidden by default.
- **Banners** fire for direct requests only. You get one when a PR is newly
  requested or updated. On first launch the app records what's already pending
  so you don't get a flood. More than 5 new at once become a single summary
  banner.
- If `gh` fails (not logged in, network, rate limit), the icon switches to a
  warning triangle, the popover shows the reason, and the last good list stays
  visible. Polling backs off while errors continue.

## Prerequisites

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.
- [GitHub CLI](https://cli.github.com/), authenticated:
  ```sh
  brew install gh
  gh auth login
  ```

## Install

```sh
cd macos-app
./build.sh
open ~/Applications/"PR Reviews.app"
```

`build.sh` builds a release binary, wraps it in `PR Reviews.app`, signs it
ad-hoc and copies it to `~/Applications` (override with
`PR_REVIEWS_INSTALL_DIR`). It quits a running copy first, so re-run it after
pulling changes.

On first launch, allow notifications when macOS asks. Then open **Settings**
(gear icon) and turn on **Open at login**.

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| Check every N min | 1 | How often to poll GitHub. |
| Include draft PRs | off | Show drafts in both tabs. |
| Skip titles matching | `DO NOT REVIEW\|WIP` | Case-insensitive regex. Empty disables it. |
| gh path | auto | Leave blank to auto-detect (`/opt/homebrew/bin/gh`, `/usr/local/bin/gh`, `~/.asdf/shims/gh`). |
| Open at login | off | Registers the app as a login item. |

## Troubleshooting

- **No banners**: check *System Settings → Notifications → PR Reviews*. Banners
  only fire for direct requests; team requests just update the counter.
- **Warning triangle in the menu bar**: open the popover to see why. Usually
  `gh auth login` fixes it.
- **`gh` not found**: set its full path in Settings (`which gh` shows it).
- **Open at login fails**: make sure the app runs from `~/Applications` or
  `/Applications`, not from `macos-app/build`.

## Uninstall the app

```sh
pkill -x PRReviews
rm -rf ~/Applications/"PR Reviews.app"
rm -rf ~/Library/Application\ Support/PRReviews
defaults delete io.github.wlepinski-synth.pr-reviews
```

## License

[MIT](LICENSE) © William Lepinski
