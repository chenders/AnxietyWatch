# Respond to Copilot

Review and respond to GitHub Copilot review comments on a pull request. Loops until Copilot has no new comments.

## Arguments

- `$ARGUMENTS` - PR number or branch name (optional, defaults to current branch)

## Instructions

### Per-round steps

1. **Identify the PR**
   - If PR number provided, use directly
   - Otherwise find PR for current branch via `gh pr view`

2. **Fetch all review comments from BOTH endpoints**

   Copilot posts comments via two different mechanisms. You MUST check both:

   **Endpoint A — PR-level comments** (inline diff comments):
   ```bash
   gh api --paginate repos/chenders/AnxietyWatch/pulls/{pr_number}/comments --jq '.[] | {id, body, path, line}'
   ```

   **Endpoint B — Review-attached comments** (comments posted as part of a review):
   ```bash
   # First get all review IDs from Copilot
   REVIEW_IDS=$(gh api --paginate repos/chenders/AnxietyWatch/pulls/{pr_number}/reviews --jq '.[] | select(.user.login == "copilot-pull-request-reviewer[bot]") | .id')

   # Then fetch comments for each review
   for rid in $REVIEW_IDS; do
     gh api --paginate repos/chenders/AnxietyWatch/pulls/{pr_number}/reviews/$rid/comments --jq '.[] | {id, body, path, line}'
   done
   ```

   Merge the results from both endpoints, deduplicating by comment ID (the same comment may appear in both).

3. **Check for new comments** — If there are no new unaddressed comments (from either endpoint) since the last round, the loop is done. Report the final status and stop.

4. **Analyze each new comment**
   - Validity: Is the suggestion technically correct?
   - Value: Would it improve code quality?
   - Scope: Is it within the scope of this PR?

5. **Categorize**: Will implement / Won't implement / Needs discussion

6. **Implement accepted suggestions**
   - Make changes, run linting (`flake8 server/ --max-line-length=120` for Python)
   - Commit: "Address Copilot review feedback"
   - Push changes

7. **Reply to each comment**

   ```bash
   gh api -X POST repos/chenders/AnxietyWatch/pulls/{pr_number}/comments/{id}/replies -f body="Fixed in $(git rev-parse --short HEAD). Explanation."
   ```

8. **Resolve implemented threads** (use PRRT* thread IDs, not PRRC* comment IDs)

   ```bash
   # Get thread IDs
   gh api graphql -f query='query { repository(owner: "chenders", name: "AnxietyWatch") { pullRequest(number: {pr_number}) { reviewThreads(first: 50) { nodes { id isResolved comments(first: 1) { nodes { body } } } } } } }'

   # Resolve
   gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "PRRT_..."}) { thread { isResolved } } }'
   ```

   Rules:
   - Resolve threads where you implemented the fix
   - Do NOT resolve threads where you declined

9. **Re-request Copilot review** — capture the review count BEFORE re-requesting to avoid a race condition where the review arrives instantly:

   ```bash
   # Capture baseline FIRST
   BEFORE_COUNT=$(gh api repos/chenders/AnxietyWatch/pulls/{pr_number}/reviews --jq 'length')

   # Then re-request
   gh api repos/chenders/AnxietyWatch/pulls/{pr_number}/requested_reviewers -X POST -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
   ```

10. **Wait for the new review** — Poll until review count exceeds `BEFORE_COUNT`:

    ```bash
    gh api repos/chenders/AnxietyWatch/pulls/{pr_number}/reviews --jq 'length'
    ```

    Poll every 15 seconds. Timeout after 5 minutes (assume review is delayed).

    **CRITICAL:** The baseline count MUST be captured before re-requesting (step 9). If captured after, the new review may already be included, causing the poll to never trigger.

11. **Loop back to step 2** — Fetch comments again and check for new ones.

### Completion criteria

The loop ends when:

- Copilot's latest review has **no new comments** (clean review), OR
- The poll in step 10 times out (report this and stop)

When complete, report a summary: total rounds, comments addressed, comments declined.

## Notes

- Never dismiss suggestions without explanation
- Never defer work without explicit user approval
- Thread IDs (PRRT*) are NOT the same as comment IDs (PRRC*)
- Track comment IDs across rounds to distinguish new comments from previously addressed ones
- **CRITICAL:** GitHub has two comment endpoints — `pulls/{pr_number}/comments` (PR-level) and `pulls/{pr_number}/reviews/{review_id}/comments` (review-level). Copilot uses BOTH. Always check both endpoints or you will miss comments.
