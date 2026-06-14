#!/usr/bin/env bash
# C11-132 validation: WebContent-kill remount-storm experiment.
#
# Drives a tagged c11 build (launched with C11_PORTAL_DEBUG=1) over its debug
# socket: opens 4 browser panes in a fresh workspace, lets them settle, kills
# one pane's WebContent process, and captures the portal log window covering
# the remount storm.
#
# Usage: webcontent-kill-experiment.sh <tag> <output-log-path>
#   e.g. webcontent-kill-experiment.sh c11-132 /tmp/c11-132-after.log
#
# Pre-req: ./scripts/reload.sh --tag <tag> already run with C11_PORTAL_DEBUG=1
# in the app's environment, and the tagged app is frontmost-running.
set -euo pipefail

TAG="${1:?usage: webcontent-kill-experiment.sh <tag> <output-log-path>}"
OUT="${2:?usage: webcontent-kill-experiment.sh <tag> <output-log-path>}"
SOCK="/tmp/c11-debug-${TAG}.sock"
PORTAL_LOG="${C11_PORTAL_LOG:-/tmp/c11-portal.log}"

c11t() { C11_SOCKET="$SOCK" CMUX_SOCKET="$SOCK" c11 "$@"; }

echo "== socket: $SOCK"
c11t identify --json >/dev/null || { echo "tagged socket unreachable"; exit 1; }

echo "== creating workspace with 4 browser panes"
c11t new-workspace --title "C11-132 repro"
c11t new-pane --type browser --url "https://example.com"
c11t new-pane --type browser --url "https://example.com" --direction right
c11t new-pane --type browser --url "https://example.com" --direction down
c11t new-pane --type browser --url "https://example.com" --direction down

echo "== settling 15s"
sleep 15

LOG_LINES_BEFORE=$(wc -l < "$PORTAL_LOG" 2>/dev/null || echo 0)
echo "== portal log lines at settle: $LOG_LINES_BEFORE"

# Find WebContent processes whose responsible app is the tagged c11 build.
APP_PID=$(pgrep -f "/tmp/c11-${TAG}/.*c11 DEV.app/Contents/MacOS/" | head -1 || true)
echo "== tagged app pid: ${APP_PID:-unknown}"
WC_PIDS=$(pgrep -f "com.apple.WebKit.WebContent" || true)
echo "== WebContent pids visible: $(echo "$WC_PIDS" | tr '\n' ' ')"

# Kill the newest WebContent (heuristic: highest pid spawned by our 4 panes).
TARGET=$(echo "$WC_PIDS" | sort -n | tail -1)
echo "== killing WebContent pid $TARGET"
kill -KILL "$TARGET"

echo "== watching 30s for remount storm + settle"
sleep 30

LOG_LINES_AFTER=$(wc -l < "$PORTAL_LOG" 2>/dev/null || echo 0)
echo "== portal log lines after kill+settle: $LOG_LINES_AFTER (delta $((LOG_LINES_AFTER - LOG_LINES_BEFORE)))"

# Confirm quiescence: no new lines over a further 15s.
sleep 15
LOG_LINES_QUIET=$(wc -l < "$PORTAL_LOG" 2>/dev/null || echo 0)
echo "== portal log lines after quiet window: $LOG_LINES_QUIET (delta $((LOG_LINES_QUIET - LOG_LINES_AFTER)))"

cp "$PORTAL_LOG" "$OUT"
echo "== captured portal log -> $OUT"
