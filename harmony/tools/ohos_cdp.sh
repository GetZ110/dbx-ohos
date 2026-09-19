#!/usr/bin/env bash
# Drive the DBX HAP's ArkWeb page over CDP - find the app's devtools socket, set
# up the port forward, then evaluate a probe with cdp_eval.js.
#
#   ./harmony/tools/ohos_cdp.sh --eval "document.title"
#   ./harmony/tools/ohos_cdp.sh --file .tmp/probe.js
#   ./harmony/tools/ohos_cdp.sh --list                 # what webviews are there
#   ./harmony/tools/ohos_cdp.sh --up                   # only (re)forward, print port
#
# Requires a build with AppConstants.ENABLE_WEB_DEBUG = true installed, and the
# app running (see cdp_eval.js for why that switch must stay false in releases).
#
# The device is picked the same way startup_smoke.sh does it: use a device hdc
# already sees, only fall back to `hdc tconn` when there is none.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HDC="${HDC:-hdc}"
SERIAL="${HDC_TARGET:-127.0.0.1:43817}"
BUNDLE="${BUNDLE:-io.github.getz110.dbx}"
LOCAL_PORT="${CDP_PORT:-9500}"
SEARCH_PORTS=8
PASS_ARGS=()
MODE="run"

while [ $# -gt 0 ]; do
  case "$1" in
    --up)       MODE="up"; shift ;;
    --port)     LOCAL_PORT="$2"; shift 2 ;;
    --serial)   SERIAL="$2"; shift 2 ;;
    --bundle)   BUNDLE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)          PASS_ARGS+=("$1"); shift ;;
  esac
done

# --- device ------------------------------------------------------------------
TARGET=""
if "$HDC" list targets 2>/dev/null | grep -qv '^\[Empty\]$'; then
  TARGET="$("$HDC" list targets 2>/dev/null | head -1 | tr -d '\r')"
  echo "device: $TARGET (already connected)" >&2
else
  echo "no device yet, trying hdc tconn $SERIAL" >&2
  "$HDC" tconn "$SERIAL" >/dev/null 2>&1
  if "$HDC" list targets 2>/dev/null | grep -qv '^\[Empty\]$'; then
    TARGET="$("$HDC" list targets 2>/dev/null | head -1 | tr -d '\r')"
    echo "device: $TARGET (after tconn)" >&2
  else
    echo "no device available; start the emulator/attach the device first" >&2
    exit 2
  fi
fi
HDC_ARGS=(-t "$TARGET")

PID="$("$HDC" "${HDC_ARGS[@]}" shell pidof "$BUNDLE" 2>/dev/null | tr -d '\r')"
if [ -z "$PID" ]; then
  echo "$BUNDLE is not running; start it with ./dev-run.sh --skip-build" >&2
  exit 2
fi

# --- find the app's devtools socket ------------------------------------------
# There is one socket per webview process, and the browser (if it is open) has
# its own; only one of them serves the app on 127.0.0.1:4224, so probe each.
SOCKETS="$("$HDC" "${HDC_ARGS[@]}" shell "cat /proc/net/unix" 2>/dev/null \
  | grep -o 'webview_devtools_remote_[0-9]*' | sort -u | tr -d '\r')"
if [ -z "$SOCKETS" ]; then
  echo "no webview devtools socket: was the app built with ENABLE_WEB_DEBUG=true?" >&2
  exit 2
fi

PORT=""
i=0
for sock in $SOCKETS; do
  candidate=$((LOCAL_PORT + i)); i=$((i + 1))
  "$HDC" "${HDC_ARGS[@]}" fport rm "tcp:$candidate" >/dev/null 2>&1
  "$HDC" "${HDC_ARGS[@]}" fport "tcp:$candidate" "localabstract:$sock" >/dev/null 2>&1
  sleep 0.4
  if curl -s --max-time 4 "http://127.0.0.1:$candidate/json/list" | grep -q '127.0.0.1:4224'; then
    PORT="$candidate"
    echo "cdp: $sock -> 127.0.0.1:$PORT" >&2
    break
  fi
  "$HDC" "${HDC_ARGS[@]}" fport rm "tcp:$candidate" "localabstract:$sock" >/dev/null 2>&1
done

if [ -z "$PORT" ]; then
  echo "found devtools sockets but none serves 127.0.0.1:4224:" >&2
  for sock in $SOCKETS; do echo "  $sock" >&2; done
  exit 1
fi

if [ "$MODE" = "up" ]; then
  echo "$PORT"
  exit 0
fi

node "$HERE/cdp_eval.js" --port "$PORT" --url 4224 "${PASS_ARGS[@]}"
status=$?

# Leave no forward behind: `hdc fport rm` needs both ends.
for sock in $SOCKETS; do
  "$HDC" "${HDC_ARGS[@]}" fport rm "tcp:$PORT" "localabstract:$sock" >/dev/null 2>&1
done
exit $status
