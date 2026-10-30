Re-review after changes

After pushing new commits to a PR that already has a review containing <!-- auto-review -->, request a re-review. Do this only for real code changes, not after merging the base branch, rebasing, or resolving conflicts. Skip it for draft PRs.

curl -sS -X POST "https://api.anthropic.com/v1/claude_code/routines/trig_01XJWjv517CHJ9d11ykse284/fire"
-H "Authorization: Bearer $REVIEW_FIRE_TOKEN"
-H "anthropic-beta: experimental-cc-routine-2026-04-01"
-H "anthropic-version: 2023-06-01"
-H "Content-Type: application/json"
-d '{"text": "PR # head "}'

If REVIEW_FIRE_TOKEN is not set or the call fails, skip this step silently. Never print the token.
