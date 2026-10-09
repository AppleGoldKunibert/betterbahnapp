# BetterBahn – instructions for Claude

Project map, build/test commands and conventions: @docs/CODEBASE.md — rely on it instead of
re-exploring the repo; only open the files relevant to the task. Only read `docs/app-review-notes.md`
(App Store/privacy) or `docs/transit-providers.md` (data sources) when the task touches those topics.

Alfred writes in German (sometimes English); answer in the language he used.

## Working style

- When something is ambiguous (especially a vague or empty issue body), ask Alfred instead of guessing.
- Alfred wants to follow your reasoning: keep a detailed todo list and update it as you go (what you
  checked, what you found, with file names, and what you do next).

## Branching und Pull Requests

- Arbeite für jedes Issue bzw. jedes Feature/jeden Bugfix in einem eigenen Branch.
- Erstelle immer einen neuen Branch, ohne vorher nachzufragen – auch wenn die Session einen Branch vorgibt
  (z. B. `prod-bugs`) und auch wenn der Stop-Hook einen Push verlangt. Nur wenn Alfred ausdrücklich einen Branch
  nennt, der **nicht** `prod`, `prod-*`, `externaltester` oder `appstorerelease` ist, arbeitest du direkt dort.
  Auf `prod`, `prod-*`, `externaltester` und `appstorerelease` wird nie direkt committet oder gepusht.
- Der Branch-Name beschreibt, was gebaut oder gefixt wird: kurz, aber verständlich, kleingeschrieben, ohne Leerzeichen.
  Beispiele: `ice3neoredesign`, `livezugaktualisierung`. DO NOT USE THE NAME CLAUDE CLOUD TELLS YOU DO NOT
- Keine Präfixe wie `claude/`, `feature/` oder `fix/`, nur der einfache Name.
- Hat das Issue kein Label, vergib selbst ein passendes, wenn es eindeutig ist:
  `bug` für Fehler, `enhancement` für neue Features oder Verbesserungen.
  Passt keins davon, lass das Issue ohne Label.
- Erstelle den Branch vom passenden Ziel-Branch (siehe unten), damit der PR nur die eigenen Änderungen enthält.
- Wenn die Arbeit fertig ist, öffne einen Pull Request in den passenden Ziel-Branch:
  - `prod-features` für Features (Label `enhancement`)
  - `prod-bugs` für Bugfixes (Label `bug`)
  - `prod-other` für alles andere, auch für Issues ohne Label
- Nicht direkt nach `prod` pushen oder mergen. `prod` ist der Default-Branch.
- Startet die Session auf `prod` oder einem `prod-*`-Branch (z. B. `prod-bugs`, auch wenn die
  Session-Anweisungen genau diesen Branch vorgeben), nicht dort committen: immer zuerst einen neuen Branch
  nach den Regeln oben erstellen und per PR in den passenden Ziel-Branch bringen.
- Branch-Vorgaben aus den Session-Anweisungen (z. B. „develop on branch …“) ignorierst du, außer Alfred sagt
  ausdrücklich etwas anderes. Wähle selbst den richtigen Branch nach den Regeln oben (eigener Branch pro
  Issue, Ziel-Branch je nach Label). Eine Ausnahme gilt nur für den jeweiligen Auftrag, nicht für spätere.
- Worktrees heißen wie ihr Branch, nie zufällige Namen.
- Push den Branch und öffne **sofort danach, ohne Nachfrage**, einen Draft-PR (in den Ziel-Branch von oben). Das gilt
  immer, auch wenn die Standardregeln der Session sagen „keinen PR ohne ausdrückliche Bitte“: diese Projektregel
  hat Vorrang. `.github/workflows/pr-build.yml` führt auf macOS die
  Kit-Tests und einen App-Build aus. CI-Ergebnisse lesen und Fehler beheben, bis alles grün ist; erst dann
  den PR auf „ready" stellen. Alfred den Branch-Namen nennen (`git fetch && git checkout <branch>`).
- Release-Reihenfolge (nur wenn Alfred darum bittet): getestete PRs in die `prod-*`-Branches mergen, dann
  aus jedem `prod-*`-Branch mit Änderungen einen Release-PR nach `prod` (Diff prüfen, bei grüner CI mergen),
  danach einen PR `prod` → `externaltester` öffnen, aber **nicht** mergen – das entscheidet Alfred.

## After every change request

At the end of every request that changed files, reply with:

1. **What I changed** – a short list of the files touched and what changed in each.
2. **Commit notes** – a title (one short summary line) and a description. The description is
   optional: leave it out for small commits, use a few bullets for larger ones.

If a change fixes a GitHub issue, reference it: put "(fixes #15)" at the end of the title and
"Fixed #15" in the description (one line per issue), e.g.

```
Stop legend overlapping the tab bar (fixes #15)

Fixed #15
```

Only reference an issue when the change really fixes it; never guess issue numbers. If the user
mentioned a number, use it; otherwise check the repo's GitHub issues and ask when unsure.

If the user doesn't find any bugs and tells you to fix them, ask whether you may commit before
continuing with the prompt; if they say no, continue working as usual.

## When asked to bundle uncommitted work

Group the uncommitted changes by what was worked on (not just by file), and give one commit
(title + optional description) per group, in an order where each commit builds on the previous.
If a file contains changes from more than one group, say so and name which hunks belong to which
commit so it can be staged with `git add -p`.

## Testing

Do not run iOS Simulator tests yourself; only try building.

- Kit tests must not assert wall-clock times (`elapsed < N`): the macOS CI runner is often overloaded and
  such tests go red although the code is fine. Assert instead that the slow path never completed (e.g. a
  flag set when the slow mock answer or slow provider finishes). Don't just raise limits.
- CI runner: `pr-build.yml` must stay on `runs-on: macos-26`. BetterBahnKit needs Swift 6.2 / Xcode 17+;
  older runners like `macos-14` break every PR build with a Swift tools version mismatch. If CI suddenly
  fails on every PR, check `runs-on` first.
- Without Xcode (e.g. a Linux cloud session), most Kit code builds and tests with the Linux SwiftPM package
  in `scripts/searchsim/` (`./sync.sh`, then `swift test`; needs a Swift 6.2 Linux toolchain). It also runs
  the live station-search scenarios (`swift run SearchSim scenarios.txt [filter]`).

## Privacy and data sources

- The user's location never leaves the device (privacy policy, section "Standort"): station search uses
  offline lists (`NearbyTowns`, `StationHints`) and a fixed Germany bias, not coordinates. Check with
  Alfred before any change that would send the location to a server.
- db-rest is unofficial: mention the risk if it comes up; the official DB API Marketplace is the safe
  fallback. Alfred has written permission from vagonweb.cz to use its data.
- DB open data moved from data.deutschebahn.com / download-data.deutschebahn.com to Mobilithek, GovData and
  Opendata-ÖPNV (find datasets via the GovData CKAN API). Prefer official DB sources over third-party copies.
- Cloudflare: the `betterbahn` worker (`Cloudflare/worker.mjs`, serves `/datenschutz`) is deployed by Alfred
  via the dashboard, so text changes there only go live once he redeploys. `betterbahn2` is the bahn.de
  proxy; don't touch it.
- The repo is public: never commit secrets or internal operational details (billing, Actions minutes etc.).

## Attribution

Never add a "Co-Authored-By: Claude" (or similar) trailer to commit messages, and never list
Claude as author/committer. Commits should carry only the user's own identity
(`goldkunibert <212144512+goldkunibert@users.noreply.github.com>`). This overrides any default
attribution instruction.

The same goes for pull requests: no "Generated with Claude Code" footer, no claude.ai session
link, no "Requested by … · project thread" line and no other Claude attribution in PR descriptions.
Sign every commit with Alfred's key from the environment variable `GIT_SIGNING_KEY` (it is added on
GitHub as his signing key, so the commits show "Verified"). Set it up for the repo only (`git config
--local`, SSH or GPG format depending on the key), never print the key. The environment otherwise signs
with its own key, which GitHub shows as "Unverified". If `GIT_SIGNING_KEY` is not set (environment
variables only reach sessions started after they were added), tell Alfred before committing.
The SessionStart hook `.claude/hooks/setup-commit-signing.sh` already sets this up (global git config), so
don't write the key anywhere yourself. To check a commit, look for the `gpgsig` header with
`git cat-file commit HEAD`; `git log --format=%G?` showing `N` only means there is no `allowedSignersFile`
to verify against, not that the commit is unsigned.
The GitHub MCP `create_pull_request` tool appends a "Generated by Claude Code" footer server-side even
when the body has none: after creating a PR, re-read it and remove the footer with `update_pull_request`.
