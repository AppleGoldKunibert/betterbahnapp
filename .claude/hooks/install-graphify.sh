#!/bin/bash
# Cloud sessions: install graphify (Python package `graphifyy`) so the /graphify skill in
# .claude/skills/graphify works, then build the code graph in the background (no LLM, a few
# seconds; doc results come from the committed graphify-out/cache/semantic). Local sessions
# are left alone.
[ "$CLAUDE_CODE_REMOTE" = "true" ] || exit 0

find_graphify() {
  if command -v graphify >/dev/null; then echo graphify
  elif [ -x "$HOME/.local/bin/graphify" ]; then echo "$HOME/.local/bin/graphify"
  elif python3 -c "import graphify" 2>/dev/null; then echo "python3 -m graphify"
  fi
}

GRAPHIFY=$(find_graphify)
if [ -z "$GRAPHIFY" ]; then
  if command -v uv >/dev/null; then
    uv tool install -q graphifyy >/dev/null 2>&1
  else
    python3 -m pip install -q graphifyy >/dev/null 2>&1 \
      || python3 -m pip install -q --break-system-packages graphifyy >/dev/null 2>&1
  fi
  GRAPHIFY=$(find_graphify)
fi
[ -n "$GRAPHIFY" ] || exit 0

cd "$CLAUDE_PROJECT_DIR" || exit 0
mkdir -p graphify-out
nohup $GRAPHIFY update . >graphify-out/build.log 2>&1 &
exit 0
