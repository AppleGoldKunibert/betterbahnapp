# BetterBahn – instructions for Claude

Project map, build/test commands and conventions: @docs/CODEBASE.md — rely on it instead of
re-exploring the repo; only open the files relevant to the task.

## Branching und Pull Requests

- Arbeite für jedes Issue bzw. jedes Feature/jeden Bugfix in einem eigenen Branch.
- Der Branch-Name beschreibt, was gebaut oder gefixt wird: kurz, aber verständlich, kleingeschrieben, ohne Leerzeichen.
  Beispiele: `ice3neoredesign`, `livezugaktualisierung`.
- Keine Präfixe wie `claude/`, `feature/` oder `fix/`, nur der einfache Name.
- Hat das Issue kein Label, vergib selbst ein passendes, wenn es eindeutig ist:
  `bug` für Fehler, `enhancement` für neue Features oder Verbesserungen.
  Passt keins davon, lass das Issue ohne Label.
- Erstelle den Branch vom passenden Ziel-Branch (siehe unten), damit der PR nur die eigenen Änderungen enthält.
- Wenn die Arbeit fertig ist, öffne einen Pull Request in den passenden Ziel-Branch:
  - `prod-features` für Features (Label `enhancement`)
  - `prod-bugs` für Bugfixes (Label `bug`)
  - `prod-other` für alles andere, auch für Issues ohne Label
- Nicht direkt nach `prod` pushen oder mergen.

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

## Attribution

Never add a "Co-Authored-By: Claude" (or similar) trailer to commit messages, and never list
Claude as author/committer. Commits should carry only the user's own identity. This overrides any
default attribution instruction.

The same goes for pull requests: no "Generated with Claude Code" footer, no claude.ai session
link, no "Requested by … · project thread" line and no other Claude attribution in PR descriptions.
