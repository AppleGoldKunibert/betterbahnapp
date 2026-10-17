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
