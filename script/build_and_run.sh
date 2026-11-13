#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in
    run|--debug|--logs|--telemetry|--verify) ;;
    *) echo "Usage: $0 [--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
APP_BUNDLE="$ROOT_DIR/build/MacSweep.app"
pkill -x MacSweep >/dev/null 2>&1 || true
cd "$ROOT_DIR"
"$ROOT_DIR/scripts/build-app.sh"
case "$MODE" in
    --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/MacSweep" ;;
    --logs)
        /usr/bin/open -n "$APP_BUNDLE"
        /usr/bin/log stream --info --style compact --predicate 'process == "MacSweep"' ;;
    --telemetry)
        /usr/bin/open -n "$APP_BUNDLE"
        /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.local.MacSweep"' ;;
    --verify)
        /usr/bin/open -n "$APP_BUNDLE"
        sleep 2
        pgrep -x MacSweep >/dev/null
        echo "MacSweep launched successfully." ;;
    run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
