# Notifications

c11 provides a notification panel for agents like Claude Code, Codex, and OpenCode. Notifications appear in the in-app notification surface and can also trigger macOS system notifications.

## Quick Start

```bash
# Send a notification (if c11 is available)
command -v c11 &>/dev/null && c11 notify --title "Done" --body "Task complete"

# With fallback to macOS notifications
command -v c11 &>/dev/null && c11 notify --title "Done" --body "Task complete" || osascript -e 'display notification "Task complete" with title "Done"'
```

## Detection

Check if the `c11` CLI is available before using it:

```bash
# Shell
if command -v c11 &>/dev/null; then
    c11 notify --title "Hello"
fi

# One-liner with fallback
command -v c11 &>/dev/null && c11 notify --title "Hello" || osascript -e 'display notification "" with title "Hello"'
```

```python
# Python
import shutil
import subprocess

def notify(title: str, body: str = ""):
    if shutil.which("c11"):
        subprocess.run(["c11", "notify", "--title", title, "--body", body])
    else:
        # Fallback to macOS
        subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}"'])
```

## CLI Usage

```bash
# Simple notification
c11 notify --title "Build Complete"

# With subtitle and body
c11 notify --title "Claude Code" --subtitle "Permission" --body "Approval needed"

# Notify a specific workspace/surface
c11 notify --title "Done" --workspace 0 --surface 1
```

## Integration Examples

### Claude Code Hooks

Claude Code is integrated through c11's PATH-scoped `Resources/bin/claude` wrapper. Inside a live c11 terminal, the wrapper injects c11-owned hook settings without requiring persistent edits to `~/.claude/settings.json`.

### OpenAI Codex

Codex is integrated through c11's PATH-scoped `Resources/bin/codex` wrapper. Inside a live c11 terminal, the wrapper:

- marks the surface as `terminal_type=codex`
- records Codex `model` metadata when a trusted payload supplies a valid model id such as `gpt-5.5`
- injects a per-invocation Codex `notify` command that targets the current c11 workspace/surface
- writes a c11-owned `--profile-v2 c11` hook layer under c11 Application Support and launches interactive Codex sessions with that profile
- records wrapper start/resume/project-dir hints so `c11 codex-hook notify` can capture an unambiguous `codex.session_id` from trusted hook payloads, explicit `codex resume <id>`, or the local Codex state DB
- clears stale notifications and marks Codex `Running` when the c11-launched invocation includes an initial command-line prompt
- passes the pane's effective project directory to Codex with `--cd` when needed, and honors an explicit `--cd` / `-C` when the operator supplied one
- never writes to `~/.codex/config.toml`, project `.codex` files, shell rc files, or other tenant-owned persistent state

Codex lifecycle hooks are discovered from real Codex config layers such as `$CODEX_HOME/config.toml`, `--profile-v2 <name>`, or `<repo>/.codex/config.toml`. The c11 wrapper deliberately does not use `-c hooks.*=...`, because current Codex releases parse those runtime overrides but do not treat them as executable hook sources. Instead, the wrapper creates an overlay Codex home at `~/Library/Application Support/c11/codex-home/<hash>/`, refreshes copied `config.toml` and `auth.json` regular files, seeds a missing local plugin cache into the overlay, writes `c11.config.toml`, exports `CODEX_HOME` only for the launched Codex process, and adds `--profile-v2 c11`. This keeps the hook source and Codex's hook-trust writes in a real Codex config layer while leaving tenant-owned Codex files untouched.

The generated c11 profile contains these bridge commands:

```toml
[features]
hooks = true

[[hooks.SessionStart]]
matcher = "startup|resume|clear"
[[hooks.SessionStart.hooks]]
type = "command"
command = "command -v c11 >/dev/null && c11 codex-hook session-start || true"

[[hooks.PermissionRequest]]
matcher = "*"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = "command -v c11 >/dev/null && c11 codex-hook permission-request || true"
```

Official Codex docs make the trust boundary explicit: non-managed command hooks require review and trust before they run. c11 does not use `--dangerously-bypass-hook-trust`, because that flag would trust every enabled non-managed hook source for the invocation, not only c11's bridge commands. On first use, Codex may show its hook-review UI; after the operator trusts the c11 commands, `SessionStart` provides high-confidence lifecycle metadata and `PermissionRequest` marks the workspace as needing input. c11 deliberately does not install default `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, or `Stop` hooks, because Codex renders hook execution inline in the terminal and those events fire on every normal turn/tool cycle. Before hook trust is accepted, completion notifications still flow through the wrapper's injected `notify` path, and that same notify bridge owns normal completion/idle updates after trust as well. When a notification arrives without a payload session id, c11 only writes `codex.session_id` if the local Codex state DB yields exactly one fresh session after first preferring the launch cwd and then falling back to the global Codex thread set. The global fallback waits briefly so a same-pane cwd row can appear before c11 accepts a weaker one-candidate global match. Ambiguous candidates intentionally keep the older `codex resume --last` fallback instead of guessing. When a valid `codex.session_id` exists but the project-dir hint is missing or malformed, restore still uses `codex resume <id>`; Codex's explicit UUID argument is the session identity, while the project dir only restores the original cwd before launching.

`c11 codex-hook prompt-submit`, `pre-tool-use`, `post-tool-use`, and `stop` remain supported for custom launch paths, but they are opt-in. Use plain `c11 codex-hook stop` only for a custom Codex launch path that does not also use the wrapper's notification bridge.

### OpenCode Plugin

Create `.opencode/plugins/c11-notify.js`:

```javascript
export const C11NotificationPlugin = async ({ $, }) => {
  const notify = async (title, body) => {
    try {
      await $`command -v c11 && c11 notify --title ${title} --body ${body}`;
    } catch {
      await $`osascript -e ${"display notification \"" + body + "\" with title \"" + title + "\""}`;
    }
  };

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await notify("OpenCode", "Session idle");
      }
    },
  };
};
```

## Environment Variables

c11 sets these in child shells:

| Variable | Description |
|----------|-------------|
| `CMUX_SOCKET_PATH` | Path to control socket |
| `CMUX_WORKSPACE_ID` | UUID of the current workspace |
| `CMUX_SURFACE_ID` | UUID of the current surface |

## CLI Commands

```
c11 notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|index>] [--surface <id|index>]
c11 list-notifications
c11 clear-notifications
c11 ping
```

## Best Practices

1. **Always check availability first** - Use `command -v c11` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
