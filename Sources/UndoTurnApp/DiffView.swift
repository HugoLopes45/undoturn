import AppKit
import Darwin
import SwiftUI
import UndoTurnCore
import UndoTurnLedger

/// The file action beside a diff: put the file back as it was before the turn.
struct DiffRestoreAction {
  let title: String
  let help: String
  let disabled: Bool
  let perform: () -> Void
}

struct DiffView: View {
  let change: Change
  let objects: ObjectStore?
  let root: String
  let restore: DiffRestoreAction

  @State private var loadingState = DiffLoadingState.loading

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(change.path)
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .lineLimit(1)
            .truncationMode(.head)
            .help(change.path)
          if let lineCounts {
            HStack(spacing: 5) {
              if lineCounts.added > 0 {
                Text("+\(lineCounts.added)").foregroundStyle(StatusColor.added)
              }
              if lineCounts.removed > 0 {
                Text("−\(lineCounts.removed)").foregroundStyle(StatusColor.removed)
              }
            }
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .monospacedDigit()
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
              "\(fileKind), \(lineCounts.added) lines added, \(lineCounts.removed) lines removed")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button(restore.title, action: restore.perform)
          .disabled(restore.disabled)
          .help(restore.help)

        Menu {
          Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(change.path, forType: .string)
          }
          if let copyableHunks {
            Button("Copy Diff") {
              copyDiff(copyableHunks)
            }
          }
          if FileManager.default.fileExists(atPath: fileURL.path) {
            Button("Reveal in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
          }
        } label: {
          Image(systemName: "ellipsis")
            .accessibilityLabel("File actions")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("File actions")
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 44)
      Divider()

      Group {
        switch loadingState {
        case .loading:
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Loading diff")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        case .loaded(let presentation):
          diffContent(presentation)
        case .failed(let message):
          Label {
            Text("Cannot show the diff. UndoTurn cannot read the stored file: \(message).")
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(StatusColor.error)
          }
          .padding(14)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    .task(id: change) {
      await loadDiff()
    }
  }

  private var fileKind: String {
    if change.before == .absent { return "Added" }
    if change.after == .absent { return "Deleted" }
    return "Modified"
  }

  private var lineCounts: (added: Int, removed: Int)? {
    guard case .loaded(let presentation) = loadingState,
      let added = presentation.addedLineCount, let removed = presentation.removedLineCount
    else { return nil }
    return (added, removed)
  }

  private var fileURL: URL {
    if change.path.hasPrefix("/") {
      URL(fileURLWithPath: change.path)
    } else {
      URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(change.path)
    }
  }

  private var copyableHunks: [DiffHunk]? {
    guard
      case .loaded(let presentation) = loadingState,
      case .text(let hunks) = presentation.diff,
      hunks.isEmpty == false
    else { return nil }
    return hunks
  }

  @ViewBuilder
  private func diffContent(_ presentation: DiffPresentation) -> some View {
    switch presentation.diff {
    case .text(let hunks):
      if hunks.isEmpty {
        Text("No text changes.")
          .foregroundStyle(.secondary)
          .padding(14)
      } else {
        GeometryReader { geometry in
          ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(hunks.indices, id: \.self) { hunkIndex in
                let hunk = hunks[hunkIndex]
                if wholeFileChange == false {
                  Text(
                    "@@ -\(hunk.oldStart),\(hunk.oldCount) "
                      + "+\(hunk.newStart),\(hunk.newCount) @@"
                  )
                  .font(.system(.callout, design: .monospaced))
                  .monospacedDigit()
                  .foregroundStyle(.secondary)
                  .fixedSize()
                  .padding(.leading, 14)
                  .padding(.vertical, 6)
                  .frame(minWidth: geometry.size.width, alignment: .leading)
                  .background(Color.accentColor.opacity(0.06))
                  .accessibilityLabel(hunkAccessibilityLabel(hunk))
                  .accessibilityAddTraits(.isHeader)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                  let lines = presentation.numberedHunks[hunkIndex]
                  ForEach(lines.indices, id: \.self) { lineIndex in
                    DiffLineRow(
                      numberedLine: lines[lineIndex],
                      showsOldNumber: change.before != .absent,
                      showsNewNumber: change.after != .absent,
                      minimumWidth: geometry.size.width
                    )
                  }
                }
              }
            }
            .frame(
              minWidth: geometry.size.width,
              minHeight: geometry.size.height,
              alignment: .topLeading
            )
            .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    case .binary(let before, let after):
      Text("Binary file. No line diff. Size: \(timelineSizeChange(before: before, after: after)).")
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
    case .tooLarge(let before, let after):
      Text(
        "No line diff for files over "
          + "\(ByteCountFormatter.string(fromByteCount: Int64(DiffContent.sizeLimit), countStyle: .memory)). "
          + "Size: \(timelineSizeChange(before: before, after: after))."
      )
      .monospacedDigit()
      .fixedSize(horizontal: false, vertical: true)
      .padding(14)
    case .notStored(let before, let after):
      Text(
        "UndoTurn does not store files over "
          + "\(ByteCountFormatter.string(fromByteCount: ObjectStore.defaultSizeLimit, countStyle: .memory)), "
          + "so there is no diff. Undo keeps this file."
      )
      .fixedSize(horizontal: false, vertical: true)
      .padding(14)
      .accessibilityValue(timelineSizeChange(before: before, after: after))
    }
  }

  private var wholeFileChange: Bool {
    change.before == .absent || change.after == .absent
  }

  private func loadDiff() async {
    guard let objects else {
      loadingState = .failed("the object store of this project is not open")
      return
    }
    loadingState = .loading
    let change = self.change
    let result = await Task.detached(priority: .userInitiated) { () -> DiffLoadResult in
      do throws(ObjectStoreError) {
        let diff = try TurnFiles.diff(change, objects: objects)
        return .loaded(diffPresentation(diff))
      } catch {
        return .failed(error)
      }
    }.value
    guard Task.isCancelled == false else { return }
    switch result {
    case .loaded(let presentation):
      loadingState = .loaded(presentation)
    case .failed(let error):
      loadingState = .failed(diffErrorDescription(error))
    }
  }

  private func copyDiff(_ hunks: [DiffHunk]) {
    let path = change.path
    let hasBefore = change.before != .absent
    let hasAfter = change.after != .absent
    Task { @MainActor in
      let text = await Task.detached(priority: .userInitiated) {
        unifiedDiff(hunks, path: path, hasBefore: hasBefore, hasAfter: hasAfter)
      }.value
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
  }
}

private struct NumberedDiffLine: Sendable {
  let kind: DiffLine.Kind
  let oldNumber: Int?
  let newNumber: Int?
  let text: String
}

private struct DiffPresentation: Sendable {
  let diff: FileDiff
  let numberedHunks: [[NumberedDiffLine]]
  let addedLineCount: Int?
  let removedLineCount: Int?
}

private func diffPresentation(_ diff: FileDiff) -> DiffPresentation {
  guard case .text(let hunks) = diff else {
    return DiffPresentation(
      diff: diff, numberedHunks: [], addedLineCount: nil, removedLineCount: nil)
  }
  var added = 0
  var removed = 0
  for line in hunks.lazy.flatMap(\.lines) {
    switch line.kind {
    case .added: added += 1
    case .removed: removed += 1
    case .context: break
    }
  }
  return DiffPresentation(
    diff: diff,
    numberedHunks: hunks.map(numberedDiffLines),
    addedLineCount: added,
    removedLineCount: removed
  )
}

private func numberedDiffLines(for hunk: DiffHunk) -> [NumberedDiffLine] {
  var oldNumber = hunk.oldStart
  var newNumber = hunk.newStart
  return hunk.lines.map { line in
    let text = clippedDiffText(line.text)
    switch line.kind {
    case .context:
      defer {
        oldNumber += 1
        newNumber += 1
      }
      return NumberedDiffLine(
        kind: line.kind, oldNumber: oldNumber, newNumber: newNumber, text: text)
    case .removed:
      defer { oldNumber += 1 }
      return NumberedDiffLine(kind: line.kind, oldNumber: oldNumber, newNumber: nil, text: text)
    case .added:
      defer { newNumber += 1 }
      return NumberedDiffLine(kind: line.kind, oldNumber: nil, newNumber: newNumber, text: text)
    }
  }
}

private func clippedDiffText(_ bytes: [UInt8]) -> String {
  var endIndex = 0
  var characterCount = 0
  while endIndex < bytes.count && characterCount < 2_000 {
    let first = bytes[endIndex]
    if first & 0x80 == 0 {
      endIndex += 1
    } else if first & 0xE0 == 0xC0 {
      endIndex += 2
    } else if first & 0xF0 == 0xE0 {
      endIndex += 3
    } else {
      endIndex += 4
    }
    characterCount += 1
  }
  guard endIndex < bytes.count else {
    return String(decoding: bytes, as: UTF8.self)
  }
  let remainingCharacters = bytes[endIndex...].reduce(into: 0) { count, byte in
    if byte & 0xC0 != 0x80 { count += 1 }
  }
  return String(decoding: bytes[..<endIndex], as: UTF8.self)
    + "… \(remainingCharacters) more characters"
}

private struct DiffLineRow: View {
  let numberedLine: NumberedDiffLine
  let showsOldNumber: Bool
  let showsNewNumber: Bool
  let minimumWidth: CGFloat

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if showsOldNumber {
        Text(numberedLine.oldNumber.map(String.init) ?? "")
          .foregroundStyle(.secondary)
          .frame(width: 36, alignment: .trailing)
          .accessibilityHidden(true)
      }
      if showsNewNumber {
        Text(numberedLine.newNumber.map(String.init) ?? "")
          .foregroundStyle(.secondary)
          .frame(width: 36, alignment: .trailing)
          .accessibilityHidden(true)
      }
      Text(prefix)
        .foregroundStyle(prefixColor)
        .frame(width: 12, alignment: .leading)
        .accessibilityHidden(true)
      Text(numberedLine.text)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
    .font(.system(.body, design: .monospaced))
    .monospacedDigit()
    .padding(.leading, 6)
    .padding(.vertical, 1)
    .frame(minWidth: minimumWidth, alignment: .leading)
    .background(background)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var prefix: String {
    switch numberedLine.kind {
    case .context: " "
    case .removed: "−"
    case .added: "+"
    }
  }

  private var background: Color {
    switch numberedLine.kind {
    case .context: .clear
    case .removed: StatusColor.removed.opacity(0.16)
    case .added: StatusColor.added.opacity(0.16)
    }
  }

  private var prefixColor: Color {
    switch numberedLine.kind {
    case .context: .secondary
    case .removed: StatusColor.removed
    case .added: StatusColor.added
    }
  }

  private var accessibilityLabel: String {
    switch numberedLine.kind {
    case .context:
      "Line \(numberedLine.newNumber.map(String.init) ?? ""): \(numberedLine.text)"
    case .removed:
      "Removed line \(numberedLine.oldNumber.map(String.init) ?? ""): \(numberedLine.text)"
    case .added:
      "Added line \(numberedLine.newNumber.map(String.init) ?? ""): \(numberedLine.text)"
    }
  }
}

private enum DiffLoadResult: Sendable {
  case loaded(DiffPresentation)
  case failed(ObjectStoreError)
}

private enum DiffLoadingState {
  case loading
  case loaded(DiffPresentation)
  case failed(String)
}

private func hunkAccessibilityLabel(_ hunk: DiffHunk) -> String {
  let usesOldRange = hunk.oldCount > 0
  let start = usesOldRange ? hunk.oldStart : hunk.newStart
  let count = usesOldRange ? hunk.oldCount : hunk.newCount
  return "Lines \(start) to \(start + max(count - 1, 0))"
}

private func unifiedDiff(
  _ hunks: [DiffHunk], path: String, hasBefore: Bool, hasAfter: Bool
) -> String {
  let lineBytes = hunks.reduce(0) { total, hunk in
    total + hunk.lines.reduce(0) { $0 + $1.text.count + 2 }
  }
  var output = ""
  output.reserveCapacity(lineBytes + path.utf8.count * 2 + hunks.count * 48 + 64)
  output.append(contentsOf: "--- \(hasBefore ? "a/\(path)" : "/dev/null")\n")
  output.append(contentsOf: "+++ \(hasAfter ? "b/\(path)" : "/dev/null")\n")
  for hunk in hunks {
    output.append(
      contentsOf:
        "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n")
    for line in hunk.lines {
      switch line.kind {
      case .context: output.append(" ")
      case .removed: output.append("-")
      case .added: output.append("+")
      }
      output.append(contentsOf: String(decoding: line.text, as: UTF8.self))
      if line.hasNewline {
        output.append("\n")
      } else {
        output.append("\n\\ No newline at end of file\n")
      }
    }
  }
  return output
}

private func diffErrorDescription(_ error: ObjectStoreError) -> String {
  switch error {
  case .system(let systemError):
    "\(systemError.operation) \(systemError.path): "
      + String(cString: Darwin.strerror(systemError.code))
  case .invalidPath(let path): "the stored path \(path) is invalid"
  case .invalidObjectID(let objectID):
    "the stored object identifier \(objectID.rawValue) is invalid"
  case .invalidSizeLimit(let size): "the object store size limit \(size) is invalid"
  case .notRegularFile(let path): "\(path) is not a regular file"
  case .sourceChanged(let path): "\(path) changed while UndoTurn read it"
  case .hashFailure(let path): "the stored object at \(path) does not match its hash"
  }
}
