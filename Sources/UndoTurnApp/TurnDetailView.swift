import AppKit
import SwiftUI
import UndoTurnCore
import UndoTurnLedger

struct TurnDetailView: View {
  let store: LedgerStore
  let root: String
  let state: HistoryState
  let row: TurnRow
  let lane: Int
  let node: NodeRecord
  let isMoving: Bool
  let turnRunning: Bool
  let onRestore: (Move, String) -> Void
  let onRestoreFile: (TurnFile) -> Void
  let onRecover: (SelectiveRecovery) -> Void
  let onLabelError: (String) -> Void
  let files: [TurnFile]

  @FocusState.Binding var labelFieldFocused: Bool
  @Environment(\.controlActiveState) private var controlActiveState
  @FocusState private var fileListFocused: Bool
  @State private var labelError: String?
  @State private var label: String
  @State private var selectedFilePath: String?
  @State private var promptExpanded = false
  @State private var editingLabel = false
  @State private var showingPaths = false
  @State private var labelCommitInProgress = false
  @State private var reportLabelCommitFailure = false
  @State private var headerHeight: CGFloat = 0
  @State private var paneHeight: CGFloat = 0

  init(
    store: LedgerStore,
    root: String,
    state: HistoryState,
    row: TurnRow,
    lane: Int,
    node: NodeRecord,
    isMoving: Bool,
    turnRunning: Bool,
    labelFieldFocused: FocusState<Bool>.Binding,
    onRestore: @escaping (Move, String) -> Void,
    onRestoreFile: @escaping (TurnFile) -> Void,
    onRecover: @escaping (SelectiveRecovery) -> Void,
    onLabelError: @escaping (String) -> Void
  ) {
    self.store = store
    self.root = root
    self.state = state
    self.row = row
    self.lane = lane
    self.node = node
    self.isMoving = isMoving
    self.turnRunning = turnRunning
    self.onRestore = onRestore
    self.onRestoreFile = onRestoreFile
    self.onRecover = onRecover
    self.onLabelError = onLabelError
    let files = TurnFiles.list(node)
    self.files = files
    self._labelFieldFocused = labelFieldFocused
    _label = State(initialValue: row.label ?? "")
    _selectedFilePath = State(initialValue: files.first?.id)
  }

  private var selectedChange: Change? {
    guard let selectedFilePath else { return nil }
    return (node.changes + node.outside).first { $0.path == selectedFilePath }
  }

  private var selectedFile: TurnFile? {
    files.first { $0.id == selectedFilePath }
  }

  private var preview: MovePreview? {
    let target: NodeID
    if row.state == .head {
      guard let parent = state.tree.parent(of: row.id) else { return nil }
      target = parent
    } else {
      target = row.id
    }
    return Timeline.preview(to: target, in: state)
  }

  private var fullPrompt: String {
    if row.kind != .turn || row.participants.count > 1 { return row.prompt }
    return node.conversation.displayPrompt ?? row.prompt
  }

  private var stateName: String {
    switch row.state {
    case .head: "Current"
    case .applied: "Applied"
    case .undone: "Undone"
    }
  }

  private var exactDate: String {
    Date(timeIntervalSince1970: TimeInterval(row.time))
      .formatted(date: .abbreviated, time: .shortened)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Expanded evidence scrolls within half the pane, so files and diffs stay reachable.
      ScrollView {
        header
          .padding(.horizontal, 20)
          .padding(.vertical, 14)
          .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
          } action: { height in
            headerHeight = height
          }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(headerHeight, paneHeight / 2))
      Divider()
      if files.isEmpty {
        Text("This turn changed no files.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(spacing: 0) {
          fileList
            .frame(width: 236)
          Divider()
          if let selectedChange, let selectedFile {
            DiffView(
              change: selectedChange, objects: store.objects(root: root), root: root,
              restore: restoreFileAction(selectedFile)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            Text("Select a file to see its diff.")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      paneHeight = height
    }
    .onChange(of: labelFieldFocused) { _, focused in
      if focused == false { commitLabel() }
    }
    .onChange(of: row.label) { _, newLabel in
      label = newLabel ?? ""
      labelError = nil
    }
    .onDisappear { commitLabel(reportFailure: true) }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      metadataLine
      VStack(alignment: .leading, spacing: 4) {
        Text(fullPrompt)
          .font(.title2.weight(.semibold))
          .textSelection(.enabled)
          .lineLimit(promptExpanded ? nil : 3)
          .fixedSize(horizontal: false, vertical: true)
        if fullPrompt.contains("\n") || fullPrompt.count > 200 {
          Button(promptExpanded ? "Show Less" : "Show More") {
            promptExpanded.toggle()
          }
          .buttonStyle(.link)
          .font(.callout)
        }
        if let rowLabel = row.label {
          Label(rowLabel, systemImage: "tag")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      actionRow
      TurnRevertControl(
        turn: row.id, state: row.state, turnRunning: turnRunning,
        isMoving: isMoving, onRecover: onRecover)
      if let selectedFile {
        FileRestoreControls(
          file: selectedFile, turn: row.id, disabled: isMoving || turnRunning,
          onRecover: onRecover)
      }
      if let labelError {
        Label {
          Text(labelError)
            .textSelection(.enabled)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(StatusColor.error)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      }
      if row.kind == .betweenTurns {
        Text("Changes observed between recorded turns. Their author is not known.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        TurnParticipantsView(participants: row.participants)
        if row.participants.count < 2 {
          TurnReplyView(conversation: node.conversation)
          TurnFactsView(
            conversation: node.conversation, started: state.turnStarts[node.id],
            finished: node.time,
            resumeCommand: resumeCommand(for: node.conversation, root: root))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var metadataLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(row.agentName)
        .fontWeight(.medium)
      if row.participants.count < 2, row.kind == .turn, let model = node.conversation.model {
        Text(" · \(model)")
      }
      if let started = state.turnStarts[node.id] {
        Text(" · \(turnDurationText(node.time - started))")
      }
      Text(" · \(exactDate) · \(row.number) · ")
      if row.state == .head {
        // Sits on the baseline and drops below it, like a text caret.
        Capsule()
          .fill(Color.accentColor)
          .frame(width: 2, height: 13)
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
          .padding(.trailing, 3)
          .accessibilityHidden(true)
      }
      Text(stateName + (lane > 0 ? ", side branch" : ""))
    }
    .font(.callout)
    .monospacedDigit()
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .truncationMode(.middle)
    .accessibilityElement(children: .combine)
  }

  private var actionRow: some View {
    HStack(alignment: .center, spacing: 8) {
      if let preview {
        actionButton(preview: preview)
        Button(row.state == .head ? preview.fileSummary : preview.summary) {
          showingPaths = true
        }
        .buttonStyle(.link)
        .font(.callout)
        .monospacedDigit()
        .help("Show the paths this action changes.")
        .popover(isPresented: $showingPaths, arrowEdge: .bottom) {
          pathsPopover(preview)
        }
      }
      moreMenu
      Spacer(minLength: 8)
      ChangeCountsText(counts: row.counts, emphasized: false)
        .font(.system(.title3, design: .monospaced).weight(.medium))
    }
  }

  private var moreMenu: some View {
    Menu {
      Button(row.label == nil ? "Add Label…" : "Edit Label…") {
        editingLabel = true
      }
      Divider()
      Button("Copy Prompt") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullPrompt, forType: .string)
      }
      if let command = resumeCommand(for: node.conversation, root: root) {
        Button("Copy Resume Command") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(command, forType: .string)
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .accessibilityLabel("More actions")
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More actions")
    .popover(isPresented: $editingLabel, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Label")
          .font(.headline)
        TextField("Label", text: $label, prompt: Text("Add a label"))
          .textFieldStyle(.roundedBorder)
          .frame(width: 240)
          .focused($labelFieldFocused)
          .accessibilityLabel("Turn label")
          .help("Type a label, then press Return. Press Escape to cancel.")
          .onSubmit {
            commitLabel()
            editingLabel = false
          }
          .onExitCommand {
            cancelLabel()
            editingLabel = false
          }
        Text("Return saves. Escape cancels.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(14)
      .onAppear { labelFieldFocused = true }
    }
  }

  private var fileList: some View {
    List(selection: $selectedFilePath) {
      Section {
        ForEach(Array(files.prefix(node.changes.count))) { file in
          fileListRow(file)
        }
      } header: {
        Text("Files · \(files.count)")
          .monospacedDigit()
      }
      if node.outside.isEmpty == false {
        Section("Outside the project") {
          ForEach(Array(files.dropFirst(node.changes.count))) { file in
            fileListRow(file)
          }
        }
      }
    }
    .focused($fileListFocused)
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
  }

  private func restoreFileAction(_ file: TurnFile) -> DiffRestoreAction {
    let item = file.isDirectory ? "Folder" : "File"
    return DiffRestoreAction(
      title: file.kind == .added ? "Remove \(item)" : "Restore \(item)",
      help: turnRunning
        ? activeRecordingRecoveryMessage
        : file.kind == .added
          ? "Removes \(file.name), which \(row.number) added. History does not move."
          : "Puts \(file.name) back as it was before \(row.number). History does not move.",
      disabled: isMoving || turnRunning || file.restorePaths.isEmpty,
      perform: { onRestoreFile(file) })
  }

  @ViewBuilder
  private func actionButton(preview: MovePreview) -> some View {
    if row.state == .head {
      Button {
        onRestore(.undo(row.id), "Undo #\(row.id.rawValue)")
      } label: {
        Label("Undo This Turn", systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(isMoving)
      .help("Undo \(row.number). Shortcut: ⌘Z.")
    } else {
      Button {
        onRestore(.to(row.id), "Go to #\(row.id.rawValue)")
      } label: {
        Label(
          "Go to \(row.number)",
          systemImage: row.state == .undone ? "arrow.uturn.forward" : "arrow.uturn.backward")
      }
      .buttonStyle(.borderedProminent)
      .tint(preview.removes == 0 ? .accentColor : Color(nsColor: .systemGray))
      .controlSize(.large)
      .disabled(isMoving)
      .monospacedDigit()
      .help("Puts every file back as it was after \(row.number).")
    }
  }

  private func pathsPopover(_ preview: MovePreview) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        previewPathGroup("Restore", paths: preview.pathsToRestore)
        previewPathGroup("Remove", paths: preview.pathsToRemove)
        previewPathGroup("Unchanged", paths: preview.pathsToKeep)
        if preview.pathsToRestore.isEmpty
          && preview.pathsToRemove.isEmpty
          && preview.pathsToKeep.isEmpty
        {
          Text("No file paths change.")
            .foregroundStyle(.secondary)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 380)
    .frame(maxHeight: 360)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private func previewPathGroup(_ title: String, paths: [String]) -> some View {
    if paths.isEmpty == false {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(title) · \(paths.count)")
          .font(.headline)
          .monospacedDigit()
        ForEach(paths, id: \.self) { path in
          Text(path)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
        }
      }
    }
  }

  private func fileListRow(_ file: TurnFile) -> some View {
    TimelineFileRow(
      file: file,
      root: root,
      emphasized: fileListFocused
        && controlActiveState == .key
        && selectedFilePath == file.path
    )
    .tag(file.id)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(timelineFileAccessibilityLabel(file))
  }

  private func cancelLabel() {
    label = row.label ?? ""
    labelError = nil
    labelFieldFocused = false
  }

  private func commitLabel(reportFailure: Bool = false) {
    let value = label
    guard value != (row.label ?? "") else {
      labelError = nil
      return
    }
    if reportFailure { reportLabelCommitFailure = true }
    guard labelCommitInProgress == false else { return }
    labelCommitInProgress = true
    Task { @MainActor in
      let error = await store.setLabel(
        value.isEmpty ? nil : value, for: row.id, root: root)
      if let error {
        if reportLabelCommitFailure {
          onLabelError(error)
        } else {
          labelError = error
        }
      }
      let shouldReportFailure = reportLabelCommitFailure
      labelCommitInProgress = false
      reportLabelCommitFailure = false
      if error == nil, label != value {
        commitLabel(reportFailure: shouldReportFailure)
      }
    }
  }
}

private struct TimelineFileRow: View {
  let file: TurnFile
  let root: String
  let emphasized: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Text(kindLetter)
        .font(.system(.callout, design: .monospaced).weight(.semibold))
        .foregroundStyle(kindColor)
        .frame(width: 14, alignment: .center)
        .help(kindDescription)
      VStack(alignment: .leading, spacing: 1) {
        Text(file.name)
          .lineLimit(1)
          .truncationMode(.middle)
        if file.folder.isEmpty == false {
          Text(file.folder)
            .font(.caption)
            .foregroundStyle(secondaryInk)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .help("\(file.path) · \(timelineSizeChange(before: file.before, after: file.after))")
    }
    .padding(.vertical, 4)
    .frame(minHeight: 36)
    .contentShape(Rectangle())
    .contextMenu {
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
      }
      if FileManager.default.fileExists(atPath: fileURL.path) {
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
      }
    }
  }

  private var fileURL: URL {
    if file.path.hasPrefix("/") {
      URL(fileURLWithPath: file.path)
    } else {
      URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(file.path)
    }
  }

  private var kindLetter: String {
    switch file.kind {
    case .added: "A"
    case .modified: "M"
    case .deleted: "D"
    }
  }

  private var kindDescription: String {
    switch file.kind {
    case .added: "Added"
    case .modified: "Modified"
    case .deleted: "Deleted"
    }
  }

  private var secondaryInk: Color {
    emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary
  }

  private var kindColor: Color {
    emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : changeColor(for: file.kind)
  }
}
private func timelineFileAccessibilityLabel(_ file: TurnFile) -> String {
  let kind: String
  switch file.kind {
  case .added: kind = "Added"
  case .modified: kind = "Modified"
  case .deleted: kind = "Deleted"
  }
  return "\(kind) \(file.path), "
    + "\(timelineSpokenSizeChange(kind: file.kind, before: file.before, after: file.after))"
}
