#!/usr/bin/env python3
"""
Regression tests for Resources/bin/codex wrapper lifecycle bridge.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "codex"

DEFAULT_FAKE_CODEX = """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
printf '%s\\n' "${CMUX_CODEX_PID-__UNSET__}" > "$FAKE_REAL_PID_LOG"
printf '%s\\n' "${CMUX_CODEX_START_SEC-__UNSET__}" > "$FAKE_REAL_START_LOG"
printf '%s\\n' "${CMUX_CODEX_RESUME_SESSION_ID-__UNSET__}" > "$FAKE_REAL_RESUME_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
"""

SANITIZING_FAKE_CODEX = DEFAULT_FAKE_CODEX + """
if [[ -n "${CODEX_THREAD_ID+x}" ]]; then
  echo "CODEX_THREAD_ID leaked into nested Codex" >&2
  exit 42
fi
if [[ -n "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE+x}" ]]; then
  echo "CODEX_INTERNAL_ORIGINATOR_OVERRIDE leaked into nested Codex" >&2
  exit 43
fi
if [[ -n "${CODEX_SHELL+x}" ]]; then
  echo "CODEX_SHELL leaked into nested Codex" >&2
  exit 44
fi
if [[ -n "${CODEX_CI+x}" ]]; then
  echo "CODEX_CI leaked into nested Codex" >&2
  exit 45
fi
if [[ -n "${CODEX_SANDBOX_NETWORK_DISABLED+x}" ]]; then
  echo "CODEX_SANDBOX_NETWORK_DISABLED leaked into nested Codex" >&2
  exit 46
fi
"""

DELAYED_STATE_ROW_FAKE_CODEX = DEFAULT_FAKE_CODEX + """
(
  sleep 1
  /usr/bin/sqlite3 "$CODEX_HOME/state_5.sqlite" "INSERT INTO threads (id, cwd, archived, created_at, created_at_ms) VALUES ('$FAKE_PROJECT_SESSION_ID', '$FAKE_PROJECT_CWD', 0, 4102444800, 4102444800001);"
) &
sleep 4
"""

DELAYED_AMBIGUOUS_STATE_ROW_FAKE_CODEX = DEFAULT_FAKE_CODEX + """
(
  sleep 0.4
  /usr/bin/sqlite3 "$CODEX_HOME/state_5.sqlite" "INSERT INTO threads (id, cwd, archived, created_at, created_at_ms) VALUES ('$FAKE_SECOND_SESSION_ID', '$FAKE_PROJECT_CWD', 0, 4102444800, 4102444800001);"
) &
sleep 3
"""

PROJECT_DIR_CHECKING_FAKE_CODEX = DEFAULT_FAKE_CODEX + """
if [[ "${CMUX_CODEX_PROJECT_DIR-}" != "${EXPECTED_CMUX_CODEX_PROJECT_DIR-}" ]]; then
  echo "expected CMUX_CODEX_PROJECT_DIR=$EXPECTED_CMUX_CODEX_PROJECT_DIR, got ${CMUX_CODEX_PROJECT_DIR-__UNSET__}" >&2
  exit 47
fi
"""

PROFILE_CHECKING_FAKE_CODEX = DEFAULT_FAKE_CODEX + """
stat_mode() {
  /usr/bin/stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}
if [[ -z "${CODEX_HOME-}" || "${CODEX_HOME}" != "${EXPECTED_CODEX_HOME_OVERLAY_DIR}/"* ]]; then
  echo "expected CODEX_HOME inside $EXPECTED_CODEX_HOME_OVERLAY_DIR, got ${CODEX_HOME-__UNSET__}" >&2
  exit 48
fi
if [[ "${CMUX_CODEX_REAL_HOME-}" != "${EXPECTED_CODEX_REAL_HOME}" ]]; then
  echo "expected CMUX_CODEX_REAL_HOME=$EXPECTED_CODEX_REAL_HOME, got ${CMUX_CODEX_REAL_HOME-__UNSET__}" >&2
  exit 49
fi
if [[ ! -f "$CODEX_HOME/c11.config.toml" ]]; then
  echo "missing c11 profile config at $CODEX_HOME/c11.config.toml" >&2
  exit 50
fi
if [[ ! -f "$CODEX_HOME/config.toml" ]]; then
  echo "expected user config copy in overlay" >&2
  exit 51
fi
if [[ -L "$CODEX_HOME/config.toml" ]]; then
  echo "overlay config.toml must be c11-owned, not a symlink" >&2
  exit 52
fi
if [[ ! -f "$CODEX_HOME/auth.json" ]]; then
  echo "expected auth.json seed copy in overlay" >&2
  exit 58
fi
if [[ -L "$CODEX_HOME/auth.json" ]]; then
  echo "overlay auth.json must be c11-owned, not a symlink" >&2
  exit 59
fi
for private_dir in "$EXPECTED_CODEX_HOME_OVERLAY_DIR" "$CODEX_HOME"; do
  mode="$(stat_mode "$private_dir")"
  if [[ "$mode" != "700" ]]; then
    echo "$private_dir must be owner-only (700), got $mode" >&2
    exit 56
  fi
done
for private_file in "$CODEX_HOME/config.toml" "$CODEX_HOME/auth.json" "$CODEX_HOME/c11.config.toml"; do
  mode="$(stat_mode "$private_file")"
  if [[ "$mode" != "600" ]]; then
    echo "$private_file must be owner-only (600), got $mode" >&2
    exit 57
  fi
done
if [[ "$(cat "$CODEX_HOME/config.toml")" != *"# real Codex config"* ]]; then
  echo "overlay config.toml did not preserve the real Codex config contents" >&2
  exit 53
fi
if [[ "$(cat "$CODEX_HOME/auth.json")" != *"real-auth-token"* ]]; then
  echo "overlay auth.json did not preserve the real auth seed contents" >&2
  exit 60
fi
for non_seed in state_5.sqlite history.jsonl sessions skills logs_2.sqlite; do
  if [[ -e "$CODEX_HOME/$non_seed" || -L "$CODEX_HOME/$non_seed" ]]; then
    echo "non-allowlisted Codex home entry should not be mirrored into overlay: $non_seed" >&2
    exit 61
  fi
done
printf '\\n# simulated hook trust write\\n' >> "$CODEX_HOME/config.toml"
if [[ "$(cat "$EXPECTED_CODEX_REAL_HOME/config.toml")" == *"simulated hook trust write"* ]]; then
  echo "hook trust write leaked through to real Codex config" >&2
  exit 54
fi
profile="$(cat "$CODEX_HOME/c11.config.toml")"
for expected in \
  "hooks = true" \
  "codex-hook session-start" \
  "codex-hook prompt-submit" \
  "codex-hook permission-request" \
  "codex-hook pre-tool-use" \
  "codex-hook post-tool-use" \
  "codex-hook stop --status-only"; do
  if [[ "$profile" != *"$expected"* ]]; then
    echo "missing $expected in c11 profile config" >&2
    exit 55
  fi
done
"""


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def hook_configs(argv: list[str]) -> list[str]:
    configs: list[str] = []
    index = 0
    while index < len(argv):
        if argv[index] == "-c" and index + 1 < len(argv):
            configs.append(argv[index + 1])
            index += 2
        else:
            index += 1
    return configs


def make_codex_state_db(
    codex_home: Path,
    *,
    session_id: str,
    cwd: str,
    extra_rows: list[tuple[str, str]] | None = None,
    created_at_ms: bool = True,
    created_at: bool = True,
) -> None:
    codex_home.mkdir(parents=True, exist_ok=True)
    db_path = codex_home / "state_5.sqlite"
    rows = [(session_id, cwd), *(extra_rows or [])]
    created_columns = []
    created_values = []
    if created_at:
        created_columns.append("created_at INTEGER")
        created_values.append("4102444800")
    if created_at_ms:
        created_columns.append("created_at_ms INTEGER")
        created_values.append("4102444800000")
    created_columns_sql = ",\n  ".join(created_columns)
    if created_columns_sql:
        created_columns_sql = ",\n  " + created_columns_sql
    created_values_sql = (", " + ", ".join(created_values)) if created_values else ""
    inserts = "\n".join(
        f"INSERT INTO threads (id, cwd, archived{', created_at' if created_at else ''}{', created_at_ms' if created_at_ms else ''}) "
        f"VALUES ('{row_session}', '{row_cwd}', 0{created_values_sql});"
        for row_session, row_cwd in rows
    )
    sql = f"""
CREATE TABLE threads (
  id TEXT,
  cwd TEXT,
  archived INTEGER{created_columns_sql}
);
{inserts}
"""
    subprocess.run(["/usr/bin/sqlite3", str(db_path), sql], check=True)


def run_wrapper(
    *,
    socket_state: str,
    argv: list[str],
    extra_env: dict[str, str] | None = None,
    real_codex_script: str = DEFAULT_FAKE_CODEX,
    wrapper_cwd: Path | None = None,
    overlay_setup: str = "dir",
) -> tuple[int, list[str], list[str], str, str, str, str]:
    with tempfile.TemporaryDirectory(prefix="c11-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "codex"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        real_pid_log = tmp / "real-pid.log"
        real_start_log = tmp / "real-start.log"
        real_resume_log = tmp / "real-resume.log"
        c11_log = tmp / "c11.log"
        socket_path = str(tmp / "c11.sock")
        real_codex_home = tmp / "real-codex-home"
        real_codex_home.mkdir(parents=True, exist_ok=True)
        (real_codex_home / "config.toml").write_text("# real Codex config\n", encoding="utf-8")
        (real_codex_home / "auth.json").write_text('{"token":"real-auth-token"}\n', encoding="utf-8")
        (real_codex_home / "history.jsonl").write_text("tenant history\n", encoding="utf-8")
        (real_codex_home / "state_5.sqlite").write_text("tenant state\n", encoding="utf-8")
        (real_codex_home / "logs_2.sqlite").write_text("tenant logs\n", encoding="utf-8")
        (real_codex_home / "sessions").mkdir()
        (real_codex_home / "sessions" / "tenant-session.jsonl").write_text("tenant session\n", encoding="utf-8")
        (real_codex_home / "skills").mkdir()
        (real_codex_home / "skills" / "tenant-skill.md").write_text("tenant skill\n", encoding="utf-8")
        overlay_dir = tmp / "c11-codex-home-overlays"
        if overlay_setup == "dir":
            overlay_dir.mkdir(parents=True, exist_ok=True)
        elif overlay_setup == "legacy-mirror":
            overlay_dir.mkdir(parents=True, exist_ok=True)
            overlay_key = hashlib.md5(str(real_codex_home).encode("utf-8")).hexdigest()
            overlay = overlay_dir / overlay_key
            overlay.mkdir(parents=True, exist_ok=True)
            for name in ("config.toml", "auth.json", "history.jsonl", "state_5.sqlite", "logs_2.sqlite", "sessions", "skills"):
                (overlay / name).symlink_to(real_codex_home / name, target_is_directory=(real_codex_home / name).is_dir())
        elif overlay_setup == "symlink-base":
            overlay_target = tmp / "overlay-target"
            overlay_target.mkdir(parents=True, exist_ok=True)
            overlay_dir.symlink_to(overlay_target, target_is_directory=True)
        elif overlay_setup == "symlink-overlay":
            overlay_dir.mkdir(parents=True, exist_ok=True)
            overlay_target = tmp / "overlay-leaf-target"
            overlay_target.mkdir(parents=True, exist_ok=True)
            overlay_key = hashlib.md5(str(real_codex_home).encode("utf-8")).hexdigest()
            (overlay_dir / overlay_key).symlink_to(overlay_target, target_is_directory=True)
        else:
            raise ValueError(f"unknown overlay setup {overlay_setup!r}")

        make_executable(
            real_dir / "codex",
            real_codex_script,
        )

        make_executable(
            wrapper_dir / "c11",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s timeout=%s\\n' "$*" "${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC-__UNSET__}" >> "$FAKE_C11_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  if [[ "${FAKE_C11_PING_OK:-0}" == "1" ]]; then
    exit 0
  fi
  exit 1
fi
exit 0
""",
        )

        test_socket: socket.socket | None = None
        if socket_state in {"live", "stale"}:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:/usr/bin:/bin"
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_WORKSPACE_ID"] = "workspace:test"
        env["CMUX_SOCKET_PATH"] = socket_path
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_PID_LOG"] = str(real_pid_log)
        env["FAKE_REAL_START_LOG"] = str(real_start_log)
        env["FAKE_REAL_RESUME_LOG"] = str(real_resume_log)
        env["FAKE_C11_LOG"] = str(c11_log)
        env["FAKE_C11_PING_OK"] = "1" if socket_state == "live" else "0"
        env["CMUX_CODEX_DISABLE_STATE_WATCHER"] = "1"
        env["CODEX_HOME"] = str(real_codex_home)
        env["CMUX_CODEX_HOME_OVERLAY_DIR"] = str(overlay_dir)
        env["EXPECTED_CODEX_HOME_OVERLAY_DIR"] = str(overlay_dir)
        env["EXPECTED_CODEX_REAL_HOME"] = str(real_codex_home)
        if extra_env:
            env.update(extra_env)

        try:
            proc = subprocess.run(
                ["codex", *argv],
                cwd=wrapper_cwd or tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
                timeout=15,
            )
            if socket_state == "live":
                for _ in range(20):
                    lines = read_lines(c11_log)
                    if (
                        any("set-agent --type codex" in line for line in lines)
                        and any("set-agent-pid codex" in line for line in lines)
                    ):
                        time.sleep(0.1)
                        break
                    time.sleep(0.05)
        finally:
            if test_socket is not None:
                test_socket.close()

        pid_lines = read_lines(real_pid_log)
        pid_value = pid_lines[0] if pid_lines else ""
        start_lines = read_lines(real_start_log)
        start_value = start_lines[0] if start_lines else ""
        resume_lines = read_lines(real_resume_log)
        resume_value = resume_lines[0] if resume_lines else ""
        return proc.returncode, read_lines(real_args_log), read_lines(c11_log), proc.stderr.strip(), pid_value, start_value, resume_value


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_live_socket_injects_notify_bridge(failures: list[str]) -> None:
    code, real_argv, c11_log, stderr, pid_value, start_value, resume_value = run_wrapper(socket_state="live", argv=["hello"])
    expect(code == 0, f"live socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv[-1:] == ["hello"], f"live socket: expected original arg last, got {real_argv}", failures)
    expect(any(" ping" in line for line in c11_log), f"live socket: expected c11 ping, got {c11_log}", failures)
    expect(any("set-agent --type codex" in line for line in c11_log), f"live socket: missing set-agent call: {c11_log}", failures)
    expect(any("set-agent-pid codex" in line for line in c11_log), f"live socket: missing PID registration call: {c11_log}", failures)
    expect(any("clear-notifications --workspace workspace:test" in line for line in c11_log), f"live socket: initial prompt should clear stale notifications: {c11_log}", failures)
    expect(any("set-status codex Running" in line for line in c11_log), f"live socket: initial prompt should mark Codex Running: {c11_log}", failures)
    expect(pid_value.isdigit(), f"live socket: expected CMUX_CODEX_PID, got {pid_value!r}", failures)
    expect(start_value.isdigit(), f"live socket: expected CMUX_CODEX_START_SEC, got {start_value!r}", failures)
    expect(resume_value == "__UNSET__", f"live socket: unexpected resume id hint {resume_value!r}", failures)
    expect("--profile-v2" in real_argv, f"live socket: expected c11 Codex profile injection, got {real_argv}", failures)
    if "--profile-v2" in real_argv:
        profile_index = real_argv.index("--profile-v2")
        expect(profile_index + 1 < len(real_argv), f"live socket: missing --profile-v2 value in {real_argv}", failures)
        if profile_index + 1 < len(real_argv):
            expect(real_argv[profile_index + 1] == "c11", f"live socket: expected --profile-v2 c11, got {real_argv}", failures)
    expect(
        "codex_hooks" not in "\n".join(real_argv),
        f"live socket: wrapper must not use deprecated codex_hooks alias: {real_argv}",
        failures,
    )

    configs = hook_configs(real_argv)
    combined = "\n".join(configs)
    expect(len(configs) == 3, f"live socket: expected notify and TUI notification -c configs only, got {configs}", failures)
    expect("notify=" in combined, f"live socket: missing notify config: {configs}", failures)
    expect("tui.notifications=true" in combined, f"live socket: missing TUI notifications config: {configs}", failures)
    expect('tui.notification_condition="always"' in combined, f"live socket: missing TUI always-notify config: {configs}", failures)
    for token in ["codex-hook", "notify", "--workspace", "workspace:test", "--surface", "surface:test", "--started-at"]:
        expect(token in combined, f"live socket: notify config missing {token!r}: {configs}", failures)
    hook_commands = [config for config in configs if config.startswith("hooks.")]
    expect(
        hook_commands == [],
        f"live socket: wrapper must not inject ignored -c hooks.* runtime overrides: {hook_commands}",
        failures,
    )
    expect(
        "--enable" not in real_argv,
        f"live socket: wrapper must not force Codex hooks with --enable: {real_argv}",
        failures,
    )
    expect("hooks.Stop" not in combined, f"live socket: Stop hook should not duplicate notify completion: {configs}", failures)
    expect(
        "--dangerously-bypass-hook-trust" not in real_argv,
        f"live socket: wrapper must not bypass Codex hook trust: {real_argv}",
        failures,
    )


def test_live_socket_uses_c11_owned_profile_layer(failures: list[str]) -> None:
    code, real_argv, _, stderr, _, _, _ = run_wrapper(
        socket_state="live",
        argv=["hello"],
        real_codex_script=PROFILE_CHECKING_FAKE_CODEX,
    )
    expect(code == 0, f"profile layer: wrapper exited {code}: {stderr}", failures)
    expect("--profile-v2" in real_argv, f"profile layer: expected --profile-v2 in args, got {real_argv}", failures)
    if "--profile-v2" in real_argv:
        index = real_argv.index("--profile-v2")
        expect(index + 1 < len(real_argv), f"profile layer: missing --profile-v2 value in {real_argv}", failures)
        if index + 1 < len(real_argv):
            expect(real_argv[index + 1] == "c11", f"profile layer: expected c11 profile, got {real_argv}", failures)
    expect(
        "--dangerously-bypass-hook-trust" not in real_argv,
        f"profile layer: wrapper must let Codex's hook review own trust: {real_argv}",
        failures,
    )


def test_profile_layer_rejects_symlinked_overlay_paths(failures: list[str]) -> None:
    for setup in ("symlink-base", "symlink-overlay"):
        code, real_argv, _, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            overlay_setup=setup,
        )
        expect(code == 0, f"{setup}: wrapper should fall through without profile overlay, exited {code}: {stderr}", failures)
        expect(
            "--profile-v2" not in real_argv,
            f"{setup}: symlinked c11 overlay path must not receive a managed profile layer: {real_argv}",
            failures,
        )


def test_profile_layer_prunes_legacy_mirror_symlinks(failures: list[str]) -> None:
    code, real_argv, _, stderr, _, _, _ = run_wrapper(
        socket_state="live",
        argv=["hello"],
        real_codex_script=PROFILE_CHECKING_FAKE_CODEX,
        overlay_setup="legacy-mirror",
    )
    expect(code == 0, f"legacy profile mirror: wrapper exited {code}: {stderr}", failures)
    expect("--profile-v2" in real_argv, f"legacy profile mirror: expected managed c11 profile, got {real_argv}", failures)


def test_plain_interactive_codex_does_not_mark_running(failures: list[str]) -> None:
    code, real_argv, c11_log, stderr, _, _, _ = run_wrapper(socket_state="live", argv=[])
    expect(code == 0, f"plain interactive: wrapper exited {code}: {stderr}", failures)
    expect("--cd" in real_argv, f"plain interactive: expected pane cwd injection, got {real_argv}", failures)
    expect(any("set-agent --type codex" in line for line in c11_log), f"plain interactive: missing set-agent call: {c11_log}", failures)
    expect(any("set-agent-pid codex" in line for line in c11_log), f"plain interactive: missing PID registration call: {c11_log}", failures)
    expect(
        all("set-status codex Running" not in line for line in c11_log),
        f"plain interactive: must not mark Running before a user prompt: {c11_log}",
        failures,
    )


def test_fresh_launch_clears_declare_session_metadata(failures: list[str]) -> None:
    code, _, c11_log, stderr, _, _, _ = run_wrapper(
        socket_state="live",
        argv=[],
        real_codex_script=DEFAULT_FAKE_CODEX + "sleep 1\n",
    )
    expect(code == 0, f"fresh metadata clear: wrapper exited {code}: {stderr}", failures)
    clear_lines = [line for line in c11_log if "clear-metadata" in line]
    expect(clear_lines, f"fresh metadata clear: missing clear-metadata call: {c11_log}", failures)
    expect(
        any("--key codex.session_id --key codex.session_project_dir" in line for line in clear_lines),
        f"fresh metadata clear: expected both Codex session keys to be cleared together: {clear_lines}",
        failures,
    )
    expect(
        any("--source declare" in line for line in clear_lines),
        f"fresh metadata clear: must clear only declare-level metadata: {clear_lines}",
        failures,
    )
    expect(
        all("--source explicit" not in line for line in clear_lines),
        f"fresh metadata clear: must not use explicit source: {clear_lines}",
        failures,
    )


def test_state_watcher_writes_unambiguous_session_metadata(failures: list[str]) -> None:
    session_id = "11111111-2222-3333-4444-555555555555"
    distractor_id = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    with tempfile.TemporaryDirectory(prefix="c11-codex-state-home-") as td:
        codex_home = Path(td) / "codex-home"
        project_dir = Path(td).resolve() / "project"
        project_dir.mkdir()
        make_codex_state_db(
            codex_home,
            session_id=session_id,
            cwd=str(project_dir),
            extra_rows=[(distractor_id, "/Users/test/other-project")],
        )

        code, _, c11_log, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            extra_env={
                "CODEX_HOME": str(codex_home),
                "CMUX_CODEX_DISABLE_STATE_WATCHER": "0",
                "CMUX_CODEX_DISABLE_PROFILE_HOOKS": "1",
                "CMUX_CODEX_STATE_WATCHER_SETTLE_SEC": "0.1",
            },
            real_codex_script=DEFAULT_FAKE_CODEX + "sleep 2\n",
            wrapper_cwd=project_dir,
        )

    expect(code == 0, f"state watcher: wrapper exited {code}: {stderr}", failures)
    expect(
        any(f"set-metadata --key codex.session_id --value {session_id}" in line for line in c11_log),
        f"state watcher: missing codex.session_id metadata write: {c11_log}",
        failures,
    )
    expect(
        any(f"set-metadata --key codex.session_id --value {session_id} --workspace workspace:test --surface surface:test --source heuristic" in line for line in c11_log),
        f"state watcher: inferred session id must be written at heuristic precedence: {c11_log}",
        failures,
    )
    expect(
        any(f"set-metadata --key codex.session_project_dir --value {project_dir}" in line for line in c11_log),
        f"state watcher: missing codex.session_project_dir metadata write: {c11_log}",
        failures,
    )


def test_state_watcher_handles_created_time_schema_variants(failures: list[str]) -> None:
    cases = [
        ("created-at-ms-only", True, False, "11111111-2222-3333-4444-555555555555", True),
        ("created-at-only", False, True, "66666666-7777-8888-9999-aaaaaaaaaaaa", True),
        ("missing-created-time", False, False, "bbbbbbbb-cccc-dddd-eeee-ffffffffffff", False),
    ]
    for label, has_created_at_ms, has_created_at, session_id, should_capture in cases:
        with tempfile.TemporaryDirectory(prefix=f"c11-codex-state-{label}-") as td:
            codex_home = Path(td) / "codex-home"
            project_dir = Path(td).resolve() / "project"
            project_dir.mkdir()
            make_codex_state_db(
                codex_home,
                session_id=session_id,
                cwd=str(project_dir),
                created_at_ms=has_created_at_ms,
                created_at=has_created_at,
            )

            code, _, c11_log, stderr, _, _, _ = run_wrapper(
                socket_state="live",
                argv=["hello"],
                extra_env={
                    "CODEX_HOME": str(codex_home),
                    "CMUX_CODEX_DISABLE_STATE_WATCHER": "0",
                    "CMUX_CODEX_DISABLE_PROFILE_HOOKS": "1",
                    "CMUX_CODEX_STATE_WATCHER_SETTLE_SEC": "0.1",
                },
                real_codex_script=DEFAULT_FAKE_CODEX + "sleep 2\n",
                wrapper_cwd=project_dir,
            )

        expect(code == 0, f"{label}: wrapper exited {code}: {stderr}", failures)
        captured = any(f"set-metadata --key codex.session_id --value {session_id}" in line for line in c11_log)
        if should_capture:
            expect(captured, f"{label}: expected session capture with available created-time column: {c11_log}", failures)
        else:
            expect(not captured, f"{label}: must not capture without a created-time column: {c11_log}", failures)


def test_state_watcher_rejects_same_cwd_ambiguity(failures: list[str]) -> None:
    first_id = "11111111-2222-3333-4444-555555555555"
    second_id = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    with tempfile.TemporaryDirectory(prefix="c11-codex-state-ambiguous-") as td:
        codex_home = Path(td) / "codex-home"
        project_dir = Path(td).resolve() / "project"
        project_dir.mkdir()
        make_codex_state_db(
            codex_home,
            session_id=first_id,
            cwd=str(project_dir),
            extra_rows=[(second_id, str(project_dir))],
        )

        code, _, c11_log, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            extra_env={
                "CODEX_HOME": str(codex_home),
                "CMUX_CODEX_DISABLE_STATE_WATCHER": "0",
                "CMUX_CODEX_DISABLE_PROFILE_HOOKS": "1",
                "CMUX_CODEX_STATE_WATCHER_SETTLE_SEC": "0.1",
            },
            real_codex_script=DEFAULT_FAKE_CODEX + "sleep 2\n",
            wrapper_cwd=project_dir,
        )

    expect(code == 0, f"state watcher ambiguity: wrapper exited {code}: {stderr}", failures)
    expect(
        all("set-metadata --key codex.session_id" not in line for line in c11_log),
        f"state watcher ambiguity: must not write a session id when same-cwd candidates are ambiguous: {c11_log}",
        failures,
    )


def test_state_watcher_settles_before_writing_single_same_cwd_candidate(failures: list[str]) -> None:
    first_id = "11111111-2222-3333-4444-555555555555"
    second_id = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    with tempfile.TemporaryDirectory(prefix="c11-codex-state-delayed-ambiguous-") as td:
        codex_home = Path(td) / "codex-home"
        project_dir = Path(td).resolve() / "project"
        project_dir.mkdir()
        make_codex_state_db(
            codex_home,
            session_id=first_id,
            cwd=str(project_dir),
        )

        code, _, c11_log, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            extra_env={
                "CODEX_HOME": str(codex_home),
                "CMUX_CODEX_DISABLE_STATE_WATCHER": "0",
                "CMUX_CODEX_DISABLE_PROFILE_HOOKS": "1",
                "CMUX_CODEX_STATE_WATCHER_SETTLE_SEC": "0.8",
                "FAKE_SECOND_SESSION_ID": second_id,
                "FAKE_PROJECT_CWD": str(project_dir),
            },
            real_codex_script=DELAYED_AMBIGUOUS_STATE_ROW_FAKE_CODEX,
            wrapper_cwd=project_dir,
        )

    expect(code == 0, f"state watcher delayed ambiguity: wrapper exited {code}: {stderr}", failures)
    expect(
        all(f"set-metadata --key codex.session_id --value {first_id}" not in line for line in c11_log),
        f"state watcher delayed ambiguity: must not commit first same-cwd candidate before settle: {c11_log}",
        failures,
    )
    expect(
        all(f"set-metadata --key codex.session_id --value {second_id}" not in line for line in c11_log),
        f"state watcher delayed ambiguity: must not commit delayed same-cwd candidate either: {c11_log}",
        failures,
    )


def test_state_watcher_allows_single_global_fallback(failures: list[str]) -> None:
    session_id = "11111111-2222-3333-4444-555555555555"
    with tempfile.TemporaryDirectory(prefix="c11-codex-state-global-") as td:
        codex_home = Path(td) / "codex-home"
        shell_dir = Path(td).resolve() / "shell-project"
        codex_dir = Path(td).resolve() / "codex-recorded-project"
        shell_dir.mkdir()
        codex_dir.mkdir()
        make_codex_state_db(codex_home, session_id=session_id, cwd=str(codex_dir))

        code, _, c11_log, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            extra_env={
                "CODEX_HOME": str(codex_home),
                "CMUX_CODEX_DISABLE_STATE_WATCHER": "0",
                "CMUX_CODEX_DISABLE_PROFILE_HOOKS": "1",
                "CMUX_CODEX_STATE_WATCHER_SETTLE_SEC": "0.1",
            },
            real_codex_script=DEFAULT_FAKE_CODEX + "sleep 4\n",
            wrapper_cwd=shell_dir,
        )

    expect(code == 0, f"state watcher global fallback: wrapper exited {code}: {stderr}", failures)
    expect(
        any(f"set-metadata --key codex.session_id --value {session_id}" in line for line in c11_log),
        f"state watcher global fallback: missing codex.session_id metadata write: {c11_log}",
        failures,
    )
    expect(
        any(f"set-metadata --key codex.session_id --value {session_id} --workspace workspace:test --surface surface:test --source heuristic" in line for line in c11_log),
        f"state watcher global fallback: inferred session id must be heuristic precedence: {c11_log}",
        failures,
    )
    expect(
        any(f"set-metadata --key codex.session_project_dir --value {codex_dir}" in line for line in c11_log),
        f"state watcher global fallback: missing Codex-recorded project dir metadata write: {c11_log}",
        failures,
    )


def test_state_watcher_waits_for_cwd_candidate_before_global_fallback(failures: list[str]) -> None:
    global_session_id = "11111111-2222-3333-4444-555555555555"
    project_session_id = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    with tempfile.TemporaryDirectory(prefix="c11-codex-state-delayed-cwd-") as td:
        codex_home = Path(td) / "codex-home"
        project_dir = Path(td).resolve() / "project"
        global_dir = Path(td).resolve() / "other-project"
        project_dir.mkdir()
        global_dir.mkdir()
        make_codex_state_db(codex_home, session_id=global_session_id, cwd=str(global_dir))

        code, _, c11_log, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            extra_env={
                "CODEX_HOME": str(codex_home),
                "CMUX_CODEX_DISABLE_STATE_WATCHER": "0",
                "CMUX_CODEX_DISABLE_PROFILE_HOOKS": "1",
                "FAKE_PROJECT_SESSION_ID": project_session_id,
                "FAKE_PROJECT_CWD": str(project_dir),
            },
            real_codex_script=DELAYED_STATE_ROW_FAKE_CODEX,
            wrapper_cwd=project_dir,
        )

    expect(code == 0, f"state watcher delayed cwd: wrapper exited {code}: {stderr}", failures)
    expect(
        any(f"set-metadata --key codex.session_id --value {project_session_id}" in line for line in c11_log),
        f"state watcher delayed cwd: should prefer delayed cwd candidate over early global candidate: {c11_log}",
        failures,
    )
    expect(
        all(f"set-metadata --key codex.session_id --value {global_session_id}" not in line for line in c11_log),
        f"state watcher delayed cwd: must not write early global fallback candidate: {c11_log}",
        failures,
    )


def test_missing_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, c11_log, stderr, pid_value, _, _ = run_wrapper(socket_state="missing", argv=["hello"])
    expect(code == 0, f"missing socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["hello"], f"missing socket: expected passthrough args, got {real_argv}", failures)
    expect(c11_log == [], f"missing socket: expected no c11 calls, got {c11_log}", failures)
    expect(pid_value == "__UNSET__", f"missing socket: expected no CMUX_CODEX_PID, got {pid_value!r}", failures)


def test_stale_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, c11_log, stderr, pid_value, _, _ = run_wrapper(socket_state="stale", argv=["hello"])
    expect(code == 0, f"stale socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["hello"], f"stale socket: expected passthrough args, got {real_argv}", failures)
    expect(any(" ping" in line for line in c11_log), f"stale socket: expected c11 ping probe, got {c11_log}", failures)
    expect(pid_value == "__UNSET__", f"stale socket: expected no CMUX_CODEX_PID, got {pid_value!r}", failures)


def test_disabled_env_skips_socket_probe_and_hook_injection(failures: list[str]) -> None:
    code, real_argv, c11_log, stderr, _, _, _ = run_wrapper(
        socket_state="live",
        argv=["hello"],
        extra_env={"CMUX_CODEX_HOOKS_DISABLED": "1"},
    )
    expect(code == 0, f"disabled env: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["hello"], f"disabled env: expected passthrough args, got {real_argv}", failures)
    expect(c11_log == [], f"disabled env: expected no c11 calls, got {c11_log}", failures)


def test_parent_codex_session_env_is_sanitized(failures: list[str]) -> None:
    code, _, _, stderr, _, _, _ = run_wrapper(
        socket_state="live",
        argv=["hello"],
        extra_env={
            "CODEX_THREAD_ID": "aaaaaaaa-1111-2222-3333-444455556666",
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop",
            "CODEX_SHELL": "1",
            "CODEX_CI": "1",
            "CODEX_SANDBOX_NETWORK_DISABLED": "1",
        },
        real_codex_script=SANITIZING_FAKE_CODEX,
    )
    expect(code == 0, f"parent Codex env sanitize: wrapper exited {code}: {stderr}", failures)


def test_parent_codex_session_env_is_sanitized_on_passthrough_paths(failures: list[str]) -> None:
    parent_env = {
        "CODEX_THREAD_ID": "aaaaaaaa-1111-2222-3333-444455556666",
        "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop",
        "CODEX_SHELL": "1",
        "CODEX_CI": "1",
        "CODEX_SANDBOX_NETWORK_DISABLED": "1",
    }
    cases = [
        ("stale socket", "stale", ["hello"], {}),
        ("disabled integration", "live", ["hello"], {"CMUX_CODEX_HOOKS_DISABLED": "1"}),
        ("auxiliary command", "live", ["exec", "hello"], {}),
    ]
    for label, socket_state, argv, env_extra in cases:
        code, _, _, stderr, _, _, _ = run_wrapper(
            socket_state=socket_state,
            argv=argv,
            extra_env={**parent_env, **env_extra},
            real_codex_script=SANITIZING_FAKE_CODEX,
        )
        expect(code == 0, f"{label}: parent Codex env sanitize exited {code}: {stderr}", failures)


def test_live_socket_injects_pane_cwd_when_absent(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="c11-codex-cwd-") as td:
        project_dir = Path(td).resolve() / "project"
        project_dir.mkdir()
        code, real_argv, _, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            wrapper_cwd=project_dir,
        )
    expect(code == 0, f"cwd injection: wrapper exited {code}: {stderr}", failures)
    expect("--cd" in real_argv, f"cwd injection: expected --cd in args, got {real_argv}", failures)
    if "--cd" in real_argv:
        cd_index = real_argv.index("--cd")
        expect(cd_index + 1 < len(real_argv), f"cwd injection: missing --cd value in {real_argv}", failures)
        if cd_index + 1 < len(real_argv):
            expect(real_argv[cd_index + 1] == str(project_dir), f"cwd injection: expected {project_dir}, got {real_argv}", failures)


def test_existing_cd_arg_is_preserved(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="c11-codex-cwd-preserve-") as td:
        project_dir = Path(td).resolve() / "project"
        explicit_dir = Path(td).resolve() / "explicit"
        project_dir.mkdir()
        explicit_dir.mkdir()
        code, real_argv, _, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["--cd", str(explicit_dir), "hello"],
            wrapper_cwd=project_dir,
        )
    expect(code == 0, f"cwd preserve: wrapper exited {code}: {stderr}", failures)
    expect(real_argv.count("--cd") == 1, f"cwd preserve: expected one --cd, got {real_argv}", failures)
    if "--cd" in real_argv:
        cd_index = real_argv.index("--cd")
        expect(real_argv[cd_index + 1] == str(explicit_dir), f"cwd preserve: expected explicit dir, got {real_argv}", failures)


def test_target_project_env_tracks_effective_cd(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="c11-codex-cwd-env-") as td:
        project_dir = Path(td).resolve() / "project"
        explicit_dir = Path(td).resolve() / "explicit"
        project_dir.mkdir()
        explicit_dir.mkdir()
        code, _, _, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["--cd", str(explicit_dir), "hello"],
            extra_env={"EXPECTED_CMUX_CODEX_PROJECT_DIR": str(explicit_dir)},
            real_codex_script=PROJECT_DIR_CHECKING_FAKE_CODEX,
            wrapper_cwd=project_dir,
        )
    expect(code == 0, f"target project env explicit --cd: wrapper exited {code}: {stderr}", failures)

    with tempfile.TemporaryDirectory(prefix="c11-codex-cwd-env-symlink-") as td:
        project_dir = Path(td).resolve() / "project"
        explicit_dir = Path(td).resolve() / "explicit"
        symlink_dir = Path(td).resolve() / "explicit-link"
        project_dir.mkdir()
        explicit_dir.mkdir()
        symlink_dir.symlink_to(explicit_dir, target_is_directory=True)
        code, _, _, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["--cd", str(symlink_dir), "hello"],
            extra_env={"EXPECTED_CMUX_CODEX_PROJECT_DIR": str(explicit_dir)},
            real_codex_script=PROJECT_DIR_CHECKING_FAKE_CODEX,
            wrapper_cwd=project_dir,
        )
    expect(code == 0, f"target project env symlink --cd: wrapper exited {code}: {stderr}", failures)

    with tempfile.TemporaryDirectory(prefix="c11-codex-cwd-env-default-") as td:
        project_dir = Path(td).resolve() / "project"
        project_dir.mkdir()
        code, _, _, stderr, _, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            extra_env={"EXPECTED_CMUX_CODEX_PROJECT_DIR": str(project_dir)},
            real_codex_script=PROJECT_DIR_CHECKING_FAKE_CODEX,
            wrapper_cwd=project_dir,
        )
    expect(code == 0, f"target project env default cwd: wrapper exited {code}: {stderr}", failures)


def test_auxiliary_commands_passthrough_after_probe(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="c11-codex-passthrough-cwd-") as td:
        passthrough_cases = [
            ["doctor"],
            ["update"],
            ["remote-control"],
            ["e", "hello"],
            ["a"],
            ["-m", "gpt-5.5", "exec", "hello"],
            ["--cd", td, "doctor"],
            ["-c", "model=\"gpt-5.5\"", "review"],
            ["--strict-config", "--help"],
        ]
        for argv in passthrough_cases:
            label = " ".join(argv)
            code, real_argv, c11_log, stderr, _, _, _ = run_wrapper(socket_state="live", argv=argv)
            expect(code == 0, f"{label}: wrapper exited {code}: {stderr}", failures)
            expect(real_argv == argv, f"{label}: expected passthrough args, got {real_argv}", failures)
            expect(all("set-agent --type codex" not in line for line in c11_log), f"{label}: must not set agent, got {c11_log}", failures)
            expect(all("set-agent-pid codex" not in line for line in c11_log), f"{label}: must not register agent PID, got {c11_log}", failures)
            injected_configs = [
                config for config in hook_configs(real_argv)
                if config.startswith("notify=") or config.startswith("tui.")
            ]
            expect(injected_configs == [], f"{label}: must not inject c11 configs, got {real_argv}", failures)


def test_resume_session_id_exported_for_metadata_capture(failures: list[str]) -> None:
    session_id = "abc12345-ef67-890a-bcde-f0123456789a"
    code, real_argv, c11_log, stderr, _, _, resume_value = run_wrapper(
        socket_state="live",
        argv=["resume", session_id],
    )
    expect(code == 0, f"resume: wrapper exited {code}: {stderr}", failures)
    expect(real_argv[-2:] == ["resume", session_id], f"resume: expected original args last, got {real_argv}", failures)
    expect(any("set-agent --type codex" in line for line in c11_log), f"resume: missing set-agent call: {c11_log}", failures)
    expect(any("set-agent-pid codex" in line for line in c11_log), f"resume: missing PID registration call: {c11_log}", failures)
    expect(all("set-status codex Running" not in line for line in c11_log), f"resume: must not mark Running without a prompt: {c11_log}", failures)
    expect(all("clear-metadata" not in line for line in c11_log), f"resume: must not clear captured resume metadata: {c11_log}", failures)
    expect(any("set-metadata --key codex.session_project_dir" in line for line in c11_log), f"resume: missing project-dir metadata write: {c11_log}", failures)
    expect(resume_value == session_id, f"resume: expected CMUX_CODEX_RESUME_SESSION_ID, got {resume_value!r}", failures)

    with tempfile.TemporaryDirectory(prefix="c11-codex-resume-cwd-") as td:
        code, real_argv, c11_log, stderr, _, _, resume_value = run_wrapper(
            socket_state="live",
            argv=["--cd", td, "resume", "-m", "gpt-5.5", session_id],
        )
    expect(code == 0, f"resume with options: wrapper exited {code}: {stderr}", failures)
    expect(real_argv[-6:] == ["--cd", td, "resume", "-m", "gpt-5.5", session_id], f"resume with options: expected original args last, got {real_argv}", failures)
    expect(any("set-agent --type codex" in line for line in c11_log), f"resume with options: missing set-agent call: {c11_log}", failures)
    expect(any("set-agent-pid codex" in line for line in c11_log), f"resume with options: missing PID registration call: {c11_log}", failures)
    expect(resume_value == session_id, f"resume with options: expected CMUX_CODEX_RESUME_SESSION_ID, got {resume_value!r}", failures)


def main() -> int:
    failures: list[str] = []
    test_live_socket_injects_notify_bridge(failures)
    test_live_socket_uses_c11_owned_profile_layer(failures)
    test_profile_layer_rejects_symlinked_overlay_paths(failures)
    test_profile_layer_prunes_legacy_mirror_symlinks(failures)
    test_plain_interactive_codex_does_not_mark_running(failures)
    test_fresh_launch_clears_declare_session_metadata(failures)
    test_state_watcher_writes_unambiguous_session_metadata(failures)
    test_state_watcher_handles_created_time_schema_variants(failures)
    test_state_watcher_rejects_same_cwd_ambiguity(failures)
    test_state_watcher_settles_before_writing_single_same_cwd_candidate(failures)
    test_state_watcher_allows_single_global_fallback(failures)
    test_state_watcher_waits_for_cwd_candidate_before_global_fallback(failures)
    test_missing_socket_skips_hook_injection(failures)
    test_stale_socket_skips_hook_injection(failures)
    test_disabled_env_skips_socket_probe_and_hook_injection(failures)
    test_parent_codex_session_env_is_sanitized(failures)
    test_parent_codex_session_env_is_sanitized_on_passthrough_paths(failures)
    test_live_socket_injects_pane_cwd_when_absent(failures)
    test_existing_cd_arg_is_preserved(failures)
    test_target_project_env_tracks_effective_cd(failures)
    test_auxiliary_commands_passthrough_after_probe(failures)
    test_resume_session_id_exported_for_metadata_capture(failures)

    if failures:
        print("FAIL: codex wrapper regression checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: codex wrapper handles missing/stale sockets and injects the notify/state bridge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
