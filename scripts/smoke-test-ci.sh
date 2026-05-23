#!/usr/bin/env bash
# Smoke test for CI: launch the app, send a command, verify it stays alive for 15 seconds.
set -euo pipefail

SOCKET_PATH="/tmp/c11-debug.sock"
STABILITY_WAIT=15

echo "=== Smoke Test ==="

# --- Find the built app ---
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/c11 DEV.app" -print -quit 2>/dev/null || true)
if [ -z "$APP" ]; then
  echo "ERROR: Built app not found in DerivedData"
  exit 1
fi
echo "App: $APP"
BINARY="$APP/Contents/MacOS/c11"
if [ ! -x "$BINARY" ]; then
  echo "ERROR: App binary not found or not executable: $BINARY"
  exit 1
fi

# --- Clean up stale socket and any existing instances ---
rm -f "$SOCKET_PATH" /tmp/c11mux-debug.sock
pkill -x "c11" 2>/dev/null || true
pkill -x "cmux" 2>/dev/null || true
sleep 1

# --- Launch the app directly (not via `open`, which can silently fail on CI) ---
echo "Launching app..."
C11_SOCKET_MODE=allowAll \
CMUX_SOCKET_MODE=allowAll \
C11_UI_TEST_MODE=1 \
CMUX_UI_TEST_MODE=1 \
CODEX_THREAD_ID=ci-poison \
CODEX_SANDBOX=seatbelt \
CODEX_SANDBOX_NETWORK_DISABLED=1 \
CODEX_NETWORK_PROXY_ACTIVE=1 \
HTTPS_PROXY=http://127.0.0.1:9 \
http_proxy=http://127.0.0.1:9 \
"$BINARY" > /tmp/c11-smoke-stdout.log 2>&1 &
APP_PID=$!
echo "App PID: $APP_PID"

# --- Verify process is alive after 2s ---
sleep 2
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: App exited immediately after launch"
  echo "--- stdout/stderr ---"
  cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -50 || true
  echo "--- debug log ---"
  tail -50 /tmp/c11-debug.log 2>/dev/null || true
  echo "--- crash reports ---"
  ls -lt ~/Library/Logs/DiagnosticReports/*c11* ~/Library/Logs/DiagnosticReports/*cmux* 2>/dev/null | head -5 || echo "(none)"
  exit 1
fi

# --- Wait for socket (up to 30s) ---
echo "Waiting for socket at $SOCKET_PATH..."
SOCKET_READY=false
for i in $(seq 1 60); do
  if [ -S "$SOCKET_PATH" ]; then
    echo "Socket ready after $((i / 2))s"
    SOCKET_READY=true
    break
  fi
  # Check if process died while waiting
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "ERROR: App crashed while waiting for socket"
    echo "--- stdout/stderr ---"
    cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -50 || true
    echo "--- debug log ---"
    tail -50 /tmp/c11-debug.log 2>/dev/null || true
    exit 1
  fi
  sleep 0.5
done
if [ "$SOCKET_READY" != "true" ]; then
  echo "ERROR: Socket not ready after 30s"
  echo "--- stdout/stderr ---"
  cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -30 || true
  echo "--- debug log ---"
  tail -30 /tmp/c11-debug.log 2>/dev/null || true
  ls -la /tmp/c11-debug* 2>/dev/null || true
  pgrep -la "c11" || pgrep -la "cmux" || echo "No c11/cmux processes found"
  exit 1
fi

# --- Ping the socket ---
echo "Pinging socket..."
PING_RESPONSE=$(python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.settimeout(5.0)
s.sendall(b'ping\n')
data = s.recv(1024).decode().strip()
s.close()
print(data)
")
echo "Ping response: $PING_RESPONSE"
if [ "$PING_RESPONSE" != "PONG" ]; then
  echo "ERROR: Expected PONG, got: $PING_RESPONSE"
  exit 1
fi

# --- Verify poisoned parent Codex env does not reach the terminal child ---
echo "Checking terminal launch environment sanitizer..."
python3 - "$SOCKET_PATH" <<'PY'
import json
import socket
import sys
import time

socket_path = sys.argv[1]
marker = "C11_ENV_PROBE_DONE"
next_request_id = 1

def request(command: str, timeout: float = 5.0) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(socket_path)
        s.settimeout(timeout)
        s.sendall((command + "\n").encode())
        return s.recv(65536).decode(errors="replace")

def request_v2(method: str, params: dict, timeout: float = 5.0) -> dict:
    global next_request_id
    request_id = next_request_id
    next_request_id += 1
    payload = {
        "id": request_id,
        "method": method,
        "params": params,
    }
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(socket_path)
        s.settimeout(timeout)
        s.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode())
        response = s.recv(65536).decode(errors="replace").strip()
    try:
        decoded = json.loads(response)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid v2 response for {method}: {response!r}") from exc
    if decoded.get("id") != request_id or "error" in decoded:
        raise RuntimeError(f"v2 {method} failed: {decoded!r}")
    return decoded

request_v2("surface.send_text", {"text": "stty -echo"})
time.sleep(0.5)
probe = (
    "env | awk -F= '/^(CODEX_|HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|"
    "ALL_PROXY|NO_PROXY|all_proxy|no_proxy)=/ { print \"C11_ENV_LEAK:\" $1 }'; "
    f"echo {marker}; stty echo"
)
request_v2("surface.send_text", {"text": probe})

deadline = time.time() + 10
last_screen = ""
while time.time() < deadline:
    time.sleep(0.5)
    last_screen = request("read_screen --scrollback --lines 200")
    if "C11_ENV_LEAK:" in last_screen:
        print("ERROR: terminal inherited poisoned Codex/proxy environment", file=sys.stderr)
        print(last_screen, file=sys.stderr)
        sys.exit(1)
    if marker in last_screen:
        print("Environment probe passed")
        sys.exit(0)

print("ERROR: environment probe marker did not appear", file=sys.stderr)
print(last_screen, file=sys.stderr)
sys.exit(1)
PY

# --- Send a command to the terminal ---
echo "Sending 'time' command to terminal..."
SEND_RESPONSE=$(python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.settimeout(5.0)
s.sendall(b'send time\\\n\n')
data = s.recv(1024).decode().strip()
s.close()
print(data)
")
echo "Send response: $SEND_RESPONSE"

# --- Wait and verify stability ---
echo "Waiting ${STABILITY_WAIT}s to verify stability..."
sleep "$STABILITY_WAIT"

if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: App crashed during ${STABILITY_WAIT}s stability check"
  echo "--- stdout/stderr ---"
  cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -30 || true
  echo "--- debug log ---"
  tail -30 /tmp/c11-debug.log 2>/dev/null || true
  exit 1
fi

# --- Final ping ---
FINAL_PING=$(python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.settimeout(5.0)
s.sendall(b'ping\n')
data = s.recv(1024).decode().strip()
s.close()
print(data)
")
echo "Final ping: $FINAL_PING"
if [ "$FINAL_PING" != "PONG" ]; then
  echo "ERROR: App not responsive after ${STABILITY_WAIT}s"
  exit 1
fi

echo "=== Smoke test passed ==="

# --- Cleanup ---
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
