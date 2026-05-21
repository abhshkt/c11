#!/usr/bin/env python3
"""
Regression checks for the c11 Codex hook bridge.

This drives the real CLI against a running c11 socket because the bridge's
contract is socket-visible behavior: surface metadata, notifications, and
sidebar status rows.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from pathlib import Path


def resolve_c11_cli() -> str:
    explicit = os.environ.get("C11_CLI_BIN") or os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    raise RuntimeError("Set C11_CLI_BIN to the tagged c11 CLI binary under test.")


def can_connect(cli_path: str, path: str) -> bool:
    proc = subprocess.run(
        [cli_path, "--socket", path, "ping"],
        capture_output=True,
        text=True,
        check=False,
        timeout=2,
    )
    return proc.returncode == 0


def resolve_socket_path(cli_path: str) -> str:
    for key in ("C11_SOCKET", "CMUX_SOCKET_PATH", "CMUX_SOCKET"):
        candidate = os.environ.get(key)
        if candidate and os.path.exists(candidate) and can_connect(cli_path, candidate):
            return candidate

    raise RuntimeError("Set C11_SOCKET to the tagged c11 socket under test.")


def run_cli(
    cli_path: str,
    socket_path: str,
    args: list[str],
    *,
    payload: dict | None = None,
    env: dict[str, str] | None = None,
    clean_c11_env: bool = False,
) -> str:
    command_env = os.environ.copy()
    command_env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    command_env["C11_QUIET_DISCOVERY"] = "1"
    if clean_c11_env:
        for key in ("CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_SOCKET_PATH", "C11_WORKSPACE_ID", "C11_SURFACE_ID", "C11_SOCKET"):
            command_env.pop(key, None)
    if env:
        command_env.update(env)

    proc = subprocess.run(
        [cli_path, "--socket", socket_path, *args],
        input=json.dumps(payload) if payload is not None else None,
        text=True,
        capture_output=True,
        env=command_env,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"c11 {' '.join(args)} failed:\n"
            f"exit={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )
    return proc.stdout.strip()


def run_cli_with_open_stdin(
    cli_path: str,
    socket_path: str,
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    timeout: float = 2.0,
) -> str:
    command_env = os.environ.copy()
    command_env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    command_env["C11_QUIET_DISCOVERY"] = "1"
    if env:
        command_env.update(env)

    master_fd, slave_fd = os.openpty()
    proc = subprocess.Popen(
        [cli_path, "--socket", socket_path, *args],
        stdin=slave_fd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=command_env,
    )
    os.close(slave_fd)
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, stderr = proc.communicate()
        raise RuntimeError(
            f"c11 {' '.join(args)} hung with inherited open stdin:\n"
            f"stdout={stdout}\nstderr={stderr}"
        )
    finally:
        os.close(master_fd)
    if proc.returncode != 0:
        raise RuntimeError(
            f"c11 {' '.join(args)} failed:\n"
            f"exit={proc.returncode}\nstdout={stdout}\nstderr={stderr}"
        )
    return stdout.strip()


def parse_ok_id(output: str) -> str:
    if output.startswith("OK "):
        return output[3:].strip()
    raise RuntimeError(f"Expected OK id response, got {output!r}")


def first_surface_id(output: str) -> str:
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.lstrip("* ").split()
        for part in parts:
            if part.startswith("surface:"):
                return part
    raise RuntimeError(f"No surface found in output {output!r}")


def tree_uuid_for_ref(tree_output: str, kind: str, ref: str) -> str:
    for line in tree_output.splitlines():
        parts = line.strip().split()
        for index, part in enumerate(parts):
            if part == kind and index + 2 < len(parts) and parts[index + 1] == ref:
                return parts[index + 2]
    raise RuntimeError(f"Could not resolve {kind} {ref} in tree output {tree_output!r}")


def list_notifications(cli_path: str, socket_path: str, workspace_uuid: str) -> list[dict[str, str]]:
    output = run_cli(cli_path, socket_path, ["list-notifications"])
    if output == "No notifications" or not output:
        return []

    items: list[dict[str, str]] = []
    for line in output.splitlines():
        if ":" not in line:
            continue
        _, payload = line.split(":", 1)
        parts = payload.split("|", 6)
        if len(parts) < 7:
            continue
        notification_id, tab_id, surface_id, read_text, title, subtitle, body = parts
        if tab_id != workspace_uuid:
            continue
        items.append(
            {
                "id": notification_id,
                "workspace_id": tab_id,
                "surface_id": surface_id,
                "is_read": read_text,
                "title": title,
                "subtitle": subtitle,
                "body": body,
            }
        )
    return items


def wait_for_notifications(cli_path: str, socket_path: str, workspace_uuid: str, minimum: int) -> list[dict[str, str]]:
    deadline = time.time() + 4
    latest: list[dict[str, str]] = []
    while time.time() < deadline:
        latest = list_notifications(cli_path, socket_path, workspace_uuid)
        if len(latest) >= minimum:
            return latest
        time.sleep(0.05)
    return latest


def sqlite_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def make_codex_state_db(
    codex_home: Path,
    *,
    session_id: str,
    cwd: str,
    created_at_ms: bool,
    created_at: bool,
    created_at_value: int = 4102444800,
    created_at_ms_value: int = 4102444800000,
    include_cwd: bool = True,
) -> None:
    codex_home.mkdir(parents=True, exist_ok=True)
    db_path = codex_home / "state_5.sqlite"
    created_columns = []
    insert_columns = []
    insert_values = []
    if created_at:
        created_columns.append("created_at INTEGER")
        insert_columns.append("created_at")
        insert_values.append(str(created_at_value))
    if created_at_ms:
        created_columns.append("created_at_ms INTEGER")
        insert_columns.append("created_at_ms")
        insert_values.append(str(created_at_ms_value))
    created_columns_sql = ",\n  " + ",\n  ".join(created_columns) if created_columns else ""
    insert_columns_sql = ", " + ", ".join(insert_columns) if insert_columns else ""
    insert_values_sql = ", " + ", ".join(insert_values) if insert_values else ""
    cwd_column_sql = "  cwd TEXT,\n" if include_cwd else ""
    insert_cwd_column_sql = ", cwd" if include_cwd else ""
    insert_cwd_value_sql = f", {sqlite_literal(cwd)}" if include_cwd else ""
    sql = f"""
CREATE TABLE threads (
  id TEXT,
{cwd_column_sql}
  archived INTEGER{created_columns_sql}
);
INSERT INTO threads (id{insert_cwd_column_sql}, archived{insert_columns_sql})
VALUES ({sqlite_literal(session_id)}{insert_cwd_value_sql}, 0{insert_values_sql});
"""
    subprocess.run(["/usr/bin/sqlite3", str(db_path), sql], check=True)


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    if os.environ.get("C11_LIVE_BRIDGE_TEST") != "1":
        print("SKIP: set C11_LIVE_BRIDGE_TEST=1 with C11_CLI_BIN and C11_SOCKET to run the live bridge acceptance check")
        return 0

    try:
        cli_path = resolve_c11_cli()
        socket_path = resolve_socket_path(cli_path)
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    workspace_id = ""
    extra_workspace_ids: list[str] = []
    try:
        workspace_id = parse_ok_id(run_cli(cli_path, socket_path, ["new-workspace"]))
        surfaces_output = run_cli(cli_path, socket_path, ["list-panels", "--workspace", workspace_id])
        surface_id = first_surface_id(surfaces_output)
        tree_output = run_cli(cli_path, socket_path, ["--id-format", "both", "tree", "--workspace", workspace_id, "--no-layout"])
        workspace_uuid = tree_uuid_for_ref(tree_output, "workspace", workspace_id)
        hook_env = {
            "CMUX_SOCKET_PATH": socket_path,
            "CMUX_WORKSPACE_ID": workspace_id,
            "CMUX_SURFACE_ID": surface_id,
            "CMUX_CODEX_PID": str(os.getpid()),
        }

        run_cli(cli_path, socket_path, ["clear-notifications", "--workspace", workspace_id])
        run_cli(
            cli_path,
            socket_path,
            ["notify", "--title", "Guard", "--body", "Keep me", "--workspace", workspace_id, "--surface", surface_id],
        )
        guard_items = wait_for_notifications(cli_path, socket_path, workspace_uuid, minimum=1)
        expect(any(item["title"] == "Guard" for item in guard_items), "Expected guard notification before no-target check")

        no_target_output = run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "prompt-submit", "{}"],
            clean_c11_env=True,
        )
        expect(no_target_output == "", f"No-target codex-hook should exit quietly, got {no_target_output!r}")
        post_no_target_items = list_notifications(cli_path, socket_path, workspace_uuid)
        expect(
            any(item["title"] == "Guard" for item in post_no_target_items),
            "No-target codex-hook must not clear notifications from the focused workspace",
        )
        stale_workspace_output = run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "prompt-submit"],
            payload={"hook_event_name": "UserPromptSubmit", "cwd": str(Path.cwd())},
            env={"CMUX_WORKSPACE_ID": "workspace:does-not-exist", "CMUX_SURFACE_ID": surface_id},
        )
        expect(stale_workspace_output == "", f"Stale-workspace codex-hook should exit quietly, got {stale_workspace_output!r}")
        post_stale_workspace_items = list_notifications(cli_path, socket_path, workspace_uuid)
        expect(
            any(item["title"] == "Guard" for item in post_stale_workspace_items),
            "Stale-workspace codex-hook must not fall back to the focused workspace",
        )
        stale_surface_output = run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "permission-request"],
            payload={
                "hook_event_name": "PermissionRequest",
                "session_id": "99999999-aaaa-bbbb-cccc-dddddddddddd",
                "cwd": str(Path.cwd()),
                "tool_name": "Bash",
                "tool_input": {"command": "echo should-not-route"},
            },
            env={"CMUX_WORKSPACE_ID": workspace_id, "CMUX_SURFACE_ID": "surface:does-not-exist"},
        )
        expect(stale_surface_output == "", f"Stale-surface codex-hook should exit quietly, got {stale_surface_output!r}")
        post_stale_surface_items = list_notifications(cli_path, socket_path, workspace_uuid)
        expect(
            all(not (item["title"] == "Codex" and item["subtitle"] == "Permission") for item in post_stale_surface_items),
            f"Stale-surface codex-hook must not notify the focused surface: {post_stale_surface_items!r}",
        )
        status_after_stale_surface = run_cli(cli_path, socket_path, ["list-status", "--workspace", workspace_id])
        expect("codex=Needs input" not in status_after_stale_surface, f"Stale-surface hook must not set status: {status_after_stale_surface!r}")
        help_output = run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "help"],
            payload={"hook_event_name": "Stop", "last_assistant_message": "not a hook invocation"},
            clean_c11_env=True,
        )
        expect("c11 codex-hook" in help_output, f"codex-hook help should not require a target workspace: {help_output!r}")

        test_root = Path(tempfile.mkdtemp(prefix=f"c11_codex_hook_project_{os.getpid()}_"))
        project_dir = test_root / "project"
        project_dir.mkdir(parents=True, exist_ok=True)
        other_project_dir = test_root / "other"
        other_project_dir.mkdir(parents=True, exist_ok=True)
        linked_project_dir = test_root / "project-link"
        linked_project_dir.symlink_to(project_dir, target_is_directory=True)
        session_id = "abc12345-ef67-890a-bcde-f0123456789a"

        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start"],
            payload={
                "hook_event_name": "SessionStart",
                "session_id": "badbad00-0000-4000-8000-000000000000",
                "cwd": str(other_project_dir),
                "model": "gpt-5.5",
            },
            env={**hook_env, "CMUX_CODEX_PROJECT_DIR": str(project_dir)},
        )
        empty_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
            ],
        )
        expect(
            "badbad00-0000-4000-8000-000000000000" not in empty_metadata,
            f"Project-mismatched Codex hook must not write metadata: {empty_metadata!r}",
        )

        missing_cwd_session_id = "11111111-2222-3333-4444-555555555555"
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start"],
            payload={
                "hook_event_name": "SessionStart",
                "session_id": missing_cwd_session_id,
                "model": "gpt-5.5",
            },
            env={**hook_env, "CMUX_CODEX_PROJECT_DIR": str(project_dir)},
        )
        missing_cwd_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
            ],
        )
        expect(
            missing_cwd_session_id not in missing_cwd_metadata,
            f"Target-scoped Codex hook without cwd must fail closed: {missing_cwd_metadata!r}",
        )

        symlink_session_id = "22222222-3333-4444-5555-666666666666"
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start"],
            payload={
                "hook_event_name": "SessionStart",
                "session_id": symlink_session_id,
                "cwd": str(linked_project_dir),
                "model": "gpt-5.5",
            },
            env={**hook_env, "CMUX_CODEX_PROJECT_DIR": str(project_dir)},
        )
        symlink_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
            ],
        )
        expect(
            f"codex.session_id = {symlink_session_id}" in symlink_metadata,
            f"Symlinked hook cwd should match the physical target project dir: {symlink_metadata!r}",
        )

        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start"],
            payload={
                "hook_event_name": "SessionStart",
                "session_id": session_id,
                "cwd": str(project_dir),
                "model": "gpt-5.5",
            },
            env=hook_env,
        )
        metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
                "--key",
                "codex.session_project_dir",
                "--key",
                "codex.session_store",
                "--key",
                "model",
            ],
        )
        expect(f"codex.session_id = {session_id}" in metadata, f"Missing codex.session_id metadata: {metadata!r}")
        expect(f"codex.session_project_dir = {project_dir}" in metadata, f"Missing project-dir metadata: {metadata!r}")
        expect("codex.session_store = managed_overlay" in metadata, f"Missing Codex managed-overlay provenance: {metadata!r}")
        expect("model = gpt-5.5" in metadata, f"Missing Codex model metadata: {metadata!r}")

        real_home_session_id = "abababab-cdcd-efef-1234-567890abcdef"
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start"],
            payload={
                "hook_event_name": "SessionStart",
                "session_id": real_home_session_id,
                "cwd": str(project_dir),
                "model": "gpt-5.5",
            },
            env={**hook_env, "CMUX_CODEX_SESSION_STORE": "real_home"},
        )
        real_home_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
                "--key",
                "codex.session_store",
            ],
        )
        expect(
            f"codex.session_id = {real_home_session_id}" in real_home_metadata,
            f"Real-home hook should still capture session id: {real_home_metadata!r}",
        )
        expect(
            "codex.session_store = real_home" in real_home_metadata,
            f"Hook provenance must follow wrapper runtime env instead of hard-coding managed_overlay: {real_home_metadata!r}",
        )

        state_db_cases = [
            ("created-at-ms-only", True, False, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", True),
            ("created-at-only", False, True, "bbbbbbbb-cccc-dddd-eeee-ffffffffffff", True),
            ("missing-created-time", False, False, "cccccccc-dddd-eeee-ffff-000000000000", False),
        ]
        for label, has_created_at_ms, has_created_at, state_session_id, should_capture in state_db_cases:
            state_home = test_root / f"state-home-{label}"
            make_codex_state_db(
                state_home,
                session_id=state_session_id,
                cwd=str(project_dir),
                created_at_ms=has_created_at_ms,
                created_at=has_created_at,
            )
            for source in ("declare", "heuristic"):
                run_cli(
                    cli_path,
                    socket_path,
                    [
                        "clear-metadata",
                        "--workspace",
                        workspace_id,
                        "--surface",
                        surface_id,
                        "--key",
                        "codex.session_id",
                        "--key",
                        "codex.session_project_dir",
                        "--key",
                        "codex.session_store",
                        "--source",
                        source,
                    ],
                )
            run_cli(
                cli_path,
                socket_path,
                ["codex-hook", "session-start", "--started-at", "4102444799"],
                payload={
                    "hook_event_name": "SessionStart",
                    "cwd": str(project_dir),
                    "model": "gpt-5.5",
                },
                env={**hook_env, "CODEX_HOME": str(state_home)},
            )
            state_metadata = run_cli(
                cli_path,
                socket_path,
                [
                    "get-metadata",
                    "--workspace",
                    workspace_id,
                    "--surface",
                    surface_id,
                    "--key",
                    "codex.session_id",
                ],
            )
            if should_capture:
                expect(
                    f"codex.session_id = {state_session_id}" in state_metadata,
                    f"{label}: state DB schema should capture session id: {state_metadata!r}",
                )
            else:
                expect(
                    f"codex.session_id = {state_session_id}" not in state_metadata,
                    f"{label}: state DB schema without created time must not capture session id: {state_metadata!r}",
                )

        no_cwd_state_id = "45454545-4545-4545-8545-454545454545"
        no_cwd_state_home = test_root / "state-home-no-cwd-column"
        no_cwd_started_at = int(time.time()) - 5
        no_cwd_created_at = no_cwd_started_at + 1
        make_codex_state_db(
            no_cwd_state_home,
            session_id=no_cwd_state_id,
            cwd=str(other_project_dir),
            created_at_ms=True,
            created_at=True,
            created_at_value=no_cwd_created_at,
            created_at_ms_value=no_cwd_created_at * 1000,
            include_cwd=False,
        )
        for source in ("declare", "heuristic"):
            run_cli(
                cli_path,
                socket_path,
                [
                    "clear-metadata",
                    "--workspace",
                    workspace_id,
                    "--surface",
                    surface_id,
                    "--key",
                    "codex.session_id",
                    "--key",
                    "codex.session_project_dir",
                    "--key",
                    "codex.session_store",
                    "--source",
                    source,
                ],
            )
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start", "--started-at", str(no_cwd_started_at)],
            payload={
                "hook_event_name": "SessionStart",
                "cwd": str(project_dir),
                "model": "gpt-5.5",
            },
            env={**hook_env, "CODEX_HOME": str(no_cwd_state_home)},
        )
        no_cwd_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
                "--key",
                "codex.session_project_dir",
            ],
        )
        expect(
            f"codex.session_id = {no_cwd_state_id}" in no_cwd_metadata,
            f"No-cwd legacy schema should capture the one fresh global session id: {no_cwd_metadata!r}",
        )
        expect(
            "codex.session_project_dir" not in no_cwd_metadata,
            f"No-cwd legacy schema must not invent project-dir proof: {no_cwd_metadata!r}",
        )

        mismatch_state_id = "99999999-aaaa-bbbb-cccc-dddddddddddd"
        mismatch_state_home = test_root / "state-home-mismatch"
        make_codex_state_db(
            mismatch_state_home,
            session_id=mismatch_state_id,
            cwd=str(other_project_dir),
            created_at_ms=True,
            created_at=True,
        )
        for source in ("declare", "heuristic"):
            run_cli(
                cli_path,
                socket_path,
                [
                    "clear-metadata",
                    "--workspace",
                    workspace_id,
                    "--surface",
                    surface_id,
                    "--key",
                    "codex.session_id",
                    "--key",
                    "codex.session_project_dir",
                    "--key",
                    "codex.session_store",
                    "--source",
                    source,
                ],
            )
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start", "--started-at", "4102444799"],
            payload={
                "hook_event_name": "SessionStart",
                "cwd": str(project_dir),
                "model": "gpt-5.5",
            },
            env={**hook_env, "CODEX_HOME": str(mismatch_state_home)},
        )
        mismatch_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
                "--key",
                "codex.session_project_dir",
            ],
        )
        expect(
            mismatch_state_id not in mismatch_metadata,
            f"Global state DB fallback must not capture a session from another cwd: {mismatch_metadata!r}",
        )
        expect(
            str(other_project_dir) not in mismatch_metadata,
            f"Global state DB fallback must not pair another cwd with target cwd metadata: {mismatch_metadata!r}",
        )

        for delimiter_label, delimiter_cwd, delimiter_session_id in [
            ("tab", f"{project_dir}\tsuffix", "12121212-1212-4212-8212-121212121212"),
            ("newline", f"{project_dir}\nsuffix", "34343434-3434-4434-8434-343434343434"),
        ]:
            delimiter_started_at = int(time.time()) - 5
            delimiter_created_at = delimiter_started_at + 1
            delimiter_state_home = test_root / f"state-home-delimiter-{delimiter_label}"
            make_codex_state_db(
                delimiter_state_home,
                session_id=delimiter_session_id,
                cwd=delimiter_cwd,
                created_at_ms=True,
                created_at=True,
                created_at_value=delimiter_created_at,
                created_at_ms_value=delimiter_created_at * 1000,
            )
            for source in ("declare", "heuristic"):
                run_cli(
                    cli_path,
                    socket_path,
                    [
                        "clear-metadata",
                        "--workspace",
                        workspace_id,
                        "--surface",
                        surface_id,
                        "--key",
                        "codex.session_id",
                        "--key",
                        "codex.session_project_dir",
                        "--key",
                        "codex.session_store",
                        "--source",
                        source,
                    ],
                )
            run_cli(
                cli_path,
                socket_path,
                ["codex-hook", "session-start", "--started-at", str(delimiter_started_at)],
                payload={
                    "hook_event_name": "SessionStart",
                    "cwd": str(project_dir),
                    "model": "gpt-5.5",
                },
                env={**hook_env, "CODEX_HOME": str(delimiter_state_home)},
            )
            delimiter_metadata = run_cli(
                cli_path,
                socket_path,
                [
                    "get-metadata",
                    "--workspace",
                    workspace_id,
                    "--surface",
                    surface_id,
                    "--key",
                    "codex.session_id",
                    "--key",
                    "codex.session_project_dir",
                ],
            )
            expect(
                delimiter_session_id not in delimiter_metadata,
                f"{delimiter_label}: delimiter-corrupted DB cwd must not capture session id: {delimiter_metadata!r}",
            )
            expect(
                str(project_dir) not in delimiter_metadata,
                f"{delimiter_label}: delimiter-corrupted DB cwd must not truncate to target project dir: {delimiter_metadata!r}",
            )

        stale_session_id = "13131313-2424-3535-4646-575757575757"
        for source in ("declare", "heuristic"):
            run_cli(
                cli_path,
                socket_path,
                [
                    "clear-metadata",
                    "--workspace",
                    workspace_id,
                    "--surface",
                    surface_id,
                    "--key",
                    "codex.session_id",
                    "--key",
                    "codex.session_project_dir",
                    "--key",
                    "codex.session_store",
                    "--source",
                    source,
                ],
            )
        run_cli(
            cli_path,
            socket_path,
            [
                "set-metadata",
                "--key",
                "codex.session_id",
                "--value",
                stale_session_id,
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--source",
                "declare",
            ],
        )
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start"],
            payload={
                "hook_event_name": "SessionStart",
                "cwd": str(other_project_dir),
                "model": "gpt-5.5",
            },
            env=hook_env,
        )
        stale_pair_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
                "--key",
                "codex.session_project_dir",
            ],
        )
        expect(
            f"codex.session_id = {stale_session_id}" in stale_pair_metadata,
            f"Existing session id should remain present when no replacement is captured: {stale_pair_metadata!r}",
        )
        expect(
            str(other_project_dir) not in stale_pair_metadata,
            f"Hook without a captured session id must not re-pair stale id with new cwd: {stale_pair_metadata!r}",
        )

        operator_model = "operator/model"
        guarded_session_id = "33333333-4444-5555-6666-777777777777"
        run_cli(
            cli_path,
            socket_path,
            ["set-metadata", "--key", "model", "--value", operator_model, "--workspace", workspace_id, "--surface", surface_id],
        )
        run_cli(
            cli_path,
            socket_path,
            ["set-metadata", "--key", "terminal_type", "--value", "shell", "--workspace", workspace_id, "--surface", surface_id],
        )
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start"],
            payload={
                "hook_event_name": "SessionStart",
                "session_id": guarded_session_id,
                "cwd": str(project_dir),
                "model": "gpt-5.4",
            },
            env=hook_env,
        )
        guarded_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "terminal_type",
                "--key",
                "model",
                "--key",
                "codex.session_id",
            ],
        )
        expect("terminal_type = shell" in guarded_metadata, f"Hook declare writes must not override explicit terminal_type: {guarded_metadata!r}")
        expect(f"model = {operator_model}" in guarded_metadata, f"Hook declare writes must not override explicit model: {guarded_metadata!r}")
        expect(f"codex.session_id = {guarded_session_id}" in guarded_metadata, f"Hook should still refresh declare-level session metadata: {guarded_metadata!r}")

        heuristic_state_id = "77777777-8888-9999-aaaa-bbbbbbbbbbbb"
        guarded_state_home = test_root / "state-home-guarded"
        make_codex_state_db(
            guarded_state_home,
            session_id=heuristic_state_id,
            cwd=str(project_dir),
            created_at_ms=True,
            created_at=True,
        )
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "session-start", "--started-at", "4102444799"],
            payload={
                "hook_event_name": "SessionStart",
                "cwd": str(project_dir),
                "model": "gpt-5.5",
            },
            env={**hook_env, "CODEX_HOME": str(guarded_state_home)},
        )
        guarded_after_heuristic = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
            ],
        )
        expect(
            f"codex.session_id = {guarded_session_id}" in guarded_after_heuristic,
            f"State-DB heuristic metadata must not override hook-provided declare metadata: {guarded_after_heuristic!r}",
        )
        expect(
            heuristic_state_id not in guarded_after_heuristic,
            f"State-DB heuristic session id should remain hidden behind declare metadata: {guarded_after_heuristic!r}",
        )
        run_cli(
            cli_path,
            socket_path,
            ["set-metadata", "--key", "terminal_type", "--value", "codex", "--workspace", workspace_id, "--surface", surface_id],
        )

        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "permission-request"],
            payload={
                "hook_event_name": "PermissionRequest",
                "session_id": session_id,
                "cwd": str(project_dir),
                "tool_name": "Bash",
                "tool_input": {
                    "command": "git status --short",
                    "description": "Need approval for bridge test",
                },
            },
            env=hook_env,
        )
        permission_items = wait_for_notifications(cli_path, socket_path, workspace_uuid, minimum=1)
        expect(
            any(item["title"] == "Codex" and item["subtitle"] == "Permission" and "bridge test" in item["body"] for item in permission_items),
            f"Expected Codex permission notification, got {permission_items!r}",
        )
        status = run_cli(cli_path, socket_path, ["list-status", "--workspace", workspace_id])
        expect("codex=Needs input" in status, f"Expected Needs input status, got {status!r}")

        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "post-tool-use"],
            payload={
                "hook_event_name": "PostToolUse",
                "session_id": session_id,
                "cwd": str(project_dir),
                "tool_name": "Bash",
                "tool_input": {"command": "git status --short"},
            },
            env=hook_env,
        )
        post_tool_items = list_notifications(cli_path, socket_path, workspace_uuid)
        expect(post_tool_items == [], f"PostToolUse should clear stale notifications, got {post_tool_items!r}")
        status = run_cli(cli_path, socket_path, ["list-status", "--workspace", workspace_id])
        expect("codex=Running" in status, f"Expected Running status after PostToolUse, got {status!r}")

        other_workspace_id = parse_ok_id(run_cli(cli_path, socket_path, ["new-workspace"]))
        extra_workspace_ids.append(other_workspace_id)
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "pre-tool-use"],
            payload={
                "hook_event_name": "PreToolUse",
                "session_id": session_id,
                "cwd": str(project_dir),
                "tool_name": "Bash",
                "tool_input": {"command": f"--tab={other_workspace_id}\n--color=#ff0000"},
            },
            env=hook_env,
        )
        status = run_cli(cli_path, socket_path, ["list-status", "--workspace", workspace_id])
        expect(
            f"codex=Running --tab={other_workspace_id}" in status,
            f"Payload-derived status should be single-line data on the target workspace: {status!r}",
        )
        other_status = run_cli(cli_path, socket_path, ["list-status", "--workspace", other_workspace_id])
        expect(
            f"codex=Running --tab={other_workspace_id}" not in other_status,
            f"Payload-derived status must not be interpreted as a --tab option: {other_status!r}",
        )

        context_shadow_session_id = "12121212-3434-5656-7878-909090909090"
        context_shadow_output = run_cli_with_open_stdin(
            cli_path,
            socket_path,
            [
                "codex-hook",
                "notify",
                "--context-json",
                json.dumps(
                    {
                        "c11_context": {
                            "cwd": str(other_project_dir),
                            "model": "context/model",
                        },
                        "last_assistant_message": "Context should not win",
                    }
                ),
                json.dumps(
                    {
                        "hook_event_name": "Stop",
                        "notification": {
                            "session_id": context_shadow_session_id,
                            "cwd": str(project_dir),
                        },
                        "model": "gpt-5.5",
                        "last_assistant_message": "Payload wins",
                    }
                ),
            ],
            env=hook_env,
            timeout=2,
        )
        expect(context_shadow_output == "", f"Context-shadow notify should exit quietly, got {context_shadow_output!r}")
        context_shadow_items = wait_for_notifications(cli_path, socket_path, workspace_uuid, minimum=1)
        expect(
            any(item["title"] == "Codex" and item["subtitle"].startswith("Completed") and "Payload wins" in item["body"] for item in context_shadow_items),
            f"Expected Codex payload JSON to win over wrapper context, got {context_shadow_items!r}",
        )
        context_shadow_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
                "--key",
                "codex.session_project_dir",
            ],
        )
        expect(
            context_shadow_session_id in context_shadow_metadata and str(project_dir) in context_shadow_metadata,
            f"Payload metadata should win over wrapper context metadata: {context_shadow_metadata!r}",
        )

        legacy_context_shadow_session_id = "67676767-8989-abab-cdcd-efefefefefef"
        legacy_context_shadow_output = run_cli_with_open_stdin(
            cli_path,
            socket_path,
            [
                "codex-hook",
                "notify",
                "--context-json",
                json.dumps(
                    {
                        "cwd": str(other_project_dir),
                        "model": "legacy/context",
                    }
                ),
                json.dumps(
                    {
                        "hook_event_name": "Stop",
                        "notification": {
                            "session_id": legacy_context_shadow_session_id,
                            "cwd": str(project_dir),
                        },
                        "last_assistant_message": "Nested payload cwd wins",
                    }
                ),
            ],
            env=hook_env,
            timeout=2,
        )
        expect(legacy_context_shadow_output == "", f"Legacy context-shadow notify should exit quietly, got {legacy_context_shadow_output!r}")
        legacy_context_shadow_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
                "--key",
                "codex.session_project_dir",
            ],
        )
        expect(
            legacy_context_shadow_session_id in legacy_context_shadow_metadata and str(project_dir) in legacy_context_shadow_metadata,
            f"Nested payload metadata should outrank legacy top-level context JSON: {legacy_context_shadow_metadata!r}",
        )
        expect(
            str(other_project_dir) not in legacy_context_shadow_metadata,
            f"Legacy context cwd must be namespaced fallback, not top-level authority: {legacy_context_shadow_metadata!r}",
        )

        argv_notify_session_id = "55555555-6666-7777-8888-999999999999"
        argv_notify_output = run_cli_with_open_stdin(
            cli_path,
            socket_path,
            [
                "codex-hook",
                "notify",
                json.dumps(
                    {
                        "hook_event_name": "Stop",
                        "session_id": argv_notify_session_id,
                        "cwd": str(project_dir),
                        "last_assistant_message": "Argv JSON done",
                    }
                ),
            ],
            env=hook_env,
            timeout=2,
        )
        expect(argv_notify_output == "", f"Argv JSON notify should exit quietly, got {argv_notify_output!r}")
        argv_completion_items = wait_for_notifications(cli_path, socket_path, workspace_uuid, minimum=1)
        expect(
            any(item["title"] == "Codex" and item["subtitle"].startswith("Completed") and "Argv JSON done" in item["body"] for item in argv_completion_items),
            f"Expected argv JSON Codex completion notification without stdin EOF, got {argv_completion_items!r}",
        )
        status = run_cli(cli_path, socket_path, ["list-status", "--workspace", workspace_id])
        expect("codex=Idle" in status, f"Expected Idle status after argv JSON notify, got {status!r}")

        before_stdin_notify_count = len(list_notifications(cli_path, socket_path, workspace_uuid))
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "notify"],
            payload={
                "hook_event_name": "Stop",
                "session_id": session_id,
                "cwd": str(project_dir),
                "last_assistant_message": "Bridge done",
            },
            env=hook_env,
        )
        completion_items = wait_for_notifications(cli_path, socket_path, workspace_uuid, minimum=before_stdin_notify_count + 1)
        expect(
            any(item["title"] == "Codex" and item["subtitle"].startswith("Completed") and "Bridge done" in item["body"] for item in completion_items),
            f"Expected Codex completion notification, got {completion_items!r}",
        )
        status = run_cli(cli_path, socket_path, ["list-status", "--workspace", workspace_id])
        expect("codex=Idle" in status, f"Expected Idle status after notify, got {status!r}")

        before_status_only_count = len(list_notifications(cli_path, socket_path, workspace_uuid))
        status_only_session_id = "44444444-5555-6666-7777-888888888888"
        run_cli(
            cli_path,
            socket_path,
            ["codex-hook", "stop", "--status-only"],
            payload={
                "hook_event_name": "Stop",
                "session_id": status_only_session_id,
                "cwd": str(project_dir),
                "last_assistant_message": "No duplicate please",
            },
            env=hook_env,
        )
        after_status_only = list_notifications(cli_path, socket_path, workspace_uuid)
        expect(
            len(after_status_only) == before_status_only_count,
            f"status-only Stop must not add a notification: before={before_status_only_count} after={after_status_only!r}",
        )
        status_only_metadata = run_cli(
            cli_path,
            socket_path,
            [
                "get-metadata",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
                "--key",
                "codex.session_id",
                "--key",
                "codex.session_store",
            ],
        )
        expect(
            f"codex.session_id = {status_only_session_id}" in status_only_metadata,
            f"status-only Stop must still capture session metadata: {status_only_metadata!r}",
        )
        expect(
            "codex.session_store = managed_overlay" in status_only_metadata,
            f"status-only Stop must capture managed-overlay provenance: {status_only_metadata!r}",
        )

        print("PASS: codex-hook bridge updates metadata, notifications, status, and no-target safety")
        return 0

    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1
    finally:
        for extra_workspace_id in reversed(extra_workspace_ids):
            try:
                run_cli(cli_path, socket_path, ["close-workspace", "--workspace", extra_workspace_id])
            except Exception:
                pass
        if workspace_id:
            try:
                run_cli(cli_path, socket_path, ["close-workspace", "--workspace", workspace_id])
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
