#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Initialize state file if missing
if [[ ! -f "$STATE_FILE" ]]; then
    echo '{}' > "$STATE_FILE"
fi

# Initialize last-checked marker if missing
LAST_CHECKED_FILE="$HOME/.config/pr-reviewer/last_checked"
touch "$LAST_CHECKED_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

notify() {
    local title="$1"
    local message="$2"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

log "=== PR review check started ==="

REVIEWS_THIS_RUN=0
ERRORS_THIS_RUN=0
REVIEWED_PRS=""

for REPO in $REPOS; do
    log "Checking $REPO for open PRs..."

    # Fetch open PRs with metadata
    PRS_JSON=$(gh pr list \
        --repo "$REPO" \
        --state open \
        --json number,title,updatedAt,headRefName,author,body,additions,deletions \
        --limit 50 2>&1) || {
        log "ERROR: Failed to fetch PRs for $REPO: $PRS_JSON"
        continue
    }

    PR_COUNT=$(echo "$PRS_JSON" | jq length)
    log "Found $PR_COUNT open PRs in $REPO"

    # Load current state
    STATE=$(cat "$STATE_FILE")

    echo "$PRS_JSON" | jq -c '.[]' | while read -r PR; do
        PR_NUM=$(echo "$PR" | jq -r '.number')
        PR_TITLE=$(echo "$PR" | jq -r '.title')
        PR_UPDATED=$(echo "$PR" | jq -r '.updatedAt')
        PR_BRANCH=$(echo "$PR" | jq -r '.headRefName')
        PR_AUTHOR=$(echo "$PR" | jq -r '.author.login')
        PR_BODY=$(echo "$PR" | jq -r '.body // ""')
        PR_ADDITIONS=$(echo "$PR" | jq -r '.additions')
        PR_DELETIONS=$(echo "$PR" | jq -r '.deletions')

        STATE_KEY="${REPO//\//_}_${PR_NUM}"
        LAST_REVIEWED=$(echo "$STATE" | jq -r ".\"$STATE_KEY\" // \"\"")

        if [[ "$LAST_REVIEWED" == "$PR_UPDATED" ]]; then
            log "PR #$PR_NUM ($PR_TITLE) - no changes since last review, skipping"
            continue
        fi

        log "PR #$PR_NUM ($PR_TITLE) - new or updated, reviewing..."

        # Fetch the diff
        DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>&1) || {
            log "ERROR: Failed to fetch diff for PR #$PR_NUM: $DIFF"
            echo "error" >> /tmp/pr-reviewer-errors.$$
            continue
        }

        # Truncate diff if too large
        DIFF_SIZE=${#DIFF}
        if (( DIFF_SIZE > MAX_DIFF_SIZE )); then
            log "WARNING: Diff for PR #$PR_NUM is ${DIFF_SIZE} chars, truncating to ${MAX_DIFF_SIZE}"
            DIFF="${DIFF:0:$MAX_DIFF_SIZE}

... [DIFF TRUNCATED - original size: ${DIFF_SIZE} chars] ..."
        fi

        # Fetch review comments and existing reviews for context
        EXISTING_COMMENTS=$(gh pr view "$PR_NUM" --repo "$REPO" --json reviews --jq '.reviews | length' 2>/dev/null || echo "0")

        # Prepare output directory
        REPO_SAFE="${REPO//\//_}"
        OUTPUT_DIR="$REVIEWS_DIR/$REPO_SAFE/$PR_NUM"
        mkdir -p "$OUTPUT_DIR"

        # Build the review prompt
        REVIEW_PROMPT=$(cat << PROMPT
You are reviewing a pull request. Be concise and actionable.

## PR Details
- **Repository:** $REPO
- **PR #$PR_NUM:** $PR_TITLE
- **Branch:** $PR_BRANCH
- **Author:** $PR_AUTHOR
- **Size:** +$PR_ADDITIONS / -$PR_DELETIONS lines
- **Existing reviews:** $EXISTING_COMMENTS

## PR Description
$PR_BODY

## Diff
\`\`\`diff
$DIFF
\`\`\`

## Review Instructions
1. **Summary**: One sentence describing what this PR does.
2. **Risk Assessment**: Low / Medium / High — and why.
3. **Issues Found**: List bugs, security concerns, logic errors, or missed edge cases. Be specific with file paths and line references.
4. **Suggestions**: Style, naming, simplification, or test coverage improvements.
5. **Verdict**: APPROVE / REQUEST_CHANGES / COMMENT — with brief rationale.

Focus on real problems. Skip nitpicks about formatting if a formatter is in use. Do not mention things that are fine.
PROMPT
)

        # Run the review
        log "Running Claude review for PR #$PR_NUM..."
        REVIEW_OUTPUT=$(echo "$REVIEW_PROMPT" | claude \
            --print \
            --model "$CLAUDE_MODEL" \
            --max-budget-usd "$MAX_BUDGET_PER_REVIEW" \
            --verbose 2>&1) || {
            log "ERROR: Claude review failed for PR #$PR_NUM"
            echo "$REVIEW_OUTPUT" > "$OUTPUT_DIR/error_$(date '+%Y%m%d_%H%M%S').txt"
            echo "error" >> /tmp/pr-reviewer-errors.$$
            continue
        }

        # Extract verdict from review
        VERDICT=$(echo "$REVIEW_OUTPUT" | grep -oiE '(APPROVE|REQUEST_CHANGES|COMMENT)' | head -1 || echo "UNKNOWN")

        # Save review locally
        REVIEW_FILE="$OUTPUT_DIR/review_$(date '+%Y%m%d_%H%M%S').md"
        cat > "$REVIEW_FILE" << REVIEWEOF
# Review: PR #$PR_NUM — $PR_TITLE
- **Repo:** $REPO
- **Author:** $PR_AUTHOR
- **Branch:** $PR_BRANCH
- **Reviewed:** $(date '+%Y-%m-%d %H:%M:%S')
- **Size:** +$PR_ADDITIONS / -$PR_DELETIONS
- **Verdict:** $VERDICT

---

$REVIEW_OUTPUT
REVIEWEOF

        log "Review saved to $REVIEW_FILE"

        # Track this review for the summary notification
        echo "#$PR_NUM ($VERDICT)" >> /tmp/pr-reviewer-completed.$$

        # Optionally post to GitHub
        if [[ "$POST_TO_GITHUB" == "true" ]]; then
            COMMENT_BODY=$(cat << COMMENTEOF
## Automated PR Review

$REVIEW_OUTPUT

---
*Generated by pr-reviewer at $(date '+%Y-%m-%d %H:%M:%S')*
COMMENTEOF
)
            gh pr comment "$PR_NUM" --repo "$REPO" --body "$COMMENT_BODY" 2>&1 && \
                log "Posted review to GitHub for PR #$PR_NUM" || \
                log "ERROR: Failed to post review to GitHub for PR #$PR_NUM"
        fi

        # Update state
        jq --arg key "$STATE_KEY" --arg val "$PR_UPDATED" '. + {($key): $val}' "$STATE_FILE" > "${STATE_FILE}.tmp" \
            && mv "${STATE_FILE}.tmp" "$STATE_FILE"

        log "PR #$PR_NUM review complete"
    done
done

# Send summary notification if any reviews happened
COMPLETED_COUNT=0
ERROR_COUNT=0
if [[ -f /tmp/pr-reviewer-completed.$$ ]]; then
    COMPLETED_COUNT=$(wc -l < /tmp/pr-reviewer-completed.$$ | tr -d ' ')
    COMPLETED_LIST=$(cat /tmp/pr-reviewer-completed.$$)
    rm -f /tmp/pr-reviewer-completed.$$
fi
if [[ -f /tmp/pr-reviewer-errors.$$ ]]; then
    ERROR_COUNT=$(wc -l < /tmp/pr-reviewer-errors.$$ | tr -d ' ')
    rm -f /tmp/pr-reviewer-errors.$$
fi

if (( COMPLETED_COUNT > 0 )); then
    SUMMARY="${COMPLETED_COUNT} PR(s) reviewed"
    if (( ERROR_COUNT > 0 )); then
        SUMMARY="$SUMMARY, ${ERROR_COUNT} error(s)"
    fi
    notify "PR Reviewer" "$SUMMARY"
    log "Notification sent: $SUMMARY"
fi

log "=== PR review check finished (${COMPLETED_COUNT} reviewed, ${ERROR_COUNT} errors) ==="
