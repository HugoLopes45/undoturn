import Darwin
import UndoTurnCore

struct LedgerTemporaryDirectory: ~Copyable {
  let path: String

  init() throws(SystemError) {
    var template = Array("/tmp/undoturn-ledger-test.XXXXXX".utf8CString)
    guard let created = mkdtemp(&template) else {
      throw SystemError(operation: "mkdtemp", path: "/tmp", code: errno)
    }
    guard let resolved = realpath(created, nil) else {
      let code = errno
      _ = rmdir(created)
      throw SystemError(operation: "realpath", path: String(cString: created), code: code)
    }
    defer { free(resolved) }
    path = String(cString: resolved)
  }

  deinit {
    _ = nftw(
      path, { entry, _, _, _ in entry.map { Darwin.remove($0) } ?? -1 }, 16, FTW_DEPTH | FTW_PHYS)
  }
}

func ledgerStat(size: Int64 = 1, inode: UInt64 = 1, modified: Int64 = 0) -> StatKey {
  StatKey(device: 1, inode: inode, size: size, modified: modified, mode: 0o644)
}

func ledgerVersion(_ id: String, size: Int64 = 1, inode: UInt64 = 1) -> FileVersion {
  .stored(ObjectID(rawValue: id), ledgerStat(size: size, inode: inode))
}

func ledgerNode(
  _ id: UInt64,
  parent: UInt64,
  time: Int64,
  agent: String = "codex",
  prompt: String? = nil,
  changes: [Change] = []
) -> NodeRecord {
  NodeRecord(
    id: NodeID(rawValue: id),
    parent: NodeID(rawValue: parent),
    time: time,
    conversation: Conversation(agent: agent, prompt: prompt),
    changes: changes
  )
}

func ledgerTurnRecords(_ node: NodeRecord) -> [HistoryRecord] {
  [
    .begin(time: node.time - 1, conversation: node.conversation),
    .node(node),
  ]
}

func replayLedgerHistory(in directory: String, records: [HistoryRecord]) throws(HistoryLogError)
  -> HistoryState
{
  let log = try HistoryLog(directory: directory)
  for record in records {
    try log.append(record)
  }
  return try log.replay()
}

func writeLedgerFile(_ bytes: [UInt8], to path: String) throws(SystemError) {
  let descriptor = path.withCString {
    Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode_t(0o600))
  }
  guard descriptor >= 0 else {
    throw SystemError(operation: "open", path: path, code: errno)
  }
  defer { _ = Darwin.close(descriptor) }

  var offset = 0
  while offset < bytes.count {
    let amount = bytes.withUnsafeBytes { buffer in
      Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
    }
    if amount < 0 && errno == EINTR { continue }
    guard amount > 0 else {
      throw SystemError(operation: "write", path: path, code: amount < 0 ? errno : EIO)
    }
    offset += amount
  }
}

func ledgerStatKey(at path: String) throws(SystemError) -> StatKey {
  var info = stat()
  guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else {
    throw SystemError(operation: "lstat", path: path, code: errno)
  }
  return StatKey(
    device: Int64(info.st_dev),
    inode: UInt64(info.st_ino),
    size: Int64(info.st_size),
    modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
    mode: UInt16(info.st_mode & 0o7777)
  )
}
