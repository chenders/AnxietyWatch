# Respond to Copilot

Review and respond to GitHub Copilot review comments on a pull request. Loops until Copilot has no new comments.

## Arguments

- `$ARGUMENTS` - PR number or branch name (optional, defaults to current branch)

## Instructions

### Per-round steps

1. **Identify the PR**
   - If PR number provided, use directly
   - Otherwise find PR for current branch via `gh pr view`

2. **Fetch all review comments**

   ```bash
   gh api repos/chenders/AnxietyScope/pulls/{pr_number}/comments | jq '.[] | {id, body, path, line}'
   ```

3. **Check for new comments** — If there are no new unaddressed comments since the last round, the loop is done. Report the final status and stop.

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
   gh api -X POST repos/chenders/AnxietyScope/pulls/{pr}/comments/{id}/replies -f body="Fixed in $(git rev-parse --short HEAD). Explanation."
   ```

8. **Resolve implemented threads** (use PRRT* thread IDs, not PRRC* comment IDs)

   ```bash
   # Get thread IDs
   gh api graphql -f query='query { repository(owner: "chenders", name: "AnxietyScope") { pullRequest(number: PR) { reviewThreads(first: 50) { nodes { id isResolved comments(first: 1) { nodes { body } } } } } } }'

   # Resolve
   gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "PRRT_..."}) { thread { isResolved } } }'
   ```

   Rules:
   - Resolve threads where you implemented the fix
   - Do NOT resolve threads where you declined

9. **Re-request Copilot review**:

   ```bash
   gh api repos/chenders/AnxietyScope/pulls/{PR_NUMBER}/requested_reviewers -X POST -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
   ```

10. **Wait for the new review** — Poll until a new review appears (review count increases):

    ```bash
    gh api repos/chenders/AnxietyScope/pulls/{PR_NUMBER}/reviews --jq 'length'
    ```

    Poll every 15 seconds. Timeout after 5 minutes (assume review is delayed).

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
