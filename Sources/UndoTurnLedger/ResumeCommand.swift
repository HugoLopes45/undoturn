import UndoTurnCore

/// A shell command that reopens the harness session of a hook turn in its project folder, or
/// nil when the turn has no session ID or its harness can not resume one by ID.
///
/// Each syntax is the one the harness's own `--help` documents for resuming by session ID.
public func resumeCommand(for conversation: Conversation, root: String) -> String? {
  guard let harness = Harness(rawValue: conversation.agent),
    let sessionID = conversation.sessionID,
    let command = harness.resumeCommandPrefix
  else { return nil }
  return "cd \(shellQuoted(root)) && \(command)\(shellQuoted(sessionID))"
}

extension Harness {
  fileprivate var resumeCommandPrefix: String? {
    switch self {
    case .claude: "claude --resume "
    case .codex: "codex resume "
    case .cursor: "cursor-agent --resume "
    case .copilot: "copilot --resume="
    case .droid: "droid --resume "
    case .opencode: "opencode --session "
    case .pi: "pi --session "
    case .omp: "omp --resume="
    // Gemini CLI resumes by list index; Devin CLI documents no resume by ID.
    case .gemini, .devin: nil
    }
  }
}

private func shellQuoted(_ value: String) -> String {
  var quoted = "'"
  // Per scalar: an apostrophe that a joiner or combining mark follows still ends a shell quote.
  for scalar in value.unicodeScalars {
    if scalar == "'" {
      quoted += #"'\''"#
    } else {
      quoted.unicodeScalars.append(scalar)
    }
  }
  return quoted + "'"
}
