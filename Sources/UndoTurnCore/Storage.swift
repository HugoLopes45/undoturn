import Darwin

public struct StoredProject: Equatable, Sendable {
  /// Real path of the recorded project folder.
  public let root: String
  public let rootExists: Bool
  /// Bytes that deleting this history frees: blocks that no APFS clone shares.
  public let reclaimableBytes: Int64
  /// Recorded turns, the count `undoturn list --all` shows.
  public let turnCount: Int
  /// Unix time of the last history write, or nil when the history is empty.
  public let lastActivity: Int64?
  /// A turn is running; `Storage.remove` refuses the project.
  public let turnRunning: Bool
}

public enum StorageError: Error, Equatable, Sendable {
  case turnRunning(String)
  case workspace(WorkspaceError)
  case history(HistoryLogError)
  case system(SystemError)
}

public enum Storage {
  /// Every registered project, sorted by root. Walks each store folder: call off the main thread.
  public static func projects(home: String) throws(StorageError) -> [StoredProject] {
    let workspaces: [Workspace]
    do { workspaces = try Workspace.registered(home: home) } catch let error {
      throw .workspace(error)
    }
    return try workspaces.map { (workspace) throws(StorageError) in try project(workspace) }
  }

  /// Deletes the whole history and every stored version of the project at `root`, then every
  /// folder that an earlier removal renamed but did not finish deleting. Blocks on the project's
  /// history lock.
  public static func remove(root: String, home: String) throws(StorageError) {
    let workspace: Workspace
    do { workspace = try Workspace.open(root: root, home: home) } catch let error {
      throw .workspace(error)
    }
    let lock: HistoryLock
    do { lock = try workspace.history.lock() } catch let error { throw .history(error) }
    let summary: HistorySummary
    do { summary = try workspace.history.summary() } catch let error { throw .history(error) }
    guard summary.pendingTurn == nil else { throw .turnRunning(root) }
    // The rename hides the history from every reader at once, so the lock can go before the
    // slow removal. The random part keeps the name free while an earlier removal of the same
    // root still runs or was left behind.
    let workspaces = home + "/workspaces"
    let removing =
      workspaces + "/" + removingPrefix + Workspace.identifier(forRoot: root) + "-"
      + FileSystem.randomHex(byteCount: 8)
    guard rename(workspace.directory, removing) == 0 else {
      throw .system(SystemError(operation: "rename", path: workspace.directory, code: errno))
    }
    _ = consume lock
    try removeTree(removing)
    try removeInterruptedRemovals(in: workspaces)
  }

  private static func project(_ workspace: Workspace) throws(StorageError) -> StoredProject {
    let summary: HistorySummary
    do { summary = try workspace.history.summary() } catch let error { throw .history(error) }
    var info = stat()
    let rootExists =
      workspace.root.withCString { lstat($0, &info) } == 0 || (errno != ENOENT && errno != ENOTDIR)
    var lastActivity: Int64?
    if summary.lastRecord != nil {
      let log = workspace.directory + "/history.log"
      guard log.withCString({ lstat($0, &info) }) == 0 else {
        throw .system(SystemError(operation: "lstat", path: log, code: errno))
      }
      lastActivity = Int64(info.st_mtimespec.tv_sec)
    }
    return StoredProject(
      root: workspace.root, rootExists: rootExists,
      reclaimableBytes: try reclaimableBytes(in: workspace.directory),
      turnCount: Int(clamping: summary.nodeCount), lastActivity: lastActivity,
      turnRunning: summary.pendingTurn != nil)
  }

  private static func reclaimableBytes(in directory: String) throws(StorageError) -> Int64 {
    let descriptor = directory.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: directory, code: errno))
    }
    return try reclaimableBytes(descriptor: descriptor, path: directory)
  }

  /// Sums the folder that `descriptor` opens, and closes `descriptor`.
  private static func reclaimableBytes(descriptor: Int32, path: String) throws(StorageError)
    -> Int64
  {
    guard let stream = fdopendir(descriptor) else {
      let code = errno
      _ = close(descriptor)
      throw .system(SystemError(operation: "fdopendir", path: path, code: code))
    }
    defer { closedir(stream) }
    var total: Int64 = 0
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else {
          throw .system(SystemError(operation: "readdir", path: path, code: errno))
        }
        return total
      }
      let name = withUnsafeBytes(of: entry.pointee.d_name) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      switch Int32(entry.pointee.d_type) {
      case DT_DIR where name != "." && name != "..":
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
          if errno == ENOENT { continue }
          throw .system(SystemError(operation: "openat", path: path + "/" + name, code: errno))
        }
        total += try reclaimableBytes(descriptor: child, path: path + "/" + name)
      case DT_REG:
        total += try privateBytes(directory: descriptor, name: name, path: path + "/" + name)
      default:
        continue
      }
    }
  }

  /// The file's blocks that no clone shares. Volumes without that attribute report allocated
  /// blocks instead.
  private static func privateBytes(directory: Int32, name: String, path: String)
    throws(StorageError) -> Int64
  {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    var buffer: (UInt64, UInt64) = (0, 0)
    let size = withUnsafeMutableBytes(of: &buffer) { (raw) -> Int64? in
      let result = getattrlistat(
        directory, name, &request, raw.baseAddress, raw.count,
        UInt(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
      // The kernel packs the value right after the 4-byte length.
      guard result == 0, raw.load(as: UInt32.self) >= 12 else { return nil }
      return raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
    }
    if let size { return size }
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return 0 }
      throw .system(SystemError(operation: "fstatat", path: path, code: errno))
    }
    return Int64(info.st_blocks) * 512
  }

  /// Prefix of the folders that `remove` renamed and has not finished deleting. No registered
  /// workspace has a name that starts with `.`.
  private static let removingPrefix = ".removing-"

  /// Whether `remove` gives this name: `.removing-<identifier>-<16 hex>`, or
  /// `.removing-<identifier>` from before the random part.
  private static func isRemovalName(_ name: String) -> Bool {
    guard name.utf8.starts(with: removingPrefix.utf8) else { return false }
    let rest = name.utf8.dropFirst(removingPrefix.utf8.count)
    guard rest.count == 32 || rest.count == 49 else { return false }
    for (offset, byte) in rest.enumerated() {
      let isHex = (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
      guard offset == 32 ? byte == 0x2D : isHex else { return false }
    }
    return true
  }

  /// Deletes every folder in `workspaces` that a removal renamed but did not finish deleting,
  /// because its process stopped or its deletion failed. Another removal may delete the same
  /// folders at the same time.
  private static func removeInterruptedRemovals(in workspaces: String) throws(StorageError) {
    guard let stream = opendir(workspaces) else {
      throw .system(SystemError(operation: "opendir", path: workspaces, code: errno))
    }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else { break }
      let name = withUnsafeBytes(of: entry.pointee.d_name) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      // `remove` only makes folders with these names: anything else stays, and no link is followed.
      if Int32(entry.pointee.d_type) == DT_DIR, isRemovalName(name) {
        names.append(name)
      }
    }
    let code = errno
    closedir(stream)
    guard code == 0 else {
      throw .system(SystemError(operation: "readdir", path: workspaces, code: code))
    }
    for name in names { try removeTree(workspaces + "/" + name) }
  }

  /// Removes `path` and its content without following symbolic links. A `path` that is already
  /// gone counts as removed: another removal deleted it first.
  private static func removeTree(_ path: String) throws(StorageError) {
    let removed = nftw(
      path,
      { entry, _, _, _ in
        guard let entry else { return -1 }
        return Darwin.remove(entry) == 0 || errno == ENOENT ? 0 : -1
      }, 16, FTW_DEPTH | FTW_PHYS)
    guard removed == 0 || errno == ENOENT else {
      throw .system(SystemError(operation: "nftw", path: path, code: errno))
    }
  }
}
