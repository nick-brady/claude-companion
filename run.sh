#!/bin/zsh
# Build Claude Companion into build/Claude Companion.app and launch it.
#   ./run.sh            build (release) + launch
#   ./run.sh selftest   run checks that need no mic/permissions
#   ./run.sh selftest --claude   also do one real round trip through `claude -p` (uses a little quota)
#   ./run.sh demo       launch and cycle the pill through its states (no mic, no Claude)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true
BIN=.build/release/ClaudeCompanion
[[ -x $BIN ]] || { echo "build failed"; exit 1; }

if [[ "${1:-}" == "selftest" ]]; then
  shift; exec $BIN --selftest "$@"
fi

APP="build/Claude Companion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp $BIN "$APP/Contents/MacOS/ClaudeCompanion"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign with a stable local identity so macOS privacy permissions (Microphone, Screen
# Recording, Automation) survive rebuilds. One-time setup: see README → "Stable signing".
# Falls back to ad-hoc signing (permissions may need re-granting after each rebuild).
SIGN_ID="${COMPANION_SIGN_ID:-Claude Companion Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --sign "$SIGN_ID" --identifier com.nickbrady.claudecompanion "$APP" >/dev/null
  echo "Signed with '$SIGN_ID' (permissions persist across rebuilds)."
else
  codesign --force --sign - --identifier com.nickbrady.claudecompanion "$APP" >/dev/null
  echo "Ad-hoc signed: no '$SIGN_ID' certificate found. macOS may re-ask for permissions after rebuilds (README → Stable signing)."
fi

pkill -x ClaudeCompanion 2>/dev/null || true
sleep 0.3
if [[ "${1:-}" == "demo" ]]; then
  open "$APP" --args --demo
else
  open "$APP"
fi
echo "Launched. The pill sits at its home position (top-left by default); the waveform icon is in the menu bar."
echo "Hold ⌥Space to talk."
