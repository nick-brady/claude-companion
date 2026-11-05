#!/bin/bash
# Claude Code hook -> Claude Companion app. Usage: notify-app.sh stop|activity
# Forwards the hook's JSON (stdin) to the app on 127.0.0.1. Never blocks Claude:
# 2-second timeout, always exits 0, prints nothing.
kind="${1:-stop}"
token_file="$HOME/Library/Application Support/ClaudeCompanion/token"
[ -r "$token_file" ] || exit 0
tty=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
curl -s -m 2 -o /dev/null -X POST "http://127.0.0.1:47823/hook/$kind" \
  -H "x-companion-token: $(cat "$token_file")" \
  -H "x-claude-tty: $tty" \
  -H "content-type: application/json" \
  --data-binary @- 2>/dev/null
exit 0
