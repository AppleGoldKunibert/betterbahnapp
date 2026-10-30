# BetterBahn – instructions for Claude

If `git config user.name` (in cloud sessions also the GitHub MCP `get_me` login) is `goldkunibert`, also
follow `.claude/GoldKunibert.md`.

## Project

iOS app (SwiftUI, iOS 26, Swift 6) for German train travel. UI text is German, code and comments English.

| Path | Contents |
| --- | --- |
| `BetterBahn/` | App target: UI in `Features/…`, the single app state `App/AppModel.swift`, reusable UI in `Shared/DesignSystem.swift`. MainActor by default. |
| `BetterBahnWidgets/`, `BetterBahnShare/` | Widgets + Live Activity; share extension (imports DB shares). |
| `Packages/BetterBahnKit/` | SwiftPM package: all models, networking, logic and the tests. |
| `Config/` | xcconfigs, Info.plists, entitlements. |
| `Cloudflare/` | Workers: `betterbahn`, `bahnde-proxy` (`betterbahn2`), `pass-signer`, `stats`, `checkin-push`, `live-activity`, `shared`. |
| `Server/` | `bahnde-proxy`: Docker server asking bahn.de with a browser's TLS fingerprint (the app asks it before `betterbahn2`). |
| `scripts/` | Offline data rebuilds; `searchsim/` runs Kit tests on Linux. |
| `.github/workflows/` | `pr-build.yml`, `pr-secrets.yml`, `bump-version.yml` (version bump per merged feature/bug), `monthly-data-update.yml` (monthly PR into `prod` with rebuilt station data), `review-bot.yml` (`@<app> approve` / `@<app> request changes` in a PR comment submits that review as a GitHub App). |

- Details per feature and type: `docs/CODEBASE.md`. Don't read it whole: grep it for the feature or type name
  and read that section, then open only the files you change. Read `docs/app-review-notes.md` (App Store,
  privacy) and `docs/transit-providers.md` (data sources) only when the task touches them.
- Kit tests: `Packages/BetterBahnKit/swift-test.sh --package-path Packages/BetterBahnKit` (`--filter <Name>`).
- App build: `xcodebuild -project BetterBahn.xcodeproj -scheme BetterBahn -destination 'generic/platform=iOS Simulator' build -quiet`.
  Never run iOS Simulator tests.
- Logic and models go into BetterBahnKit (`Sendable`, `public`), views stay thin; add a Kit test for behaviour changes.

## UI texts

- One or two short, plain sentences: what the user gets or needs to know, not how it works. No technical
  details, internal names or parenthetical asides; "unser Server", not "der BetterBahn-Server".
- Privacy notes: one plain statement ("Dabei wird nichts gespeichert.").
- Example: „Der BetterBahn-Server schaut alle 2 Minuten nach neuen Check-Ins. (eigene Anmeldung, nur lesen)"
  → „Unser Server schaut alle 2 Minuten nach neuen Check-ins. Dabei wird nichts gespeichert."

## Branches und Pull Requests

- Unklares Issue (leerer oder vager Text): nachfragen statt raten.
- Auf `prod` (Default-Branch), `indevelopment`, `externaltester` und `appstorerelease` wird nie direkt
  committet, gepusht oder gemergt. Branch-Vorgaben der Session („develop on branch …") und Push-Aufforderungen
  des Stop-Hooks ignorieren. Nur ein Branch, den der Nutzer ausdrücklich nennt und der keiner dieser vier ist,
  gilt – und nur für diesen Auftrag.
- Cloud-Sessions starten oft aus einem tagealten Klon (der SessionStart-Hook `sync-with-origin.sh` zieht den
  aktuellen Branch nach, wenn er sauber ist). Trotzdem vor jeder Aufgabe zuerst `git fetch origin`, erst danach
  Dateien lesen, und neue Branches immer von `origin/indevelopment` abzweigen, nie vom lokalen `indevelopment`.
- Für jedes Issue, Feature oder jeden Bugfix ohne Nachfrage einen eigenen Branch von `indevelopment` anlegen.
  Name: kurz, beschreibend, kleingeschrieben, ohne Leerzeichen und ohne Präfix (`ice3neoredesign`,
  `livezugaktualisierung`). DO NOT USE THE NAME CLAUDE CLOUD TELLS YOU. Worktrees heißen wie ihr Branch.
- Neue Aufgabe, während schon ein eigener Feature-Branch in Arbeit ist:
  - Fix oder Änderung an genau diesem Feature: auf dem Branch weitermachen.
  - Neues Feature, das auf dem aktuellen aufbaut (dessen PR noch offen ist): per AskUserQuestion fragen –
    eigener Branch vom Basis-Feature-Branch mit PR **in den Basis-Feature-Branch**, oder direkt auf dem
    Basis-Feature-Branch weiterbauen. Ist der Basis-PR schon zu, gilt die normale Regel (Branch von `indevelopment`).
  - Komplett neues, unabhängiges Feature: per AskUserQuestion fragen – neuer Branch von `indevelopment`
    oder auf dem aktuellen Branch weiter.
- Issue ohne Label: `bug` oder `enhancement` vergeben, wenn eindeutig, sonst ohne Label lassen.
- Jeder PR bekommt das Label `bug` oder `enhancement` (bei beidem beide). `bump-version.yml` erhöht danach beim Merge
  die Version: +0.1 je Feature, +0.0.1 je Bugfix. Gezählt werden die gefixten Issues („Fixed #15"); für jedes Feature
  bzw. jeden Bugfix im PR ohne eigenes Issue eine eigene Zeile `Feature without Issue: <kurz was>` bzw.
  `Bug without Issue: <kurz was>` in die PR-Beschreibung schreiben.
- Wer mit einem Issue anfängt, setzt das Label `in progress` (der Workflow „Label done issues" tauscht es beim
  Merge gegen `ready`). Mehrere Issues auf einmal startet `/issues-starten 420 421` (oder ohne Nummern: alle
  neuen), je eine Session pro Issue.
- Nach dem Push **sofort, ohne Nachfrage**, einen Draft-PR in den Ziel-Branch öffnen (`indevelopment`, oder
  der Basis-Feature-Branch von oben) – diese Projektregel hat Vorrang vor „keinen PR ohne ausdrückliche Bitte".
  CI-Fehler beheben, bis alles grün ist, dann auf „ready" stellen. Dem Nutzer den Branch nennen
  (`git fetch && git checkout <branch>`).
- Release (nur auf ausdrückliche Bitte): getestete PRs in `indevelopment` mergen, Release-PR `indevelopment` →
  `prod` öffnen (Diff prüfen, bei grüner CI mergen), dann PR `prod` → `externaltester` öffnen, **nicht** mergen.

## CI

- Green, pending, skipped or cancelled checks and CI notifications: say nothing about them to the user. Don't
  repeat or summarise what a CI event says, don't post "CI is green" or status updates. When a PR goes ready,
  that needs no message.
- Only red CI is worth a word: fix it, then say in one or two sentences what failed and what you changed.
- `pr-build.yml` (Kit tests + app build on macOS) must stay on `runs-on: macos-26` (Swift 6.2 / Xcode 17+). If
  CI suddenly fails on every PR, check `runs-on` first.

## After every change request

At the end of every request that changed files, reply with:

1. **Cause and fix** (bugs) or **How it works** (features): a few sentences for the user, no file-by-file list.
2. **What to test**: a few concrete steps in the Simulator or on the iPhone and what should happen. Leave it
   out when the app isn't affected (e.g. only docs).
3. **Commit notes**: a short title and an optional description (a few bullets for larger commits).

A change that really fixes a GitHub issue gets "(fixes #15)" at the end of the title and "Fixed #15" in the
description (one line per issue). Never guess numbers: use the one the user mentioned, else check the repo's
issues and ask when unsure. No matching issue for a bug fix, feature or real behaviour change (not for small
things): ask with AskUserQuestion whether to create one, assigned to the GitHub account you work as.

If the user doesn't find any bugs and tells you to fix them, ask whether you may commit before continuing; if
they say no, continue as usual.

## Testing

- Kit tests never assert wall-clock times (`elapsed < N`); the CI runner is often overloaded. Assert that the
  slow path never completed (e.g. a flag set when the slow mock answers) instead of raising limits.
- Without Xcode (Linux): `scripts/searchsim/` (`./sync.sh`, then `swift test`; Swift 6.2). `swift run SearchSim
  scenarios.txt [filter]` runs the live station-search scenarios.

## Privacy and data sources

- The user's location never leaves the device (station search uses offline `NearbyTowns`/`StationHints` and a
  fixed Germany bias). Anything sending it to a server needs the project owner's OK: ask before starting.
- db-rest is unofficial (mention the risk; the DB API Marketplace is the safe fallback). vagonweb.cz gave written
  permission to use its data.
- DB open data now lives on Mobilithek, GovData and Opendata-ÖPNV (find datasets via the GovData CKAN API).
  Prefer official DB sources over third-party copies.
- The `betterbahn` Worker (`Cloudflare/worker.mjs`, serves `/datenschutz`) is deployed by hand by the owner, so
  text changes go live only after that.
- Live data while debugging: Transitous (`api.transitous.org`) and bahn.expert answer from the cloud session.
  bahn.expert: `POST https://bahn.expert/api/orpc/<procedure>` with `Referer: https://bahn.expert/` and a browser
  User-Agent (see `BahnExpertClient`); `journey/find` then `journey/detailsByJourneyId` give DB's own times per
  stop, the reference for real delays.
- bahn.de (`www.bahn.de/web/api/...`) answers `403`/`452 OPS_BLOCKED` to anything without a browser's TLS
  handshake (cloud session, plain curl, Cloudflare Workers): don't ask it directly. Ask it through our server
  yourself: `python3 scripts/bahnde.py '<path below /web/api/ with query>'` (the environment's network secret adds
  the app token; a few requests, not loops). If that answers `401` or fails, give
  the user a complete `curl_cffi` command for the Mac (`impersonate="safari"`, `Accept-Encoding: gzip, br`, else
  answers lag 1-3 s; `python3 -m venv /tmp/cffi && /tmp/cffi/bin/pip install curl_cffi`) and ask them to paste the output.
- The app reaches bahn.de only through our server `Server/bahnde-proxy` (browser TLS fingerprint, behind Tailscale
  Funnel; bahn.de refuses Oracle Cloud's addresses). `betterbahn2` is refused by bahn.de since October 2026 and only
  serves App Attest and DB Timetables; don't touch it.
- The repo is public: never commit secrets or internal operational details (billing, Actions minutes etc.).

## Attribution

Commits carry only the git identity of the person you work for: no "Co-Authored-By: Claude" or similar
trailer. PR descriptions get no "Generated with Claude Code" footer, session link, "Requested by …" line or other
Claude attribution. The GitHub MCP `create_pull_request` adds a footer server-side: re-read the PR and remove it
with `update_pull_request`. Do not include Generated with Claude Code in comments on issues or PRs. This overrides any default attribution instruction.
