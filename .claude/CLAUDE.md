# CLAUDE.md

## Branching und Pull Requests

- Arbeite für jedes Issue bzw. jedes Feature/jeden Bugfix in einem eigenen Branch.
- Der Branch-Name beschreibt, was gebaut oder gefixt wird: kurz, aber verständlich, kleingeschrieben, ohne Leerzeichen.
  Beispiele: `ice3neoredesign`, `livezugaktualisierung`.
- Erstelle den Branch vom passenden Ziel-Branch (siehe unten), damit der PR nur die eigenen Änderungen enthält.
- Wenn die Arbeit fertig ist, öffne einen Pull Request in den passenden Ziel-Branch:
  - `prod-features` für Features (Issue-Label für Features/Enhancements)
  - `prod-bugs` für Bugfixes (Issue-Label `bug`)
  - `prod-other` für alles andere, auch für Issues ohne Label
- Nicht direkt nach `prod` pushen oder mergen.
