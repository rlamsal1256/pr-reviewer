#!/usr/bin/env bash
# PR Reviewer Configuration
# Copy this to config.sh and fill in your values:
#   cp config.example.sh config.sh

# GitHub repos to watch (owner/repo format, space-separated)
REPOS="your-org/your-repo"

# Where to save review output
REVIEWS_DIR="$HOME/.pr-reviews"

# State file tracking which PRs have been reviewed
STATE_FILE="$HOME/.config/pr-reviewer/state.json"

# Log file
LOG_FILE="$HOME/.config/pr-reviewer/reviewer.log"

# Post review as a GitHub PR comment? (true/false)
POST_TO_GITHUB=false

# Maximum diff size in characters to send to Claude (avoid token limits)
MAX_DIFF_SIZE=200000

# Claude model to use (sonnet for speed/cost, opus for depth, haiku for cheap)
CLAUDE_MODEL="sonnet"

# Max budget per review in USD
MAX_BUDGET_PER_REVIEW="0.50"
