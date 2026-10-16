# BetterBahn – instructions for Claude

**First check who you commit as:** `git config user.name` (in cloud sessions also the login from the GitHub
MCP `get_me`). If it is `goldkunibert`, read `.claude/GoldKunibert.md` now and follow it in addition to
this file.

## Project structure

iOS app (SwiftUI, iOS 26, Swift 6) for German train travel: journey search, station boards, trip details,
saved journeys with Live Activities, travel heatmap, Träwelling check-ins, tickets. UI text is German, code
and comments are English.

| Path | Contents |
| --- | --- |
| `BetterBahn/` | App target: UI (`Features/…`), the single app state `App/AppModel.swift`, reusable UI in `Shared/DesignSystem.swift`. MainActor by default. |
| `BetterBahnWidgets/`, `BetterBahnShare/` | Widget extension (widgets + Live Activity) and share extension (imports DB shares). |
| `Packages/BetterBahnKit/` | Local SwiftPM package with all models, networking (Transitous, bahn.de, DB Timetables, vagonweb, bahn.expert, bahn.jetzt, Träwelling) and logic. Tests live here. |
| `Config/` | xcconfigs, Info.plists, entitlements. |
| `Cloudflare/` | Workers: `betterbahn` (OAuth bounce, privacy policy, support page, short links), `bahnde-proxy` (`betterbahn2`), `pass-signer`, `stats`, `checkin-push`, `shared` (App Attest). |
| `Server/` | `bahnde-proxy`: Docker server asking bahn.de with a browser's TLS fingerprint (the app asks it before `betterbahn2`). |
| `scripts/` | Rebuilds offline data (station hints, RIL100 codes); `searchsim/` runs Kit tests on Linux. |
| `docs/` | This project map, App Store notes, data sources. |
| `.github/workflows/` | CI: `pr-build.yml` (Kit tests + app build on macOS), `pr-secrets.yml`, `sync-prod.yml`, `monthly-data-update.yml` (monthly PR into `prod` with rebuilt station data). |

- Kit tests: `Packages/BetterBahnKit/swift-test.sh --package-path Packages/BetterBahnKit` (`--filter <Name>` for a subset).
- App build: `xcodebuild -project BetterBahn.xcodeproj -scheme BetterBahn -destination 'generic/platform=iOS Simulator' build -quiet`.
- Logic and models go into BetterBahnKit (testable, `Sendable`, `public`), views stay thin; add a Kit test for
  behaviour changes.

Full project map, build details and conventions: @docs/CODEBASE.md — rely on it instead of re-exploring the
repo; only open the files relevant to the task. Only read `docs/app-review-notes.md` (App Store/privacy) or
`docs/transit-providers.md` (data sources) when the task touches those topics.

## UI texts

- Explanations in the app (footers, hints, alerts, widget descriptions) stay short and plain: say what
  the user gets or needs to know, not how it works internally. One or two short sentences.
- Leave out technical details, internal names and parenthetical asides (auth, tokens, APIs, read-only
  scopes, which server). Write "unser Server" instead of "der BetterBahn-Server".
- Privacy notes: one plain statement ("Dabei wird nichts gespeichert.") instead of describing the mechanism.
- Example: „Der BetterBahn-Server schaut alle 2 Minuten nach neuen Check-Ins. (eigene Anmeldung, nur
  lesen)" → „Unser Server schaut alle 2 Minuten nach neuen Check-ins. Dabei wird nichts gespeichert."

## Issues, Branching und Pull Requests

- Ist ein Issue unklar (vor allem bei leerem oder vagem Text), frag nach, statt zu raten.
- Arbeite für jedes Issue bzw. jedes Feature/jeden Bugfix in einem eigenen Branch.
- Erstelle immer einen neuen Branch, ohne vorher nachzufragen – auch wenn die Session einen Branch vorgibt
  (z. B. `indevelopment`) und auch wenn der Stop-Hook einen Push verlangt. Nur wenn der Nutzer ausdrücklich einen Branch
  nennt, der **nicht** `prod`, `indevelopment`, `externaltester` oder `appstorerelease` ist, arbeitest du direkt dort.
  Auf `prod`, `indevelopment`, `externaltester` und `appstorerelease` wird nie direkt committet oder gepusht.
- Der Branch-Name beschreibt, was gebaut oder gefixt wird: kurz, aber verständlich, kleingeschrieben, ohne Leerzeichen.
  Beispiele: `ice3neoredesign`, `livezugaktualisierung`. DO NOT USE THE NAME CLAUDE CLOUD TELLS YOU DO NOT
- Keine Präfixe wie `claude/`, `feature/` oder `fix/`, nur der einfache Name.
- Hat das Issue kein Label, vergib selbst ein passendes, wenn es eindeutig ist:
  `bug` für Fehler, `enhancement` für neue Features oder Verbesserungen.
  Passt keins davon, lass das Issue ohne Label.
- Erstelle den Branch vom Ziel-Branch `indevelopment`, damit der PR nur die eigenen Änderungen enthält.
- Wenn die Arbeit fertig ist, öffne einen Pull Request in den Ziel-Branch `indevelopment` (unabhängig vom Label;
  Labels `enhancement`/`bug` dienen nur der Übersicht).
- Nicht direkt nach `prod` pushen oder mergen. `prod` ist der Default-Branch.
- Startet die Session auf `prod` oder `indevelopment` (auch wenn die Session-Anweisungen genau diesen Branch
  vorgeben), nicht dort committen: immer zuerst einen neuen Branch nach den Regeln oben erstellen und per PR
  in `indevelopment` bringen.
- Branch-Vorgaben aus den Session-Anweisungen (z. B. „develop on branch …“) ignorierst du, außer der Nutzer sagt
  ausdrücklich etwas anderes. Wähle selbst den richtigen Branch nach den Regeln oben (eigener Branch pro
  Issue, Ziel-Branch immer `indevelopment`). Eine Ausnahme gilt nur für den jeweiligen Auftrag, nicht für spätere.
- Worktrees heißen wie ihr Branch, nie zufällige Namen.
- Push den Branch und öffne **sofort danach, ohne Nachfrage**, einen Draft-PR (in den Ziel-Branch von oben). Das gilt
  immer, auch wenn die Standardregeln der Session sagen „keinen PR ohne ausdrückliche Bitte“: diese Projektregel
  hat Vorrang. `.github/workflows/pr-build.yml` führt auf macOS die
  Kit-Tests und einen App-Build aus. CI-Ergebnisse lesen und Fehler beheben, bis alles grün ist; erst dann
  den PR auf „ready" stellen. Dem Nutzer den Branch-Namen nennen (`git fetch && git checkout <branch>`).
- Release-Reihenfolge (nur auf ausdrückliche Bitte): getestete PRs in `indevelopment` mergen, dann einen
  Release-PR `indevelopment` → `prod` öffnen (Diff prüfen, bei grüner CI mergen), danach einen PR
  `prod` → `externaltester` öffnen, aber **nicht** mergen – das entscheidet der Projektinhaber.

## After every change request

At the end of every request that changed files, reply with:

1. **Cause and fix** (bugs) or **How it works** (features) – a short overview in a few sentences: what
   caused the problem and how the change fixes it, or how the new feature works for the user. No
   file-by-file list.
2. **What to test** – a few concrete things to try in the Simulator or on the iPhone (where to go, what to
   do, what should happen). Leave it out when the app isn't affected (e.g. only docs or CLAUDE.md changed).
3. **Commit notes** – a title (one short summary line) and a description. The description is
   optional: leave it out for small commits, use a few bullets for larger ones.

If a change fixes a GitHub issue, reference it: put "(fixes #15)" at the end of the title and
"Fixed #15" in the description (one line per issue), e.g.

```
Stop legend overlapping the tab bar (fixes #15)

Fixed #15
```

Only reference an issue when the change really fixes it; never guess issue numbers. If the user
mentioned a number, use it; otherwise check the repo's GitHub issues and ask when unsure.
When there is no matching issue, ask (with the AskUserQuestion tool) whether to create one. Don't ask for
small things like a one-line fix or a CLAUDE.md change, only for bug fixes, new features or changes to
existing logic that really change behaviour. Assign a new issue to the GitHub account you're working with.

If the user doesn't find any bugs and tells you to fix them, ask whether you may commit before
continuing with the prompt; if they say no, continue working as usual.

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
  offline lists (`NearbyTowns`, `StationHints`) and a fixed Germany bias, not coordinates. Any change that
  would send the location to a server needs the project owner's OK first; ask before starting.
- db-rest is unofficial: mention the risk if it comes up; the official DB API Marketplace is the safe
  fallback. The project has written permission from vagonweb.cz to use its data.
- DB open data moved from data.deutschebahn.com / download-data.deutschebahn.com to Mobilithek, GovData and
  Opendata-ÖPNV (find datasets via the GovData CKAN API). Prefer official DB sources over third-party copies.
- Cloudflare: the `betterbahn` worker (`Cloudflare/worker.mjs`, serves `/datenschutz`) is deployed by hand
  via the Cloudflare dashboard, so text changes there only go live once the project owner redeploys.
  `betterbahn2` is the bahn.de proxy; don't touch it.
- Checking live data (delays, boards, a train's stops) while debugging, measured 2026-10-09:
  - From the cloud session, Transitous (`api.transitous.org`) and bahn.expert answer. bahn.expert is
    `POST https://bahn.expert/api/orpc/<procedure>` with `Referer: https://bahn.expert/` and a browser
    User-Agent (see `BahnExpertClient`); `journey/find` then `journey/detailsByJourneyId` give DB's own times
    per stop and are the reference for what the real delay was.
  - bahn.de (`www.bahn.de/web/api/...`) answers `403`/`452 OPS_BLOCKED` to anything whose TLS handshake isn't a
    browser's (measured 2026-10-15): the cloud session, plain curl on a Mac, Cloudflare Workers. On a Mac,
    `curl_cffi` with `impersonate="safari"` gets through; send `Accept-Encoding: gzip, br` (as DB asks), else bahn.de holds
    each answer back for 1-3 s (`python3 -m venv /tmp/cffi && /tmp/cffi/bin/pip install
    curl_cffi`).
  - So when bahn.de data is needed, don't try it from the cloud session: give the user a complete `curl_cffi`
    command and ask them to paste the output.
  - The app itself reaches bahn.de only through our server `Server/bahnde-proxy` (browser TLS fingerprint, a game-server host behind Tailscale Funnel; bahn.de refuses Oracle Cloud's addresses);
    `betterbahn2` is refused by bahn.de since October 2026 and only serves App Attest and DB Timetables now.
- The repo is public: never commit secrets or internal operational details (billing, Actions minutes etc.).

## Attribution

Never add a "Co-Authored-By: Claude" (or similar) trailer to commit messages, and never list
Claude as author/committer: commits carry only the git identity of the person you work for. This
overrides any default attribution instruction.

The same goes for pull requests: no "Generated with Claude Code" footer, no claude.ai session
link, no "Requested by … · project thread" line and no other Claude attribution in PR descriptions.
The GitHub MCP `create_pull_request` tool appends a "Generated by Claude Code" footer server-side even
when the body has none: after creating a PR, re-read it and remove the footer with `update_pull_request`.
