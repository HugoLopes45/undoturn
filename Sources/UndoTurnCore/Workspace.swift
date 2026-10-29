import Darwin

public enum WorkspaceError: Error, Equatable, Sendable {
  /// The filesystem root and the user's home folder are never recorded.
  case refusedRoot(String)
  /// The folder has no recorded history yet, and the caller asked not to create it.
  case notRecorded(String)
  case system(SystemError)
  case history(HistoryLogError)
  case objects(ObjectStoreError)
}

/// The on-disk state UndoTurn keeps for one project folder:
/// `<home>/workspaces/<identifier>/{root, history.log, history.lock, mirror, journal, live, objects/}`.
public struct Workspace: Sendable {
  /// Real path of the recorded project folder.
  public let root: String
  /// Private state folder of this workspace.
  public let directory: String
  /// The private UndoTurn home used to create this workspace.
  public let undoTurnHome: String
  public let history: HistoryLog
  public let objects: ObjectStore

  public var mirrorPath: String { directory + "/mirror" }
  public var journalPath: String { directory + "/journal" }

  /// `$UNDOTURN_HOME`, else `$HOME/Library/Application Support/UndoTurn`.
  public static func defaultHome() -> String? {
    if let value = getenv("UNDOTURN_HOME"), value.pointee != 0 { return String(cString: value) }
    guard let home = getenv("HOME"), home.pointee != 0 else { return nil }
    return String(cString: home) + "/Library/Application Support/UndoTurn"
  }

  /// First 32 hex characters of the SHA-256 of the root path bytes.
  public static func identifier(forRoot root: String) -> String {
    String(FileSystem.sha256Hex(Array(root.utf8)).prefix(32))
  }

  /// Opens or creates the state folder for `root`, which must already be a real path.
  public static func open(root: String, home: String) throws(WorkspaceError) -> Workspace {
    let directory = home + "/workspaces/" + identifier(forRoot: root)
    do throws(SystemError) {
      try FileSystem.makeDirectories(directory, mode: 0o700)
      for path in [home, home + "/workspaces"] where chmod(path, 0o700) != 0 {
        throw SystemError(operation: "chmod", path: path, code: errno)
      }
      let rootFile = directory + "/root"
      let recorded = Array((root + "\n").utf8)
      if (try? FileSystem.readFile(rootFile)) != recorded {
        try FileSystem.writeAtomically(recorded, to: rootFile, mode: 0o600, durable: true)
      }
    } catch let error {
      throw .system(error)
    }
    let history: HistoryLog
    do {
      history = try HistoryLog(directory: directory)
    } catch let error {
      throw .history(error)
    }
    let objects: ObjectStore
    do {
      objects = try ObjectStore(directory: directory + "/objects")
    } catch let error {
      throw .objects(error)
    }
    return Workspace(
      root: root, directory: directory, undoTurnHome: home, history: history, objects: objects)
  }

  /// Picks the deepest usable registered root, then the nearest usable git root, then `cwd`.
  /// Refused as roots: folders that contain the user home or the UndoTurn home, folders inside the
  /// UndoTurn home, and a `cwd` fallback directly in the user home (`~/Desktop`) without its own
  /// `.git`. A `.git` in a refused folder is skipped, so a dotfiles repository in the home folder
  /// does not turn the whole home folder into one workspace.
  public static func resolve(cwd: String, home: String, userHome: String, create: Bool = true)
    throws(WorkspaceError) -> Workspace
  {
    let folder: String
    do {
      folder = try FileSystem.realPath(cwd)
    } catch let error {
      throw .system(error)
    }
    let refusal = RootRefusal(
      userHome: (try? FileSystem.realPath(userHome)) ?? userHome,
      undoTurnHome: (try? FileSystem.realPath(home)) ?? home)

    if let root = try registeredRoots(home: home)
      .filter({ contains($0, folder) && !refusal.refuses($0) })
      .max(by: { $0.count < $1.count })
    {
      return try open(root: root, home: home)
    }
    let candidate = try candidateRoot(folder: folder, refusal: refusal)
    guard create else { throw .notRecorded(candidate) }
    return try open(root: candidate, home: home)
  }

  private static func candidateRoot(folder: String, refusal: RootRefusal) throws(WorkspaceError)
    -> String
  {
    var candidate = folder
    while true {
      if !refusal.refuses(candidate) {
        let gitMarker: stat?
        do {
          gitMarker = try FileSystem.lstatIfPresent(candidate + "/.git")
        } catch let error {
          throw .system(error)
        }
        if gitMarker != nil { return candidate }
      }
      if candidate == "/" { break }
      candidate = FileSystem.parent(of: candidate)
    }
    guard !refusal.refuses(folder), FileSystem.parent(of: folder) != refusal.userHome else {
      throw .refusedRoot(folder)
    }
    return folder
  }

  private struct RootRefusal {
    let userHome: String
    let undoTurnHome: String

    func refuses(_ root: String) -> Bool {
      Workspace.contains(root, userHome) || Workspace.contains(root, undoTurnHome)
        || Workspace.contains(undoTurnHome, root)
    }
  }

  /// Every workspace with a readable `root` file, sorted by root.
  public static func registered(home: String) throws(WorkspaceError) -> [Workspace] {
    try registeredRoots(home: home).map { (root) throws(WorkspaceError) in
      try open(root: root, home: home)
    }
  }

  private static func registeredRoots(home: String) throws(WorkspaceError) -> [String] {
    let folder = home + "/workspaces"
    guard let stream = opendir(folder) else {
      if errno == ENOENT { return [] }
      throw .system(SystemError(operation: "opendir", path: folder, code: errno))
    }
    defer { closedir(stream) }
    var roots: [String] = []
    while let entry = readdir(stream) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      guard !name.hasPrefix(".") else { continue }
      guard let bytes = try? FileSystem.readFile(folder + "/" + name + "/root"), bytes.last == 0x0A
      else { continue }
      let root = String(decoding: bytes.dropLast(), as: UTF8.self)
      if identifier(forRoot: root) == name { roots.append(root) }
    }
    return roots.sorted()
  }

  private static func contains(_ root: String, _ path: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? root : root + "/")
  }
}
