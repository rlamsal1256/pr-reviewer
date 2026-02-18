# pr-reviewer

Automated PR review tool that polls GitHub for new/updated pull requests and reviews them using Claude Code. Runs locally on macOS via `launchd`.

## How it works

A shell script runs on a schedule via macOS `launchd`. Each cycle it:

1. Fetches open PRs from configured repos using `gh pr list`
2. Compares each PR's `updatedAt` against a local state file
3. For new or updated PRs, fetches the diff and sends it to `claude -p` for review
4. Saves reviews locally to `~/.pr-reviews/`
5. Optionally posts reviews as GitHub PR comments
6. Sends a macOS notification summarizing what was reviewed

## Prerequisites

- macOS
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- `jq`

## Setup

1. Clone:

```sh
git clone git@github.com:YOUR_USER/pr-reviewer.git ~/.config/pr-reviewer
```

2. Run the install script (creates config, generates launchd plist, symlinks CLI):

```sh
cd ~/.config/pr-reviewer
./install.sh
```

3. Edit `config.sh` with your repos:

```sh
REPOS="your-org/your-repo another-org/another-repo"
```

4. Run install again to start the scheduler:

```sh
./install.sh
```

## Usage

### Summary command

```sh
pr-reviews          # Reviews since you last checked (marks as read)
pr-reviews all      # All reviews from today
pr-reviews pr 123   # Full review for a specific PR
pr-reviews status   # Job status, counts, last run
pr-reviews log      # Live tail of the reviewer log
```

### Run manually

```sh
~/.config/pr-reviewer/review.sh
```

### Stop/start the scheduler

```sh
launchctl unload ~/Library/LaunchAgents/com.pr-reviewer.plist
launchctl load ~/Library/LaunchAgents/com.pr-reviewer.plist
```

### Reset state (re-review all PRs)

```sh
echo '{}' > ~/.config/pr-reviewer/state.json
```

## Configuration

Edit `config.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `REPOS` | — | Space-separated `owner/repo` list to watch |
| `POST_TO_GITHUB` | `false` | Post reviews as PR comments |
| `MAX_DIFF_SIZE` | `200000` | Truncate diffs beyond this char count |
| `CLAUDE_MODEL` | `sonnet` | Claude model (`sonnet`, `opus`, `haiku`) |
| `MAX_BUDGET_PER_REVIEW` | `0.50` | Max USD per review |

Poll interval is set in `install.sh` (default 900s = 15 minutes).

## File structure

```
~/.config/pr-reviewer/
  config.example.sh   # Example config (tracked)
  config.sh           # Your config (gitignored)
  review.sh           # Polling + review script
  pr-reviews          # Summary CLI tool
  install.sh          # Setup script
  state.json          # Tracks reviewed PRs (gitignored)
  reviewer.log        # Log file (gitignored)

~/.pr-reviews/        # Review output
  <owner_repo>/
    <pr_num>/
      review_YYYYMMDD_HHMMSS.md
```

## Cost

With Sonnet, each review costs ~$0.03-0.12 depending on diff size. At ~10 PR updates/day, expect ~$5-15/month. Use `haiku` for ~10x cheaper.
