# C11-131: Crash-resume fix + explicit state save/verify/restart CLI + end-to-end resume validation harness

Ships the full plan in docs/c11-state-save-load-and-crash-resume.md (the spec for this ticket — read it first).

WHAT: After a c11 crash, panes/positions restore but Claude sessions never resume. Root cause (diagnosed 2026-06-09): on a dirty ShutdownSentinel, AppDelegate calls ConversationStore.markAllUnknown() and the designed "forced pull-scrape" reclassification pass was never implemented (ConversationStrategyInputs has zero production callers; ClaudeCodeScraper also targets ~/.claude/sessions/, the wrong directory — real transcripts live at ~/.claude/projects/<cwd-slug>/<id>.jsonl). ClaudeCodeStrategy.resume() skips state=unknown, so crash recovery — the case resume exists for — always skips.

WORK AREAS (one deliverable, sections ordered; 2 before 4):
1. Crash-resume fix: replace markAllUnknown with reclassifyAfterCrash — for each seeded ref with state alive/suspended, stat the transcript file; exists → .suspended ("crash recovery: transcript verified on disk"), missing → .unknown. Refs already unknown/tombstoned untouched (preserves /exit-no-resume contract). Per-kind verification through the strategy seam; fix or delete the dead scraper. Privacy contract: stat only, never open transcript bytes.
2. `c11 state save [--out] [--scrollback]` (new socket verb session.save; production cousin of DEBUG-only debug.session.save_and_load) + `c11 state verify [<path>]` (read-only per-panel resume-decision report; exit 0 iff all refs would resume).
3. `c11 app restart [--no-resume]`: clean-shutdown choreography (suspendAllAlive → snapshot → promoteToClean) then relaunch + restore + resume. The "c11 is laggy" command.
4. Tests: Tier 1 logic tests (c11LogicTests: sentinel, store transitions, strategy matrix, snapshot round-trip, injectable-filesystem verify pass). Tier 2 tests_v2 python harness: tagged build + fake `claude` PATH shim (records argv, does real `c11 conversation push`, blocks like a TUI) + fake transcripts; scenario matrix per spec §3 (clean restart, crash+transcript, crash-missing-transcript, /exit, double crash, kill switch, non-claude panel). Decisive oracle = shim argv log containing --resume <id>, never screen-scraping.

ACCEPTANCE: the "crash, transcript present" scenario — red on today's HEAD — passes: kill -9 a tagged c11 with live (shimmed) claude sessions, relaunch, every panel re-invokes claude with --resume <expected-id>, topology intact. Plus a real-Claude manual smoke on the tagged build with screenshot evidence attached as validation.

CONTEXT: Sources/Conversation/* (Store, Strategy, Strategies/ClaudeCode, ShutdownSentinel, SnapshotBridge), AppDelegate.swift launch/terminate choreography (~2383-2435, 2888-2939, 3050-3085), Workspace.swift pendingRestartPlans (~430-545), TerminalController.swift v2 verb dispatch. Honor socket threading + focus policies, dlog DEBUG-gating, test-quality policy (runtime behavior, not source-grep). New CLI verbs must be documented in skills/c11/SKILL.md + synced via scripts/sync-installed-skills.sh.

OPERATOR EXPERIENCE WHEN DONE: c11 crashes → relaunch brings back every workspace AND every Claude conversation resumed in place. `c11 state save` checkpoints on demand; `c11 state verify` explains per-pane resume decisions; `c11 app restart` is the one-command fix for a laggy instance.

CI e2e wiring (test-e2e.yml job for the Tier 2 scenarios) is in scope if straightforward; if it turns into a yak-shave, file a follow-up ticket instead and say so in the review.
