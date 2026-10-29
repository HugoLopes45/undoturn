/// Native command-hook decisions for the explicitly supported protocols. No success path
/// auto-approves a tool: absence of a decision preserves the host's own approval policy.
public enum CommandProtectionProtocol {
  public static func supports(_ agent: Agent) -> Bool {
    switch agent {
    case .claude, .codex, .gemini, .cursor: true
    default: false
    }
  }

  public static func supportsAsk(_ agent: Agent) -> Bool {
    agent == .claude || agent == .cursor
  }

  public static func response(_ decision: CommandProtection.Decision, agent: Agent) -> JSONValue? {
    guard supports(agent) else { return nil }
    let permission: String
    let reason: String
    switch decision {
    case .proceed: return nil
    case .refuse(let message):
      permission = "deny"
      reason = message
    case .requestPermission(let message):
      permission = supportsAsk(agent) ? "ask" : "deny"
      reason =
        supportsAsk(agent)
        ? message
        : "UndoTurn: \(agent.rawValue)'s precommand hook does not support requesting native approval. "
          + "This destructive Git command is refused. Review and run it yourself outside the agent if intended. "
          + "Project checkpoints do not back up .git."
    }
    var output = JSONObject()
    switch agent {
    case .claude, .codex:
      var specific = JSONObject()
      specific["hookEventName"] = .string("PreToolUse")
      specific["permissionDecision"] = .string(permission)
      specific["permissionDecisionReason"] = .string(reason)
      output["hookSpecificOutput"] = .object(specific)
    case .cursor:
      output["permission"] = .string(permission)
      output["user_message"] = .string(reason)
      output["agent_message"] = .string(reason)
    case .gemini:
      output["decision"] = .string("deny")
      output["reason"] = .string(reason)
    default: return nil
    }
    return .object(output)
  }
}
