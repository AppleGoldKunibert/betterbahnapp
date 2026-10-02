# CLAUDE.md

## Branching und Pull Requests

- Arbeite für jedes Issue bzw. jedes Feature/jeden Bugfix in einem eigenen Branch.
- Der Branch-Name beschreibt, was gebaut oder gefixt wird: kurz, aber verständlich, kleingeschrieben, ohne Leerzeichen.
  Beispiele: `ice3neoredesign`, `livezugaktualisierung`.
- Hat das Issue kein Label, vergib selbst ein passendes, wenn es eindeutig ist:
  `bug` für Fehler, `enhancement` für neue Features oder Verbesserungen.
  Passt keins davon, lass das Issue ohne Label.
- Erstelle den Branch vom passenden Ziel-Branch (siehe unten), damit der PR nur die eigenen Änderungen enthält.
- Wenn die Arbeit fertig ist, öffne einen Pull Request in den passenden Ziel-Branch:
  - `prod-features` für Features (Label `enhancement`)
  - `prod-bugs` für Bugfixes (Label `bug`)
  - `prod-other` für alles andere, auch für Issues ohne Label
- Nicht direkt nach `prod` pushen oder mergen.
