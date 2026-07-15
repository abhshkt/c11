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
    /// `codex resume <id>` when available, and falls back to `--last` only
    /// when no trusted id exists. Grok/Pi have best-effort recent-session
    /// commands; Opencode/OMP exact resume flows through conversation
    /// strategies, with this registry remaining the legacy fallback path.
    static let phase1: AgentRestartRegistry = {
        // Rows are generated from the agent registry: every manifest that
        // declares a resume spec contributes a row whose resolver is the
        // manifest's `resumeCommand`. Manifests with `ResumeSpec.none`
        // (github-copilot, custom) contribute no row and fall through to a
        // fresh launch. Belt-and-braces id/path re-validation lives in
        // `AgentManifest.resumeCommand`.
        let rows = AgentRegistry.shared.all.compactMap { manifest -> Row? in
            if case .none = manifest.resume { return nil }
            return Row(terminalType: manifest.kind) { sessionId, metadata in
                manifest.resumeCommand(sessionId: sessionId, metadata: metadata)
            }
        }
        return .init(name: "phase1", rows: rows)
    }()
}
