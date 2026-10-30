# Re-Review nach Änderungen

After pushing new commits to a PR that already has a review containing `<!-- auto-review -->`, request a re-review. Do this only for real code changes, not after merging the base branch, rebasing, or resolving conflicts. Skip it for draft PRs.

Replace `<number>` with the PR number and `<sha>` with the full 40-character head SHA, then run:

    curl -sS -X POST "https://api.anthropic.com/v1/claude_code/routines/$REVIEW_FIRE_ID/fire" \
      -H "Authorization: Bearer $REVIEW_FIRE_TOKEN" \
      -H "anthropic-beta: experimental-cc-routine-2026-04-01" \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" \
      -d '{"text": "PR #<number> head <sha>"}'

`REVIEW_FIRE_ID` is the routine id (`trig_…`), `REVIEW_FIRE_TOKEN` its token. If either is not set or the call fails, skip this step silently. Never print the token.
