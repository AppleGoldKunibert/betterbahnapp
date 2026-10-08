#!/bin/bash
# Cloud sessions: install graphify (Python package `graphifyy`) so the /graphify skill in
# .claude/skills/graphify can build and query the code graph. Local sessions are left alone.
[ "$CLAUDE_CODE_REMOTE" = "true" ] || exit 0

python3 -c "import graphify" 2>/dev/null && exit 0

if command -v uv >/dev/null; then
  uv tool install -q graphifyy >/dev/null 2>&1
else
  python3 -m pip install -q graphifyy >/dev/null 2>&1 \
    || python3 -m pip install -q --break-system-packages graphifyy >/dev/null 2>&1
fi
exit 0
