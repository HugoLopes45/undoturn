import Darwin

enum WorkspaceScan {
  case full(ScanResult)
  case delta(RescanDelta)

  var unreadableDirectories: [String] {
    switch self {
    case .full(let result): return result.unreadableDirectories
    case .delta(let delta): return delta.unreadableDirectories
    }
  }
}

struct OutsideWalkFile {
  let path: String
  let stat: StatKey
}

struct OutsideWalkSnapshot {
  let files: [OutsideWalkFile]
  let unreadableDirectories: [String]
  let absent: Bool
}

struct OutsideWalker {
  let limit: Int?
  /// Real path of the UndoTurn home. The walker never enters it.
  let excluded: String
  var files: [OutsideWalkFile] = []
  var unreadableDirectories: [String] = []
  private(set) var visitedCount = 0

  mutating func capture(_ path: String) throws(SystemError) -> OutsideWalkSnapshot? {
    visitedCount = 1
    guard limit.map({ visitedCount <= $0 }) ?? true else { return nil }
    guard let info = try FileSystem.lstatIfPresent(path) else {
      return OutsideWalkSnapshot(
        files: [], unreadableDirectories: [], absent: true)
    }
    switch info.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFREG):
      let realPath = try FileSystem.realPath(path)
      if !isExcludedPath(realPath) {
        files.append(OutsideWalkFile(path: realPath, stat: StatKey(info)))
      }
    case mode_t(S_IFDIR):
      return try captureDirectory(path)
    default:
      break
    }
    return OutsideWalkSnapshot(
      files: files, unreadableDirectories: unreadableDirectories, absent: false)
  }

  private mutating func captureDirectory(_ path: String) throws(SystemError)
    -> OutsideWalkSnapshot?
  {
    let realPath = try FileSystem.realPath(path)
    if isExcludedPath(realPath) {
      return OutsideWalkSnapshot(files: [], unreadableDirectories: [], absent: false)
    }
    let descriptor = realPath.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT {
        return OutsideWalkSnapshot(files: [], unreadableDirectories: [], absent: true)
      }
      guard code == EACCES || code == EPERM else {
        throw SystemError(operation: "open directory", path: realPath, code: code)
      }
      unreadableDirectories.append(realPath)
      return OutsideWalkSnapshot(
        files: files, unreadableDirectories: unreadableDirectories, absent: false)
    }
    defer { _ = Darwin.close(descriptor) }
    guard try walkDirectory(realPath, descriptor: descriptor) else { return nil }
    return OutsideWalkSnapshot(
      files: files, unreadableDirectories: unreadableDirectories, absent: false)
  }

  private mutating func walkDirectory(_ path: String, descriptor: Int32) throws(SystemError)
    -> Bool
  {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0 else {
      throw SystemError(operation: "dup", path: path, code: errno)
    }
    guard let stream = fdopendir(duplicate) else {
      let code = errno
      _ = Darwin.close(duplicate)
      throw SystemError(operation: "fdopendir", path: path, code: code)
    }
    defer { _ = closedir(stream) }

    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        let code = errno
        if code == EACCES || code == EPERM {
          unreadableDirectories.append(path)
          return true
        }
        guard code == 0 else { throw SystemError(operation: "readdir", path: path, code: code) }
        break
      }
      let name = withUnsafeBytes(of: entry.pointee.d_name) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      if name == "." || name == ".." { continue }
      visitedCount += 1
      guard limit.map({ visitedCount <= $0 }) ?? true else { return false }
      names.append(name)
    }

    return try walkChildren(names.sorted(), at: descriptor, path: path)
  }

  private mutating func walkChildren(_ names: [String], at descriptor: Int32, path: String)
    throws(SystemError) -> Bool
  {
    for name in names {
      var info = stat()
      let status = name.withCString {
        fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
      }
      if status != 0 {
        let code = errno
        if code == ENOENT { continue }
        if code == EACCES || code == EPERM {
          unreadableDirectories.append(path)
          return true
        }
        throw SystemError(operation: "fstatat", path: path + "/" + name, code: code)
      }
      let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
      switch info.st_mode & mode_t(S_IFMT) {
      case mode_t(S_IFREG):
        files.append(OutsideWalkFile(path: childPath, stat: StatKey(info)))
      case mode_t(S_IFDIR):
        guard try walkChildDirectory(name, at: descriptor, path: childPath) else { return false }
      default:
        break
      }
    }
    return true
  }

  private mutating func walkChildDirectory(_ name: String, at descriptor: Int32, path: String)
    throws(SystemError) -> Bool
  {
    if isExcludedPath(path) { return true }
    let child = name.withCString {
      openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    if child < 0 {
      let code = errno
      if code == ENOENT || code == ENOTDIR || code == ELOOP { return true }
      if code == EACCES || code == EPERM {
        unreadableDirectories.append(path)
        return true
      }
      throw SystemError(operation: "open directory", path: path, code: code)
    }
    defer { _ = Darwin.close(child) }
    return try walkDirectory(path, descriptor: child)
  }

  private func isExcludedPath(_ path: String) -> Bool {
    path == excluded || path.hasPrefix(excluded + "/")
  }
}

/// Visibility around restored rules, or an external policy edit whose prior bytes are unavailable.
struct RestoredRuleSnapshot {
  let before: ScanResult?
  let after: ScanResult

  init?(
    restored: [Change], workspace: Workspace, mirror: Mirror, policyChanged: Bool
  ) throws(RecorderError) {
    let overrides = try Self.overrides(restored: restored, workspace: workspace)
    guard !overrides.isEmpty || policyChanged else { return nil }
    do throws(SystemError) {
      after = try Scanner.scan(root: workspace.root)
      if policyChanged && overrides[".undoturnignore"] == nil {
        before = nil
      } else {
        var paths: [String] = []
        for path in after.files.keys where (mirror[path] ?? .absent) == .absent {
          paths.append(path)
        }
        for path in mirror.entries.keys where after.files[path] == nil { paths.append(path) }
        let delta = try Scanner.rescan(
          root: workspace.root, paths: paths, ignoreFileOverrides: overrides)
        if let delta {
          before = ScanResult(
            files: delta.observedFiles, unreadableDirectories: delta.unreadableDirectories)
        } else {
          before = try Scanner.scan(root: workspace.root, ignoreFileOverrides: overrides)
        }
      }
      if let path = after.unreadableDirectories.first ?? before?.unreadableDirectories.first {
        throw SystemError(
          operation: "reconcile ignore rules", path: workspace.root + "/" + path, code: EACCES)
      }
    } catch let error {
      throw .system(error)
    }
  }

  private static func overrides(
    restored: [Change], workspace: Workspace
  ) throws(RecorderError) -> [String: IgnoreFileOverride] {
    var result: [String: IgnoreFileOverride] = [:]
    for change in restored {
      guard let key = rulePath(change.path) else { continue }
      let cargo = key == "Cargo.toml" || key.hasSuffix("/Cargo.toml")
      let contents: [UInt8]?
      switch change.before {
      case .stored(let id, _):
        do throws(ObjectStoreError) {
          contents = cargo ? [] : try workspace.objects.contents(of: id)
        } catch let error { throw .objectStore(error) }
      case .unstored:
        guard cargo else {
          throw .system(
            SystemError(
              operation: "recover prior ignore rules", path: workspace.root + "/" + key, code: EIO))
        }
        contents = []
      case .absent, .link, .directory:
        contents = nil
      }
      result[key] = IgnoreFileOverride(contents: contents)
    }
    return result
  }

  private static func rulePath(_ path: String) -> String? {
    guard !path.hasPrefix("/") else { return nil }
    let folded = path.lowercased()
    if folded == ".undoturnignore" || folded == ".git/info/exclude" { return folded }
    if path == "Cargo.toml" || path.hasSuffix("/Cargo.toml") { return path }
    guard let name = path.split(separator: "/").last, name.lowercased() == ".gitignore" else {
      return nil
    }
    return String(path.dropLast(name.count)) + ".gitignore"
  }
}
