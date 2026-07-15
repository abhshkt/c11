import Foundation

/// Best-effort resume strategy for Grok Build. Grok exposes `grok --resume`
/// (no id) to attach to the most recent session globally, but ships no
/// SessionStart hook and no verified per-session transcript path c11 can
/// scrape. So capture is fresh-launch-only — it acts on a hook/manual push
/// or a wrapper-claim placeholder, same shape as Kimi/Opencode in v1.
///
/// When a non-placeholder ref does exist (alive/suspended), `resume()` types
/// the best-effort `grok --always-approve --resume`, mirroring the
/// `AgentRestartRegistry.phase1` fallback row. The command carries no
/// interpolated id, so there is no untrusted-input surface to shell-quote.
struct GrokStrategy: ConversationStrategy {
    let kind: String = "grok"

    init() {}

    func capture(inputs: ConversationStrategyInputs) -> ConversationRef? {
        if let push = inputs.push, !push.placeholder {
            return push
        }
        return inputs.wrapperClaim
    }

    func resume(ref: ConversationRef) -> ResumeAction {
        if ref.placeholder {
            return .skip(reason: "fresh-launch-only")
        }
        switch ref.state {
        case .alive, .suspended:
            // grok --resume (no id) attaches to the most recent session.
            // Best-effort: may not match the exact session in the snapshot.
            return .typeCommand(text: "grok --always-approve --resume", submitWithReturn: true)
        default:
            return .skip(reason: "state=\(ref.state.rawValue) not auto-resumable")
        }
    }
}
