import Foundation

/// Wrap a path in single quotes for safe interpolation into a shell
/// command. `isValidClaudeSessionProjectDir` already rejects single
/// quotes; this helper still escapes them defensively so a bypass of the
/// validator (direct in-process writer, future regression) cannot become
/// a command-injection vector.
nonisolated func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Pure-value lookup table mapping a known terminal type + session hint to
/// the shell command that resumes it. Phase 1 ships a single row for
/// `claude-code`; rows for `codex`, `opencode`, `kimi` land in Phase 5
/// without schema changes.
///
/// The registry is **not Codable**. It flows through
/// `ApplyOptions.restartRegistry` as an in-process reference and is resolved
/// by name at the v2 handler boundary (`"phase1"` → `.phase1`). Keeping it
/// out of the wire format prevents snapshot files from locking in a specific
/// registry version — a snapshot written today stays restorable after Phase
/// 5 adds rows, because the registry is resolved app-side at restore time.
struct AgentRestartRegistry: Sendable {
    struct Row: Sendable {
        /// Canonical `terminal_type` string, matching the value written by
        /// `c11 set-agent --type <type>` and surfaced by the sidebar chip.
        let terminalType: String
        /// Pure resolver. Returns the command to run, or `nil` to decline
        /// (e.g., required session id missing). `metadata` is the full
        /// string-valued surface-metadata map; future rows may consult
        /// additional keys without schema changes.
        let resolve: @Sendable (_ sessionId: String?, _ metadata: [String: String]) -> String?

        init(
            terminalType: String,
            resolve: @escaping @Sendable (_ sessionId: String?, _ metadata: [String: String]) -> String?
        ) {
            self.terminalType = terminalType
            self.resolve = resolve
        }
    }

    /// Stable identity for `Equatable` comparisons. The registry carries
    /// closures (not `Equatable`); callers (the v2 handler, tests) identify
    /// a registry by the name it was minted with — `"phase1"` for the
    /// canonical singleton, test-chosen names for fixtures.
    let name: String
    private let rowsByType: [String: Row]

    init(name: String, rows: [Row]) {
        self.name = name
        var map: [String: Row] = [:]
        // Trim on insert to match the symmetric trim in `resolveCommand`;
        // avoids an asymmetric-trim footgun where a row registered with
        // surrounding whitespace is silently un-resolvable.
        for row in rows {
            let key = row.terminalType.trimmingCharacters(in: .whitespacesAndNewlines)
            map[key] = row
        }
        self.rowsByType = map
    }

    /// Consult the registry. Returns `nil` when the type is unknown or the
    /// matching row declines. Pure; never mutates.
    func resolveCommand(
        terminalType: String?,
        sessionId: String?,
        metadata: [String: String]
    ) -> String? {
        guard let type = terminalType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty,
              let row = rowsByType[type] else { return nil }
        return row.resolve(sessionId, metadata)
    }

    /// Names the executor handler accepts in `snapshot.restore` params.
    /// `"phase1"` → `.phase1`; unknown names resolve to `nil` so an
    /// unrecognised wire value silently falls back to Phase 0 behavior
    /// rather than erroring the restore.
    static func named(_ name: String?) -> AgentRestartRegistry? {
        switch name {
        case "phase1": return .phase1
        default: return nil
        }
    }

    /// Phase 1 ships claude resume. Phase 5 added codex / grok / opencode / kimi rows.
    ///
    /// The claude closure re-validates `sessionId` against the UUIDv4 grammar
    /// even though `SurfaceMetadataStore` already rejects non-UUID writes for
    /// the `claude.session_id` reserved key. The "never trust the metadata
    /// layer solely" belt-and-braces is deliberate: the synthesised string
    /// is interpolated into a shell command that runs on restore, and any
    /// future in-process writer that bypasses the store must not become a
    /// command-injection vector.
    ///
    /// The trailing `"\n"` is preserved in the row's output for
    /// compatibility with callers and snapshot consumers that may inspect
    /// the literal string. Submission no longer depends on it:
    /// `ghostty_surface_text` wraps every write in bracketed-paste markers
    /// (`ESC[200~ … ESC[201~`), and bracketed paste is specifically
    /// designed so embedded `\n`/`\r` do NOT auto-execute — shells and
    /// TUI raw-mode handlers only submit when a real Return arrives
    /// outside the paste sequence. Both the executor and the boot-time
    /// restart path route registry output through
    /// `TerminalSurface.sendSubmitFormText`, which trims the trailing
    /// newline, types the bytes via paste, and dispatches a synthetic
    /// Return key outside the paste so the receiving shell or TUI
    /// actually submits the line.
    ///
    /// Use `claude --dangerously-skip-permissions --resume <id>` rather than
    /// `cc`: `cc` resolves to the C compiler in c11 terminal environments,
    /// not Claude. The c11 wrapper at `Resources/bin/claude` intercepts the
    /// command, sees `--resume`, skips its own `--session-id` injection, and
    /// forwards to real claude with the hooks settings JSON intact.
    ///
    /// Codex uses captured `codex.session_id` metadata for deterministic
    /// `codex resume <id>` when available. The generic `sessionId` parameter is
    /// intentionally ignored for Codex so a stale `claude.session_id` cannot be
    /// consumed as a Codex id. Older snapshots without a captured Codex id still
    /// fall back to `codex resume --last`, but malformed captured ids and invalid
    /// store provenance fail closed rather than guessing with `--last` or the
    /// managed overlay. Like Claude, a malformed project_dir hint is dropped
    /// while the valid session id is still resumed.
    /// Grok supports `--resume` without an id to attach to the most recent
    /// session. Opencode and kimi have no verified resume flag and launch
    /// fresh — best-effort is preferable to a broken flag.
    static let phase1: AgentRestartRegistry = .init(name: "phase1", rows: [
        Row(terminalType: "claude-code") { sessionId, metadata in
            guard let raw = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  isValidClaudeSessionId(raw) else { return nil }
            let resume = "claude --dangerously-skip-permissions --resume \(raw)"
            // `claude --resume <id>` resolves the session JSONL relative to
            // the current shell's cwd encoding (`~/.claude/projects/<encoded-cwd>/<id>.jsonl`).
            // A session captured in a worktree subdir cannot be resumed
            // from its parent. When the hook recorded a project_dir, `cd`
            // there first — re-validating defensively in case a future
            // bypass slipped a malformed value past the store. The
            // single-quote escape is belt-and-braces: the validator
            // already rejects single quotes.
            if let raw = metadata[SurfaceMetadataKeyName.claudeSessionProjectDir]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty,
               isValidClaudeSessionProjectDir(raw) {
                return "cd \(shellSingleQuote(raw)) && \(resume)\n"
            }
            return "\(resume)\n"
        },
        Row(terminalType: SurfaceMetadataKeyName.terminalTypeCodex) { _, metadata in
            if metadata.keys.contains(SurfaceMetadataKeyName.codexRestartBlocked) {
                return nil
            }

            func recordedProjectDir() -> String? {
                guard let rawDir = metadata[SurfaceMetadataKeyName.codexSessionProjectDir]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawDir.isEmpty,
                      isValidCodexSessionProjectDir(rawDir) else {
                    return nil
                }
                return rawDir
            }

            let sessionStore: String
            if metadata.keys.contains(SurfaceMetadataKeyName.codexSessionStore) {
                guard let candidate = metadata[SurfaceMetadataKeyName.codexSessionStore]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      candidate == SurfaceMetadataKeyName.codexSessionStoreManagedOverlay ||
                        candidate == SurfaceMetadataKeyName.codexSessionStoreRealHome else {
                    return nil
                }
                sessionStore = candidate
            } else {
                sessionStore = SurfaceMetadataKeyName.codexSessionStoreManagedOverlay
            }

            let raw: String
            if metadata.keys.contains(SurfaceMetadataKeyName.codexSessionId) {
                guard let candidate = metadata[SurfaceMetadataKeyName.codexSessionId]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !candidate.isEmpty else {
                    return nil
                }
                raw = candidate
            } else {
                // Older snapshots or disabled hooks retain the historical
                // best-effort behavior. `resume --last` must read the
                // operator's real Codex state; c11's managed CODEX_HOME
                // overlay intentionally does not mirror sessions/state DBs.
                // The wrapper also detects this argv shape for manual runs,
                // but the env marker keeps restored legacy snapshots explicit.
                let resumeLast = "env CMUX_CODEX_LEGACY_RESUME_LAST=1 codex resume --last"
                if let rawDir = recordedProjectDir() {
                    return "cd \(shellSingleQuote(rawDir)) 2>/dev/null || true; \(resumeLast)\n"
                }
                return "\(resumeLast)\n"
            }
            guard isValidCodexSessionId(raw) else { return nil }
            let resume: String
            if sessionStore == SurfaceMetadataKeyName.codexSessionStoreRealHome {
                resume = "env CMUX_CODEX_REAL_HOME_RESUME=1 codex resume \(raw)"
            } else {
                resume = "env CMUX_CODEX_MANAGED_RESUME=1 codex resume \(raw)"
            }
            if let rawDir = recordedProjectDir() {
                return "cd \(shellSingleQuote(rawDir)) 2>/dev/null || true; \(resume)\n"
            }
            return "\(resume)\n"
        },
        Row(terminalType: "grok") { _, _ in
            // grok --resume (no id) attaches to the most recent session.
            // Best-effort: may not match the exact session in the snapshot.
            "grok --always-approve --resume\n"
        },
        Row(terminalType: "opencode") { _, _ in
            // no stable resume flag known; launches fresh.
            "opencode run --dangerously-skip-permissions\n"
        },
        Row(terminalType: "kimi") { _, _ in
            // no stable resume flag known; launches fresh.
            "kimi\n"
        }
    ])
}
