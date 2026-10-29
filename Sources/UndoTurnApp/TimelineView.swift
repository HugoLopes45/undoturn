import AppKit
import SwiftUI
import UndoTurnCore
import UndoTurnLedger

struct TimelineView: View {
  let store: LedgerStore
  let agentSetup: AgentSetupController
  @Bindable var selection: TimelineSelection

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var controlActiveState
  @FocusState private var turnListFocused: Bool
  @FocusState private var labelFieldFocused: Bool
  @State private var headTravel = HeadTravel()
  @State private var moveFeedback: TimelineMoveFeedback?
  @State private var recoveryRequest: RecoveryRequest?
  @State private var listItemsOnScreen: Set<ListItemOnScreen> = []
  @State private var columnVisibility = NavigationSplitViewVisibility.all

  private var project: ProjectLedger? {
    guard let root = selection.root else { return store.projects.first }
    return store.project(root: root)
  }

  private var state: HistoryState? {
    project.flatMap { store.state(root: $0.root) }
  }

  private var hasPendingTurn: Bool {
    state?.pendingTurn != nil
  }

  private var isMoving: Bool {
    project.map { store.moving.contains($0.root) } ?? false
  }

  private var currentTime: Int64 {
    Int64(Date().timeIntervalSince1970)
  }

  private var windowTitle: String {
    guard let project else { return selection.root.map { projectName($0) } ?? "UndoTurn" }
    return displayName(project)
  }

  private var selectedTurnID: NodeID? {
    guard selection.runningSelected == false, let state else { return nil }
    guard let turn = selection.selectedTurn ?? Timeline.defaultTurn(in: state),
      state.nodes[turn] != nil
    else { return nil }
    return turn
  }

  private var listSelection: Binding<TimelineItemID?> {
    Binding(
      get: {
        if selection.runningSelected, state?.pendingTurn != nil { return .running }
        guard let selectedTurnID else { return nil }
        return .turn(selectedTurnID)
      },
      set: { item in
        switch item {
        case .running:
          selection.selectedTurn = nil
          selection.runningSelected = true
        case .turn(let id):
          selection.selectedTurn = id
          selection.runningSelected = false
        case nil:
          selection.selectedTurn = nil
          selection.runningSelected = false
        }
      }
    )
  }

  private var projectSelection: Binding<String?> {
    Binding(
      get: { selection.root ?? store.projects.first?.root },
      set: { root in
        guard let root, root != selection.root, store.project(root: root) != nil else { return }
        selection.root = root
        selection.selectedTurn = nil
        selection.runningSelected = false
        moveFeedback = nil
      }
    )
  }

  private func displayName(_ project: ProjectLedger) -> String {
    let duplicates = store.projects.filter { $0.name == project.name }
    guard duplicates.count > 1 else { return project.name }
    let parent = URL(fileURLWithPath: project.root).deletingLastPathComponent().lastPathComponent
    return "\(parent)/\(project.name)"
  }

  var body: some View {
    let history = project.flatMap { store.state(root: $0.root) }
    let rows = history.map(Timeline.rows) ?? []
    let now = currentTime

    Group {
      if store.projects.isEmpty, selection.root.map({ store.project(root: $0) == nil }) ?? true {
        VStack(spacing: 0) {
          loadErrorBanner
          HookFailureBanner(failures: store.hookFailures)
          noProjects
        }
      } else {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          projectSidebar
            .navigationSplitViewColumnWidth(min: 180, ideal: 212, max: 300)
        } content: {
          VStack(spacing: 0) {
            loadErrorBanner
            HookFailureBanner(failures: store.hookFailures)
            if let unavailableRoot = selection.root, store.project(root: unavailableRoot) == nil {
              projectUnavailable(root: unavailableRoot)
            } else {
              turnListPane(state: history, rows: rows, now: now)
            }
          }
          .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
          // Turn numbers repeat across projects, so a project switch must replace the rows,
          // not animate them.
          .id(project?.root ?? selection.root ?? "")
          .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
        } detail: {
          detailPane(state: history, rows: rows)
            .id(project?.root ?? selection.root ?? "")
        }
        // AppKit makes the list the first responder when the window opens; tell SwiftUI too,
        // so the selected row draws its emphasized colors.
        .defaultFocus($turnListFocused, true)
      }
    }
    .overlay(alignment: .bottom) {
      feedbackToast
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: moveFeedback?.id)
    }
    .toolbar {
      moveToolbar
    }
    .modifier(
      SelectiveRecoveryPresenter(
        store: store, request: $recoveryRequest, onSuccess: recoverySucceeded,
        onFailure: { message in showFeedback(.failed(message)) })
    )
    .navigationTitle(windowTitle)
    .onAppear { consumeNotificationFeedback() }
    .onChange(of: store.notificationFeedback) { _, _ in
      consumeNotificationFeedback()
    }
    .onChange(of: project?.root) { _, newRoot in
      if selection.root == nil {
        selection.root = newRoot
        selection.selectedTurn = nil
        selection.runningSelected = false
      }
    }
    .onChange(of: hasPendingTurn) { _, isPending in
      guard isPending == false, selection.runningSelected else { return }
      selection.runningSelected = false
      if let head = project?.head, head.rawValue > 0 {
        selection.selectedTurn = head
      } else {
        selection.selectedTurn = nil
      }
    }
  }

  private var projectSidebar: some View {
    List(selection: projectSelection) {
      Section("Projects") {
        if let root = selection.root, store.project(root: root) == nil {
          Label(projectName(root), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .tag(root)
        }
        ForEach(store.projects) { project in
          SidebarProjectRow(
            name: displayName(project),
            root: project.root,
            lastActivity: project.lastActivity,
            running: project.running
          )
          .tag(project.root)
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if store.paused {
        VStack(alignment: .leading, spacing: 6) {
          Label("Recording paused", systemImage: "pause.circle")
            .font(.callout.weight(.medium))
          Text("New agent turns are not recorded.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Resume Recording", action: resumeRecording)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
    }
  }

  @ToolbarContentBuilder
  private var moveToolbar: some ToolbarContent {
    if store.projects.isEmpty == false, project != nil {
      ToolbarItemGroup(placement: .primaryAction) {
        if isMoving {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Move in progress")
        }

        Button {
          guard let preview = project?.undo else { return }
          requestMove(.undo(preview.turn), action: "Undo #\(preview.turn.rawValue)")
        } label: {
          Label {
            Text(project?.undo.map { "Undo #\($0.turn.rawValue)" } ?? "Undo")
              .monospacedDigit()
          } icon: {
            Image(systemName: "arrow.uturn.backward")
          }
        }
        .help(
          project?.undo.map { "\($0.summary) Shortcut: ⌘Z." }
            ?? "Nothing to undo. Shortcut: ⌘Z."
        )
        .disabled(project?.undo == nil || isMoving)
        .keyboardShortcut(
          labelFieldFocused ? nil : KeyboardShortcut("z", modifiers: .command))

        Button {
          guard let preview = project?.redo else { return }
          requestMove(.redo(preview.turn), action: "Redo #\(preview.turn.rawValue)")
        } label: {
          Label {
            Text(project?.redo.map { "Redo #\($0.turn.rawValue)" } ?? "Redo")
              .monospacedDigit()
          } icon: {
            Image(systemName: "arrow.uturn.forward")
          }
        }
        .help(redoHelp)
        .disabled(project?.redo == nil || project?.running != nil || isMoving)
        .keyboardShortcut(
          labelFieldFocused
            ? nil
            : KeyboardShortcut("z", modifiers: [.command, .shift]))
      }
    }
  }

  private var redoHelp: String {
    guard let redo = project?.redo else { return "Nothing to redo. Shortcut: ⇧⌘Z." }
    guard project?.running == nil else { return activeRecordingRecoveryMessage }
    return "\(redo.summary) Shortcut: ⇧⌘Z."
  }

  @ViewBuilder
  private var loadErrorBanner: some View {
    if store.loadErrors.isEmpty == false {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(store.loadErrors.indices, id: \.self) { index in
          let message = store.loadErrors[index]
          Label {
            Text(message)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(StatusColor.error)
          }
          .lineLimit(3)
          .textSelection(.enabled)
          .help(message)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      Divider()
    }
  }

  private var noProjects: some View {
    ContentUnavailableView {
      Label {
        Text("No Recorded Projects")
      } icon: {
        LedgerMark(paused: false)
      }
    } description: {
      Text(
        "UndoTurn saves local history when supported agent hooks run. "
          + "Choose a project to configure recording, then start a new agent session."
      )
    } actions: {
      Button(agentSetup.operation ?? "Install Agent Hooks…") {
        agentSetup.perform(.install)
      }
      .buttonStyle(.borderedProminent)
      .disabled(agentSetup.isBusy)
      .help("Choose a project and configure recording with the bundled command-line tool.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func projectUnavailable(root: String) -> some View {
    ContentUnavailableView(
      "\(projectName(root)) Is Not Available",
      systemImage: "exclamationmark.triangle",
      description: Text("Choose another project in the sidebar.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func resumeRecording() {
    Task { @MainActor in
      guard let message = await store.setPaused(false) else { return }
      showFeedback(.failed(message))
    }
  }

  private func projectHeader(_ project: ProjectLedger) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(displayName(project))
        .font(.title2.weight(.semibold))
        .lineLimit(1)
      Text((project.root as NSString).abbreviatingWithTildeInPath)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(project.root)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 18)
    .padding(.top, 6)
    .padding(.bottom, 8)
  }

  @ViewBuilder
  private func turnListPane(state: HistoryState?, rows: [TimelineRow], now: Int64) -> some View {
    if let project {
      projectHeader(project)
    }
    if let state {
      if rows.isEmpty && state.pendingTurn == nil {
        noTurns
      } else {
        let railWidth = laneRailWidth(rows: rows)
        let headArrivesFrom = headTravel.arrivalEdge(head: state.tree.head, rows: rows)
        let emphasizedItem =
          turnListFocused && controlActiveState == .key
          ? listSelection.wrappedValue : nil
        let listRoot = project?.root ?? ""
        let topItem =
          state.pendingTurn != nil && project?.running != nil
          ? TimelineItemID.running : rows.first.map { .turn($0.id) }
        ScrollViewReader { scroller in
          List(selection: listSelection) {
            if state.pendingTurn != nil, let running = project?.running {
              TimelineRunningRowView(
                turn: running,
                railWidth: railWidth,
                hasRecordedHead: state.tree.head != state.tree.root,
                emphasized: emphasizedItem == .running
              )
              .tag(TimelineItemID.running)
              .id(TimelineItemID.running)
              .onAppear {
                listItemsOnScreen.insert(ListItemOnScreen(root: listRoot, item: .running))
              }
              .onDisappear {
                listItemsOnScreen.remove(ListItemOnScreen(root: listRoot, item: .running))
              }
              .listRowSeparator(.hidden)
              .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 10))
              .accessibilityElement(children: .combine)
              .accessibilityLabel(
                "Running turn, \(running.prompt), started "
                  + "\(RelativeAge.spoken(from: running.time, now: now))"
              )
            }
            ForEach(rows) { row in
              TimelineTurnRowView(
                row: row,
                isHead: row.turn.state == .head,
                railWidth: railWidth,
                headArrivesFrom: headArrivesFrom,
                emphasized: emphasizedItem == .turn(row.id)
              )
              .tag(TimelineItemID.turn(row.id))
              .id(TimelineItemID.turn(row.id))
              .onAppear {
                listItemsOnScreen.insert(ListItemOnScreen(root: listRoot, item: .turn(row.id)))
              }
              .onDisappear {
                listItemsOnScreen.remove(ListItemOnScreen(root: listRoot, item: .turn(row.id)))
              }
              .listRowSeparator(.hidden)
              .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 10))
              .accessibilityElement(children: .combine)
              .accessibilityLabel(
                "Turn \(row.turn.id.rawValue), \(row.turn.prompt)"
                  + (row.turn.label.map { ", label \($0)" } ?? "")
              )
              .accessibilityValue(
                "\(spokenState(row.turn.state))"
                  + (row.lane > 0 ? ", side branch" : "")
                  + ", \(row.turn.agentName)"
                  + ", \(row.turn.counts.spokenDescription), "
                  + "\(RelativeAge.spoken(from: row.turn.time, now: now))"
              )
            }
          }
          .listStyle(.inset)
          .scrollContentBackground(.hidden)
          .focused($turnListFocused)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: state.tree.head)
          // List keeps its first visible row in place when rows arrive above it, which hides
          // a new turn under the header. Follow the newest item while the previous one shows.
          .onChange(of: topItem) { previous, newest in
            guard let previous, let newest,
              listItemsOnScreen.contains(ListItemOnScreen(root: listRoot, item: previous))
            else { return }
            scroller.scrollTo(newest, anchor: .top)
          }
        }
      }
    } else {
      noTurns
    }
  }

  @ViewBuilder
  private var noTurns: some View {
    if store.paused {
      ContentUnavailableView {
        Label {
          Text("Recording Paused")
        } icon: {
          LedgerMark(paused: true)
        }
      } description: {
        Text("UndoTurn does not record turns while recording is paused.")
      } actions: {
        Button("Resume Recording", action: resumeRecording)
      }
    } else {
      ContentUnavailableView {
        Label {
          Text("No Turns Yet")
        } icon: {
          LedgerMark(paused: false)
        }
      } description: {
        Text(
          "Turns show here when your agent finishes a turn in this project. "
            + "If you use Codex CLI, run /hooks in Codex once to trust the UndoTurn hook."
        )
      }
    }
  }

  private func laneRailWidth(rows: [TimelineRow]) -> CGFloat {
    let highestLane = rows.flatMap(\.activeLanes).max() ?? 0
    return CGFloat(highestLane) * 10 + 14
  }

  @ViewBuilder
  private func detailPane(state: HistoryState?, rows: [TimelineRow]) -> some View {
    Group {
      if let state, let turnID = selectedTurnID,
        let row = rows.first(where: { $0.id == turnID }),
        let node = state.nodes[turnID],
        let root = project?.root
      {
        TurnDetailView(
          store: store,
          root: root,
          state: state,
          row: row.turn,
          lane: row.lane,
          node: node,
          isMoving: isMoving,
          turnRunning: project?.running != nil,
          labelFieldFocused: $labelFieldFocused,
          onRestore: { move, action in requestMove(move, action: action) },
          onRestoreFile: { file in
            restoreFile(file, turn: turnID, root: root, after: false)
          },
          onRecover: { recovery in
            recoveryRequest = RecoveryRequest(recovery: recovery, root: root)
          },
          onLabelError: { message in showFeedback(.failed(message)) }
        )
        .id("\(root):\(turnID.rawValue)")
      } else if selection.runningSelected, let running = project?.running {
        runningDetail(running)
      } else {
        ContentUnavailableView(
          "No Turn Selected",
          systemImage: "arrow.left",
          description: Text("Select a turn to see its prompt, files and diffs.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    .navigationSplitViewColumnWidth(min: 460, ideal: 720)
  }

  private func runningDetail(_ running: RunningTurn) -> some View {
    ScrollView {
      runningSummary(running)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  private func runningSummary(_ running: RunningTurn) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 6) {
        HarnessMarkView(harness: running.harness, size: 13)
        SwiftUI.TimelineView(.everyMinute) { context in
          Text(
            "\(running.agentName) · started "
              + "\(RelativeAge.spoken(from: running.time, now: Int64(context.date.timeIntervalSince1970)))"
          )
        }
      }
      .font(.callout)
      .monospacedDigit()
      .foregroundStyle(.secondary)
      Text(running.prompt)
        .font(.title2.weight(.semibold))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      TurnParticipantsView(participants: running.participants)
      if running.question != nil || running.step != nil {
        RunningLiveView(turn: running)
      }
      Text(
        "UndoTurn records the shared interval when all active participants stop. "
          + "Files are not attributed per session."
      )
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var feedbackToast: some View {
    if let moveFeedback {
      FeedbackToast(
        feedback: moveFeedback,
        followUp: followUp(for: moveFeedback),
        onDismiss: { self.moveFeedback = nil }
      )
      .id(moveFeedback.id)
      .padding(.horizontal, 24)
      .padding(.bottom, 18)
      .transition(
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
      )
      .task(id: moveFeedback.id) {
        // A result that needs reading stays until dismissed.
        guard moveFeedback.staysOpen == false else { return }
        try? await Task.sleep(for: .seconds(8))
        guard Task.isCancelled == false, self.moveFeedback?.id == moveFeedback.id else { return }
        self.moveFeedback = nil
      }
    }
  }

  /// An after-version restore is conflict-checked; it is not a guaranteed reversal.
  private func followUp(for feedback: TimelineMoveFeedback) -> FeedbackToast.FollowUp? {
    guard case .moved(_, _, _, let reversal) = feedback.kind, let reversal,
      let project, isMoving == false
    else { return nil }
    switch reversal {
    case .redo(let turn, let root):
      // Turn numbers repeat across projects; a late result must not redo in another one.
      guard root == project.root, project.redo?.turn == turn, project.running == nil else {
        return nil
      }
      return FeedbackToast.FollowUp(title: "Redo") {
        requestMove(.redo(turn), action: "Redo #\(turn.rawValue)")
      }
    case .putBack(let file, let turn, let root):
      guard root == project.root, project.running == nil else { return nil }
      return FeedbackToast.FollowUp(title: "Restore After Version…") {
        restoreFile(file, turn: turn, root: root, after: true)
      }
    }
  }

  private func showFeedback(_ feedback: TimelineMoveFeedback) {
    moveFeedback = feedback
    AccessibilityNotification.Announcement(feedback.announcement).post()
  }

  private func spokenState(_ state: TurnState) -> String {
    switch state {
    case .head: "current turn"
    case .applied: "applied"
    case .undone: "undone"
    }
  }

  private func requestMove(_ move: Move, action: String) {
    guard let project, store.moving.contains(project.root) == false else { return }
    if project.running != nil {
      showFeedback(.failed(activeRecordingRecoveryMessage))
      return
    }
    let root = project.root
    Task { @MainActor in
      await performMove(move, action: action, root: root)
    }
  }

  private func performMove(_ move: Move, action: String, root: String) async {
    switch await store.move(move, root: root) {
    case .moved(let summary):
      let reversal: TimelineMoveFeedback.Reversal?
      if case .undo = move { reversal = .redo(summary.turn, root: root) } else { reversal = nil }
      showFeedback(
        .moved(summary, title: resultTitle(summary, root: root), root: root, reversal: reversal))
    case .failed(let message):
      showFeedback(.failed(message))
    case .stale:
      selection.selectedTurn = nil
      selection.runningSelected = false
      showFeedback(
        .failed(
          "History changed while you were choosing \(action). The current turn is selected."))
    case .turnRunning:
      showFeedback(.failed(activeRecordingRecoveryMessage))
    }
  }

  private func resultTitle(_ summary: RestoreSummary, root: String) -> String {
    guard let state = store.state(root: root),
      let prompt = Timeline.rows(state).first(where: { $0.id == summary.turn })?.turn.prompt
    else { return summary.title }
    return "\(summary.title) · \(prompt)"
  }

  /// Requests a recorded version without moving history or overriding later edits.
  private func restoreFile(
    _ file: TurnFile, turn: NodeID, root: String, after: Bool
  ) {
    guard store.moving.contains(root) == false else { return }
    recoveryRequest = RecoveryRequest(
      recovery: .files(path: file.path, turn: turn, after: after, folder: file.isDirectory),
      root: root)
  }

  private func recoverySucceeded(_ request: RecoveryRequest, summary: RestoreSummary) {
    var reversal: TimelineMoveFeedback.Reversal?
    if case .files(let path, let turn, let after, let folder) = request.recovery,
      !after, !folder, summary.restored + summary.removed > 0,
      let node = store.state(root: request.root)?.nodes[turn],
      let file = TurnFiles.list(node).first(where: { $0.path == path })
    {
      reversal = .putBack(file, turn: turn, root: request.root)
    }
    showFeedback(
      .moved(summary, title: request.recovery.action, root: request.root, reversal: reversal))
  }

  private func consumeNotificationFeedback() {
    switch store.takeNotificationFeedback() {
    case .failed(let message):
      showFeedback(.failed(message))
    case .moved(let summary, let root):
      showFeedback(
        .moved(summary, title: resultTitle(summary, root: root), root: root, reversal: nil))
    case nil:
      break
    }
  }

}

private struct SidebarProjectRow: View {
  let name: String
  let root: String
  let lastActivity: Int64
  let running: RunningTurn?

  var body: some View {
    Label {
      HStack(spacing: 6) {
        Text(name)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 4)
        if let running {
          Image(systemName: running.question == nil ? "circle.fill" : "hand.raised.fill")
            .font(.system(size: running.question == nil ? 6 : 10))
            .foregroundStyle(Color.accentColor)
            .help(running.question == nil ? "A turn is running" : "The agent is waiting for you")
            .accessibilityLabel(
              running.question == nil ? "A turn is running" : "The agent is waiting for you")
        } else if lastActivity > 0 {
          SwiftUI.TimelineView(.everyMinute) { context in
            Text(
              RelativeAge.short(
                from: lastActivity, now: Int64(context.date.timeIntervalSince1970))
            )
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
          }
        }
      }
    } icon: {
      Image(systemName: "folder")
    }
    .help((root as NSString).abbreviatingWithTildeInPath)
  }
}

/// The result of an action, floating over the bottom of the window.
private struct FeedbackToast: View {
  struct FollowUp {
    let title: String
    let perform: () -> Void
  }

  let feedback: TimelineMoveFeedback
  let followUp: FollowUp?
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      icon
        .font(.title3)
        .padding(.top, 1)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        switch feedback.kind {
        case .moved(let summary, let title, let root, _):
          Text(title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
          Text("Project: \(projectName(root))")
            .font(.callout.weight(.semibold))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Text(root)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Project root: \(root)")
          Text(summary.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
          keptFiles(summary)
          RestoreResultsView(summary: summary)
        case .failed(let message):
          Text(message)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let followUp {
        Button(followUp.title, action: followUp.perform)
          .controlSize(.large)
      }
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .help("Dismiss")
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: 600)
    .modifier(ToastBackground())
  }

  @ViewBuilder
  private var icon: some View {
    switch feedback.kind {
    case .moved(let summary, _, _, _):
      if summary.kept.isEmpty {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(StatusColor.added)
      } else {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(StatusColor.modified)
      }
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(StatusColor.error)
    }
  }

  @ViewBuilder
  private func keptFiles(_ summary: RestoreSummary) -> some View {
    if summary.kept.isEmpty == false {
      Text(
        "UndoTurn did not change \(summary.kept.count == 1 ? "this file" : "these files"):"
      )
      .font(.callout)
      .padding(.top, 4)
      ScrollView {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(summary.kept.prefix(3).enumerated()), id: \.offset) { item in
            Text(item.element)
          }
          if summary.kept.count > 3 {
            DisclosureGroup("\(summary.kept.count - 3) more") {
              ForEach(Array(summary.kept.dropFirst(3).enumerated()), id: \.offset) { item in
                Text(item.element)
              }
            }
          }
        }
        .font(.system(.callout, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      }
      .frame(maxHeight: 110)
      .fixedSize(horizontal: false, vertical: true)
    }
    if summary.skipped > 0 {
      Text("\(summary.skipped) \(summary.skipped == 1 ? "file" : "files") already matched.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

private struct TimelineMoveFeedback {
  let kind: Kind
  /// A new identity for every result, so a repeated result restarts its timer.
  let id = UUID()

  static func moved(
    _ summary: RestoreSummary, title: String, root: String, reversal: Reversal?
  ) -> Self {
    Self(kind: .moved(summary, title: title, root: root, reversal: reversal))
  }

  static func failed(_ message: String) -> Self {
    Self(kind: .failed(message))
  }

  enum Kind {
    case moved(RestoreSummary, title: String, root: String, reversal: Reversal?)
    case failed(String)
  }

  /// A redo, or an offer to restore the recorded after version with conflict protection.
  enum Reversal {
    case redo(NodeID, root: String)
    case putBack(TurnFile, turn: NodeID, root: String)
  }

  /// Results with file details remain available for inspection until dismissed.
  var staysOpen: Bool {
    switch kind {
    case .moved(let summary, _, _, _): !summary.fileResults.isEmpty || !summary.kept.isEmpty
    case .failed: true
    }
  }

  var announcement: String {
    switch kind {
    case .moved(let summary, let title, let root, _):
      "\(title). Project: \(projectName(root)). Project root: \(root). \(summary.detail)"
    case .failed(let message): message
    }
  }
}

/// Turn numbers repeat across projects, so an on-screen list row is keyed by its project too.
private struct ListItemOnScreen: Hashable {
  let root: String
  let item: TimelineItemID
}

func timelineByteCount(_ count: Int64) -> String {
  count.formatted(.byteCount(style: .file, spellsOutZero: false))
}

func timelineSizeChange(before: Int64?, after: Int64?) -> String {
  switch (before, after) {
  case (nil, let after?):
    timelineByteCount(after)
  case (let before?, nil):
    timelineByteCount(before)
  case (let before?, let after?):
    "\(timelineByteCount(before)) → \(timelineByteCount(after))"
  case (nil, nil):
    "Size unavailable"
  }
}

func timelineSpokenSizeChange(kind: ChangeCounts.Kind, before: Int64?, after: Int64?) -> String {
  switch kind {
  case .added:
    after.map { timelineByteCount($0) } ?? "size unavailable"
  case .deleted:
    before.map { "was \(timelineByteCount($0))" } ?? "size unavailable"
  case .modified:
    switch (before, after) {
    case (let before?, let after?):
      "\(timelineByteCount(before)) to \(timelineByteCount(after))"
    case (let before?, nil):
      timelineByteCount(before)
    case (nil, let after?):
      timelineByteCount(after)
    case (nil, nil):
      "size unavailable"
    }
  }
}
