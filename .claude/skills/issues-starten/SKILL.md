---
name: issues-starten
description: Start a cloud session for each GitHub issue (issues that change the same screen share one), so a batch of new issues gets worked on without opening a chat per issue. Use when the user lists issues to start ("/issues-starten 420 421", "starte #420-#425") or asks to start all new issues.
argument-hint: "[issue numbers or ranges] - empty: all open issues nobody works on yet"
---

# Start issues in their own sessions

This session only plans and starts; the started sessions do the work. Don't create a branch, change files or
open a PR here. It needs a cloud session: load `mcp__claude-code-remote__create_session` and the GitHub MCP
tools with ToolSearch. Don't call `list_sessions`: it is expensive and the label below answers the same question.

## 1. Pick the issues

- `git fetch origin`, then read the issues in `AppleGoldKunibert/betterbahnapp`.
- With arguments: those issues (`420-425` is a range). Without: all open issues without the labels `ready`
  and `in progress`.
- Leave out, and name in the report with the reason:
  - closed issues and issues labelled `ready` (already merged into `indevelopment`) or `in progress`
    (a session already works on it), unless the user named them and still wants a new session;
  - issues an open PR already fixes ("fixes #N" in its title or body);
  - unclear issues (empty or vague text, see "Unklares Issue" in CLAUDE.md). Ask about them with
    AskUserQuestion when a short answer makes them clear, and pass the answer on in the session's prompt;
    otherwise say what is missing.

## 2. Bundle what overlaps

Read each issue with its comments and find what it will change: grep `docs/CODEBASE.md` for the screen or
feature it names and note the main views and Kit types.

- One session for issues that change the same screen or the same Kit type, or where one builds on the other.
  At most 3 issues per session.
- Files almost every change touches (`AppModel.swift`, `DesignSystem.swift`, `docs/CODEBASE.md`,
  `BetterBahnKitTests.swift`) don't count as overlap: conflicts there are small and merging `indevelopment`
  fixes them.
- Every other issue gets its own session.

## 3. Start the sessions

Label every issue you start `in progress` (it shows on GitHub that a session works on it; the "Label done
issues" workflow removes it when the PR is merged). Then one `create_session` per issue or bundle:

- `source_url`: `https://github.com/AppleGoldKunibert/betterbahnapp`, `source_revision`: `indevelopment`.
- `title`: `#420 <short title>`; a bundle: `#420 + #423 <shared screen>`.
- `tags`: `["issues-starten"]`. Leave out `environment_id`, `model` and `permission_mode`: the session takes
  them from this one.
- `prompt`, in German (the user sees it as the session's first message):

  One issue:

  ```
  Bearbeite Issue #420 „<Titel>“: https://github.com/AppleGoldKunibert/betterbahnapp/issues/420
  Lies zuerst das Issue mit allen Kommentaren und halte dich an .claude/CLAUDE.md.
  <the user's answer from step 1, if any>
  ```

  A bundle:

  ```
  Bearbeite nacheinander diese Issues, sie betreffen beide <Bildschirm>:
  - #420 „<Titel>“: https://github.com/AppleGoldKunibert/betterbahnapp/issues/420
  - #423 „<Titel>“: https://github.com/AppleGoldKunibert/betterbahnapp/issues/423
  Jedes Issue bekommt ohne Nachfrage einen eigenen Branch von origin/indevelopment und einen eigenen PR. Fang
  das nächste an, sobald der PR des vorigen offen ist. Baut eins auf dem anderen auf, frag nach, wie es
  .claude/CLAUDE.md beschreibt. Halte dich an .claude/CLAUDE.md.
  ```

Start them one after another. If a call fails (for example a usage limit), stop, remove `in progress` from
the issues that didn't get a session, and say which ones still need starting.

## 4. Report

A short table, one row per session: issues, what they change, and the session link
(`https://claude.ai/code/<session id>`). Below it the issues you left out and why. Nothing more: each session
reports in its own chat.
