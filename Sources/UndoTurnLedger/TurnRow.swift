import UndoTurnCore

public enum TurnState: Equatable, Sendable {
  case head
  case applied
  case undone
}

public struct TurnRow: Equatable, Sendable, Identifiable {
  public let id: NodeID
  public let number: String
  public let prompt: String
  public let agent: String
  public let harness: Harness?
  /// The harness name, `undoturn run` for other commands, or the recorded agent name.
  public let agentName: String
  public let label: String?
  public let time: Int64
  public let counts: ChangeCounts
  public let state: TurnState
  public let kind: NodeRecord.Kind
  /// Observed identities in the interval, not authorship of individual file changes.
  public let participants: [RecordingParticipant]

  init(node: NodeRecord, state: TurnState, label: String?) {
    self.id = node.id
    self.number = "#\(node.id.rawValue)"
    switch node.kind {
    case .betweenTurns: self.prompt = "Changes between turns"
    case .checkpoint: self.prompt = "Checkpoint: \(ledgerPrompt(node.conversation.displayPrompt))"
    case .turn:
      self.prompt = ledgerRecordingPrompt(
        node.conversation.displayPrompt, participants: node.participants)
    }
    self.agent = node.conversation.agent
    self.harness =
      node.kind == .turn && node.participants.count < 2
      ? Harness(agent: agent, command: node.conversation.prompt) : nil
    switch node.kind {
    case .betweenTurns: self.agentName = "Between turns"
    case .checkpoint: self.agentName = "Checkpoint"
    case .turn:
      self.agentName =
        node.participants.count > 1
        ? "Shared recording" : ledgerAgentName(agent, harness: harness)
    }
    self.label = label
    self.time = node.time
    self.counts = ChangeCounts(node)
    self.state = state
    self.kind = node.kind
    self.participants = node.participants
  }
}

public struct RunningTurn: Equatable, Sendable {
  public let time: Int64
  public let prompt: String
  public let agent: String
  public let harness: Harness?
  public let agentName: String
  /// The newest file or shell step of the turn.
  public let step: RunningDetail?
  /// The agent's question while it waits for the person.
  public let question: RunningDetail?
  public let participants: [RecordingParticipant]

  init(
    time: Int64, prompt: String?, agent: String, live: LiveTurn?, root: String,
    participants: [RecordingParticipant]
  ) {
    self.time = time
    self.prompt = ledgerRecordingPrompt(prompt, participants: participants)
    self.agent = agent
    self.harness = participants.count < 2 ? Harness(agent: agent, command: prompt) : nil
    self.agentName =
      participants.count > 1 ? "Shared recording" : ledgerAgentName(agent, harness: harness)
    self.participants = participants
    self.step = live?.tool.map { RunningDetail(text: $0.action.summary(root: root), time: $0.time) }
    self.question = live?.attention.map {
      RunningDetail(text: displayLine($0.message) ?? "", time: $0.time)
    }
  }
}

public struct RunningDetail: Equatable, Sendable {
  public let text: String
  public let time: Int64
}

func ledgerTurnStates(in state: HistoryState) -> [NodeID: TurnState] {
  var result = Dictionary(uniqueKeysWithValues: state.nodes.keys.map { ($0, TurnState.undone) })
  var current = state.tree.head
  guard current != state.tree.root else { return result }
  result[current] = .head

  while let parent = state.tree.parent(of: current), parent != state.tree.root {
    result[parent] = .applied
    current = parent
  }
  return result
}

func ledgerAgentName(_ agent: String, harness: Harness?) -> String {
  harness?.name ?? (agent == "run" ? "undoturn run" : agent)
}

func ledgerPrompt(_ prompt: String?) -> String {
  prompt.flatMap(displayLine) ?? "Turn without a prompt"
}

private func ledgerRecordingPrompt(_ prompt: String?, participants: [RecordingParticipant])
  -> String
{
  participants.count > 1
    ? "Shared recording · \(participants.count) participants" : ledgerPrompt(prompt)
}
