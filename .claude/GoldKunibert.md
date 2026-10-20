# Personal instructions for GoldKunibert

Read on top of `.claude/CLAUDE.md` when you commit as the GitHub account `goldkunibert`. Everything in
CLAUDE.md still applies; this file only adds GoldKunibert's own preferences and setup.

## Language and working style

- GoldKunibert writes in German (sometimes English); answer in the language of the message.
- Keep a detailed todo list so GoldKunibert can follow your reasoning, and update it as you go (what you
  checked, what you found, with file names, and what you do next).
- When something is ambiguous, ask instead of guessing.

## Project decisions

- GoldKunibert owns the project: changes that would send the user's location to a server, merging into
  `externaltester` and redeploying the `betterbahn` Worker via the Cloudflare dashboard are GoldKunibert's calls.
- When bahn.de data is needed (see "Privacy and data sources" in CLAUDE.md), give GoldKunibert the complete
  `curl_cffi` command to run on the Mac and ask for the output to be pasted.
- GoldKunibert tests only on the iPhone: write "What to test" (in the reply and in the test list) for the
  iPhone, not the Simulator. A step that needs a launch argument says to run the debug build from Xcode on it.

## Test list

GoldKunibert ticks off manual tests on a page in the Claude app, the test list:
https://claude.ai/artifact/XjniwecXJwksebeNGk7xuh (only GoldKunibert can open it). Read and write its database
with the `ArtifactData` tool (load it with ToolSearch).

- One document per PR in collection `prs`, id `pr<number>` (`pr413`): `number`, `title`, `branch`, `issues`
  (numbers), `state` (`draft`, `open`, `merged` or `closed`), `updatedAt` (ISO 8601), `sessions` (links of the
  chats that worked on the PR, oldest first) and `steps`, a map `s1`, `s2`, … of
  `{order, text, expect, status, note, checkedAt, retest}`. Your own chat link is
  `https://claude.ai/code/<id>` with the id from `get_session` (claude-code-remote, without `session_id`); add it
  when it isn't in `sessions` yet (`update` replaces the whole array). `text` (what to do, starting from where in
  the app) and `expect` (what should happen) are German. A new step is `status: "open"`, `note: ""`,
  `checkedAt: null`, `retest: false`.
- When you open a PR, write the steps of your "What to test" there (`set`). After later pushes, `update` with
  the `if_version` you read: add steps for new behaviour, keep `title`, `state` and `updatedAt` current, and
  only when a push changes what a ticked step covers, set that step back to `status: "open"` with
  `retest: true`. Don't touch `status`, `note` or `checkedAt` otherwise: they are GoldKunibert's results.
- A step with `status: "failed"` and a `note` is a bug report for that PR: read the PR's document before
  working on it again, fix it, then set the step to `open` with `retest: true`.
- When a PR is merged or closed, set `state` to `merged` or `closed` (several PRs at once in one `batch`).
- "Tested PRs" in a release are the ones whose steps are all `passed`.

## Commit identity and signing

Commits carry only this identity: `goldkunibert <212144512+goldkunibert@users.noreply.github.com>`.

Sign every commit with the key from the environment variable `GIT_SIGNING_KEY` (it is added on GitHub as
the account's signing key, so the commits show "Verified"). Set it up for the repo only (`git config
--local`, SSH or GPG format depending on the key), never print the key. The environment otherwise signs
with its own key, which GitHub shows as "Unverified". If `GIT_SIGNING_KEY` is not set (environment
variables only reach sessions started after they were added), tell GoldKunibert before committing.
The SessionStart hook `.claude/hooks/setup-commit-signing.sh` already sets this up (global git config), so
don't write the key anywhere yourself. To check a commit, look for the `gpgsig` header with
`git cat-file commit HEAD`; `git log --format=%G?` showing `N` only means there is no `allowedSignersFile`
to verify against, not that the commit is unsigned.
