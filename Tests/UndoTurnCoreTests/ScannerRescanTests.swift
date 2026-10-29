import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct ScannerRescanTests {
  @Test func fullScanIsRequiredForPathsThatCanChangeTraversalRules() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    try rescanMakeDirectory("\(root)/.git/info")
    try rescanMakeDirectory("\(root)/nested")
    try rescanWriteFile("", at: "\(root)/.gitignore")
    try rescanWriteFile("", at: "\(root)/.git/info/exclude")
    try rescanWriteFile("", at: "\(root)/nested/Cargo.toml")

    for path in [
      "", ".gitignore", "nested/Cargo.toml", ".git/info/exclude", ".GitIgnore", "nested/.GITIGNORE",
      ".Git/Info/Exclude", ".undoturnignore", ".UndoTurnIgnore",
    ] {
      #expect(try Scanner.rescan(root: root, paths: [path]) == nil)
    }
  }

  @Test func coalescesPathsBelowAnAlreadySelectedAncestor() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    try rescanWriteFile("old", at: "\(root)/a/b/file.txt")
    let previous = try Scanner.scan(root: root).files
    try rescanWriteFile("new value", at: "\(root)/a/b/file.txt")

    let withDescendantDelta = try Scanner.rescan(root: root, paths: ["a", "a/b"])
    let ancestorOnlyDelta = try Scanner.rescan(root: root, paths: ["a"])
    let withDescendant = try #require(withDescendantDelta)
    let ancestorOnly = try #require(ancestorOnlyDelta)

    #expect(withDescendant.applying(to: previous) == ancestorOnly.applying(to: previous))
  }

  @Test func unreadableTouchedDirectoryKeepsItsEarlierEntries() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    let blocked = "\(root)/blocked"
    try rescanWriteFile("before", at: "\(blocked)/nested/file.txt")
    let previous = try Scanner.scan(root: root)
    guard chmod(blocked, 0) == 0 else {
      throw SystemError(operation: "chmod", path: blocked, code: errno)
    }
    defer { _ = chmod(blocked, 0o700) }

    let rescan = try Scanner.rescan(root: root, paths: ["blocked"])
    let result = try #require(rescan)

    var expected = previous.files
    expected["blocked"] = StatKey.directory(mode: 0)
    #expect(result.applying(to: previous.files).files == expected)
    #expect(result.unreadableDirectories == ["blocked"])
  }

  @Test func caseOnlyRenamesWithOldNameRequireFullWalk() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path + "/project"
    try rescanMakeDirectory(root)
    let caseSensitivity = root.withCString { pathconf($0, _PC_CASE_SENSITIVE) }
    #expect(caseSensitivity == 0 || caseSensitivity == 1)
    guard caseSensitivity == 0 else {
      #expect(caseSensitivity == 1, "case-only rename checks require a case-insensitive volume")
      return
    }
    for (oldPath, newPath, isDirectory) in [
      ("readme.md", "README.md", false),
      ("Sources", "sources", true),
    ] {
      let originalPath = isDirectory ? oldPath + "/main.swift" : oldPath
      try rescanWriteFile("before", at: "\(root)/\(originalPath)")
      try rescanRename("\(root)/\(oldPath)", "\(root)/\(newPath)")

      var pathSets = [[oldPath], [oldPath, newPath]]
      if isDirectory {
        pathSets.append([oldPath + "/main.swift"])
        pathSets.append([oldPath + "/main.swift", newPath + "/main.swift"])
      }
      for paths in pathSets {
        guard case nil = try Scanner.rescan(root: root, paths: paths) else {
          Issue.record("expected a full rescan for rename \(oldPath) to \(newPath), paths \(paths)")
          continue
        }
      }
    }
  }

  @Test func caseOnlyRenamedUnreadableFolderRequiresFullWalk() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path + "/project"
    try rescanWriteFile("before", at: "\(root)/Blocked/x")
    guard root.withCString({ pathconf($0, _PC_CASE_SENSITIVE) }) == 0 else { return }
    try rescanRename("\(root)/Blocked", "\(root)/blocked")
    guard chmod("\(root)/blocked", 0) == 0 else {
      throw SystemError(operation: "chmod", path: "\(root)/blocked", code: errno)
    }
    defer { _ = chmod("\(root)/blocked", 0o700) }

    #expect(try Scanner.rescan(root: root, paths: ["Blocked/x"]) == nil)
  }

  @Test func lowercaseCargoManifestDoesNotPruneTargetDuringRescan() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path + "/project"
    try rescanMakeDirectory("\(root)/target/debug")
    try rescanWriteFile("[package]\n", at: "\(root)/cargo.toml")
    try rescanWriteFile("binary", at: "\(root)/target/debug/app")
    let previous = try Scanner.scan(root: root)
    var mirror = Mirror()
    for (path, stat) in previous.files {
      mirror.update(path: path, version: .unstored(stat))
    }
    let recorder = Recorder(
      workspace: try Workspace.open(root: root, home: directory.path + "/home")
    ) { _, _ in nil }

    let delta = try #require(try Scanner.rescan(root: root, paths: ["target/debug/app"]))
    let complete = try Scanner.scan(root: root)
    let expected = changedPathsBetween(previous.files, complete.files)

    #expect(delta.applying(to: previous.files).files == complete.files)
    #expect(recorder.changedPaths(delta: delta, mirror: mirror) == expected)
  }

  @Test func unreadableFolderReplacingTrackedFileIsAChange() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path + "/project"
    try rescanWriteFile("before", at: "\(root)/x")
    let previous = try Scanner.scan(root: root)
    let oldStat = try #require(previous.files["x"])
    var mirror = Mirror()
    mirror.update(path: "x", version: .unstored(oldStat))
    let recorder = Recorder(
      workspace: try Workspace.open(root: root, home: directory.path + "/home")
    ) { _, _ in nil }
    try rescanUnlink("\(root)/x")
    try rescanMakeDirectory("\(root)/x")
    guard chmod("\(root)/x", 0) == 0 else {
      throw SystemError(operation: "chmod", path: "\(root)/x", code: errno)
    }
    defer { _ = chmod("\(root)/x", 0o700) }

    let delta = try #require(try Scanner.rescan(root: root, paths: ["x"]))
    let complete = try Scanner.scan(root: root)
    let expected = changedPathsBetween(previous.files, complete.files)

    #expect(delta.applying(to: previous.files).files == complete.files)
    #expect(recorder.changedPaths(delta: delta, mirror: mirror) == expected)
    #expect(expected == ["x"])
  }

  @Test func unreadableNestedFolderReplacingTrackedFileIsAChange() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path + "/project"
    try rescanWriteFile("before", at: "\(root)/parent/x")
    let previous = try Scanner.scan(root: root)
    let oldStat = try #require(previous.files["parent/x"])
    var mirror = Mirror()
    mirror.update(path: "parent", version: .directory(mode: try fileMode(root + "/parent")))
    mirror.update(path: "parent/x", version: .unstored(oldStat))
    let recorder = Recorder(
      workspace: try Workspace.open(root: root, home: directory.path + "/home")
    ) { _, _ in nil }
    try rescanUnlink("\(root)/parent/x")
    try rescanMakeDirectory("\(root)/parent/x")
    guard chmod("\(root)/parent/x", 0) == 0 else {
      throw SystemError(operation: "chmod", path: "\(root)/parent/x", code: errno)
    }
    defer { _ = chmod("\(root)/parent/x", 0o700) }

    let delta = try #require(try Scanner.rescan(root: root, paths: ["parent"]))
    let complete = try Scanner.scan(root: root)
    let expected = changedPathsBetween(previous.files, complete.files)

    #expect(delta.applying(to: previous.files).files == complete.files)
    #expect(recorder.changedPaths(delta: delta, mirror: mirror) == expected)
    #expect(expected == ["parent/x"])
  }

  @Test func pathBelowSymlinkedAncestorIsAbsent() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    try rescanWriteFile("before", at: "\(root)/ancestor/file.txt")
    let previous = try Scanner.scan(root: root).files
    _ = try rescanRemoveTree("\(root)/ancestor")
    try rescanMakeDirectory("\(root)/outside")
    try rescanWriteFile("outside", at: "\(root)/outside/file.txt")
    try rescanMakeSymlink(target: "\(root)/outside", at: "\(root)/ancestor")

    let rescan = try Scanner.rescan(root: root, paths: ["ancestor/file.txt"])
    let result = try #require(rescan)
    let applied = result.applying(to: previous)

    #expect(!applied.files.keys.contains { $0.hasPrefix("ancestor/") })
  }

  @Test func seededMutationsRescanToTheSameFilesAsAFullWalk() throws {
    let baseSeed: UInt64 = 0xA6D3_7B91_52E4_C80F

    for iteration in 0..<200 {
      let seed = baseSeed &+ UInt64(iteration)
      var generator = SplitMix64(state: seed)
      let directory = try TemporaryDirectory()
      let root = directory.path
      try makeRandomWorkspace(root: root, generator: &generator)
      let previous = try Scanner.scan(root: root).files
      var touched = Set<String>()

      let parents = [
        "src", "src/deep", "ignored-dir/deep", "node_modules/pkg", "target/debug",
        "nested/target/debug",
      ]
      let createParent = parents[generator.index(upperBound: parents.count)]
      let createdPath = "\(createParent)/created-\(generator.next()).txt"
      try rescanWriteFile(randomContents(generator: &generator), at: "\(root)/\(createdPath)")
      touched.insert(createdPath)

      try rescanWriteFile(
        randomContents(generator: &generator, minimumSize: 17),
        at: "\(root)/src/deep/modify.txt")
      touched.insert("src/deep/modify.txt")

      try rescanUnlink("\(root)/src/deep/delete.txt")
      touched.insert("src/deep/delete.txt")

      touched.formUnion(try rescanRemoveTree("\(root)/remove-me"))

      let oldFile = "\(root)/src/rename-source.txt"
      let newFilePath = "src/renamed-\(iteration).txt"
      try rescanRename(oldFile, "\(root)/\(newFilePath)")
      touched.insert("src/rename-source.txt")
      touched.insert(newFilePath)

      let oldDirectory = "\(root)/rename-me"
      let newDirectoryPath = "renamed-directory-\(iteration)"
      try rescanRename(oldDirectory, "\(root)/\(newDirectoryPath)")
      touched.insert("rename-me")
      touched.insert(newDirectoryPath)

      touched.formUnion(try rescanRemoveTree("\(root)/dir-to-file"))
      try rescanWriteFile(randomContents(generator: &generator), at: "\(root)/dir-to-file")
      touched.insert("dir-to-file")

      try rescanUnlink("\(root)/file-to-dir")
      try rescanMakeDirectory("\(root)/file-to-dir")
      try rescanWriteFile(
        randomContents(generator: &generator), at: "\(root)/file-to-dir/child.txt")
      touched.insert("file-to-dir")
      touched.insert("file-to-dir/child.txt")

      touched.formUnion(try rescanRemoveTree("\(root)/dir-to-link"))
      try rescanMakeSymlink(
        target: "\(root)/external-target", at: "\(root)/dir-to-link")
      touched.insert("dir-to-link")

      let rescan = try Scanner.rescan(root: root, paths: touched.sorted())
      let delta = try #require(rescan, "seed \(seed), iteration \(iteration)")
      let incremental = delta.applying(to: previous)
      let complete = try Scanner.scan(root: root)
      #expect(
        incremental.files == complete.files,
        "seed \(seed), iteration \(iteration), paths \(touched.sorted())")
    }
  }
}

private func changedPathsBetween(
  _ previous: [String: StatKey],
  _ current: [String: StatKey]
) -> [String] {
  var paths = Set<String>()
  for path in previous.keys where previous[path] != current[path] {
    paths.insert(path)
  }
  for path in current.keys where current[path] != previous[path] {
    paths.insert(path)
  }
  return paths.sorted()
}

private struct SplitMix64 {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }

  mutating func index(upperBound: Int) -> Int {
    Int(next() % UInt64(upperBound))
  }
}

private func makeRandomWorkspace(root: String, generator: inout SplitMix64) throws {
  let directories = [
    ".git/info", "src/deep/generated", "src/build", "ignored-dir/deep", "node_modules/pkg",
    "target/debug", "nested/target/debug", "remove-me/deep", "rename-me/deep",
    "dir-to-file/deep", "dir-to-link/deep", "external-target",
  ]
  for path in directories {
    try rescanMakeDirectory("\(root)/\(path)")
  }

  try rescanWriteFile(
    "ignored-dir/\n*.log\n!important.log\n/src/deep/generated/\n", at: "\(root)/.gitignore")
  try rescanWriteFile("*.tmp\n!keep.tmp\nbuild/\n", at: "\(root)/src/.gitignore")
  try rescanWriteFile("excluded.txt\n", at: "\(root)/.git/info/exclude")
  if generator.next() & 1 == 0 { try rescanWriteFile("[package]\n", at: "\(root)/Cargo.toml") }
  if generator.next() & 1 == 0 {
    try rescanWriteFile("[package]\n", at: "\(root)/nested/Cargo.toml")
  } else {
    try rescanMakeDirectory("\(root)/nested")
  }

  let files = [
    "important.log", "ordinary.log", "excluded.txt", "src/deep/modify.txt",
    "src/deep/delete.txt", "src/rename-source.txt", "src/keep.tmp", "src/local.tmp",
    "src/build/ignored.txt", "src/deep/generated/bundle.js", "ignored-dir/ordinary.txt",
    "ignored-dir/.env.secret", "ignored-dir/deep/.env.local", "ignored-dir/deep/plain.txt",
    "node_modules/pkg/index.js", "target/debug/app", "nested/target/debug/app",
    "remove-me/deep/old.txt", "rename-me/deep/move.txt", "dir-to-file/deep/old.txt",
    "dir-to-link/deep/old.txt", "file-to-dir",
    "external-target/outside.txt",
  ]
  for path in files {
    try rescanWriteFile(randomContents(generator: &generator), at: "\(root)/\(path)")
  }
  try rescanWriteFile("initial", at: "\(root)/src/deep/modify.txt")
  let randomDirectoryCount = 1 + generator.index(upperBound: 4)
  for index in 0..<randomDirectoryCount {
    let name = "tree-\(index)-\(generator.next() % 1_000)"
    let base = "\(root)/\(name)"
    try rescanMakeDirectory("\(base)/deep")
    try rescanMakeDirectory("\(base)/ignored/deep")
    try rescanWriteFile("*.tmp\n!keep.tmp\nignored/\n", at: "\(base)/.gitignore")
    for path in [
      "deep/file-\(generator.next()).txt", "deep/ignored.tmp", "deep/keep.tmp",
      "ignored/plain.txt", "ignored/.env.local", "ignored/deep/nested.txt",
    ] {
      try rescanWriteFile(randomContents(generator: &generator), at: "\(base)/\(path)")
    }
  }
}

private func randomContents(generator: inout SplitMix64, minimumSize: Int = 1) -> String {
  let size = minimumSize + Int(generator.next() % 37)
  let character = Character(UnicodeScalar(97 + Int(generator.next() % 26)) ?? "x")
  return String(repeating: character, count: size)
}

private func rescanMakeDirectory(_ path: String) throws(SystemError) {
  try makeDirectories(path)
}

private func rescanWriteFile(_ contents: String, at path: String) throws(SystemError) {
  let parent = FileSystem.parent(of: path)
  try makeDirectories(parent)
  try writeFile(Array(contents.utf8), to: path)
}

private func rescanMakeSymlink(target: String, at path: String) throws(SystemError) {
  guard target.withCString({ source in path.withCString { symlink(source, $0) } }) == 0 else {
    throw SystemError(operation: "symlink", path: path, code: errno)
  }
}

private func rescanRename(_ old: String, _ new: String) throws(SystemError) {
  guard old.withCString({ source in new.withCString { rename(source, $0) } }) == 0 else {
    throw SystemError(operation: "rename", path: old, code: errno)
  }
}

private func rescanUnlink(_ path: String) throws(SystemError) {
  guard path.withCString({ unlink($0) }) == 0 else {
    throw SystemError(operation: "unlink", path: path, code: errno)
  }
}

private func rescanRemoveTree(_ path: String) throws(SystemError) -> [String] {
  let items = try rescanListTree(path)
  for item in items.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count })
  {
    let absolute = "\(path)/\(item)"
    var metadata = stat()
    guard absolute.withCString({ lstat($0, &metadata) }) == 0 else {
      throw SystemError(operation: "lstat", path: absolute, code: errno)
    }
    let removed = absolute.withCString {
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) ? rmdir($0) : unlink($0)
    }
    guard removed == 0 else {
      throw SystemError(operation: "remove", path: absolute, code: errno)
    }
  }
  var metadata = stat()
  guard path.withCString({ lstat($0, &metadata) }) == 0 else {
    throw SystemError(operation: "lstat", path: path, code: errno)
  }
  let removed = path.withCString {
    metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) ? rmdir($0) : unlink($0)
  }
  guard removed == 0 else { throw SystemError(operation: "remove", path: path, code: errno) }
  return [
    path.split(separator: "/").last.map(String.init)
      ?? path.split(separator: "/").joined(separator: "/")
  ]
    + items.map { "\(path.split(separator: "/").last.map(String.init) ?? "")/\($0)" }
}

private func rescanListTree(_ path: String) throws(SystemError) -> [String] {
  guard let directory = path.withCString({ opendir($0) }) else {
    throw SystemError(operation: "opendir", path: path, code: errno)
  }
  defer { _ = closedir(directory) }
  var result: [String] = []
  while let entry = readdir(directory) {
    let name = withUnsafeBytes(of: entry.pointee.d_name) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }
    if name == "." || name == ".." { continue }
    result.append(name)
    let child = "\(path)/\(name)"
    var metadata = stat()
    guard child.withCString({ lstat($0, &metadata) }) == 0 else {
      throw SystemError(operation: "lstat", path: child, code: errno)
    }
    if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
      result.append(contentsOf: try rescanListTree(child).map { "\(name)/\($0)" })
    }
  }
  return result
}
