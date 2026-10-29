import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct ScannerTests {
  @Test func scansNestedRegularFilesUsingWorkspaceRelativePaths() throws {
    let directory = try TemporaryDirectory()
    try makeDirectory(at: "\(directory.path)/nested/deeper")
    try writeFile("one.txt", at: "\(directory.path)/root.txt")
    try writeFile("two.txt", at: "\(directory.path)/nested/deeper/file.txt")

    let files = try Scanner.scan(root: directory.path).files

    #expect(
      files.keys.sorted() == ["nested", "nested/deeper", "nested/deeper/file.txt", "root.txt"])
  }

  @Test func skipsGitAndDependencyBuildDirectories() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    try makeDirectory(at: "\(root)/.git/info")
    try makeDirectory(at: "\(root)/node_modules/pkg")
    try makeDirectory(at: "\(root)/.build/checkouts")
    try makeDirectory(at: "\(root)/DerivedData/Build")
    try makeDirectory(at: "\(root)/Pods/library")
    try makeDirectory(at: "\(root)/target/debug")
    try makeDirectory(at: "\(root)/nested/target/debug")
    try makeDirectory(at: "\(root)/dist")
    try makeDirectory(at: "\(root)/build")
    try makeDirectory(at: "\(root)/plain/dist")
    try makeDirectory(at: "\(root)/plain/build")
    try writeFile("/dist/\n/build/\n", at: "\(root)/.gitignore")
    try writeFile("", at: "\(root)/Cargo.toml")
    try writeFile("secret", at: "\(root)/.git/config")
    try writeFile("secret", at: "\(root)/node_modules/pkg/index.js")
    try writeFile("secret", at: "\(root)/.build/checkouts/package.swift")
    try writeFile("secret", at: "\(root)/DerivedData/Build/app")
    try writeFile("secret", at: "\(root)/Pods/library/source.m")
    try writeFile("secret", at: "\(root)/target/debug/app")
    try writeFile("kept", at: "\(root)/nested/target/debug/kept")
    try writeFile("secret", at: "\(root)/dist/bundle.js")
    try writeFile("secret", at: "\(root)/build/output")
    try writeFile("kept", at: "\(root)/plain/build/kept")
    try writeFile("kept", at: "\(root)/plain/dist/kept")

    let files = try Scanner.scan(root: root).files

    #expect(
      files.keys.sorted() == [
        ".gitignore", "Cargo.toml", "nested", "nested/target", "nested/target/debug",
        "nested/target/debug/kept", "plain", "plain/build", "plain/build/kept", "plain/dist",
        "plain/dist/kept",
      ])
  }

  @Test func appliesGitignoreNegationAnchorsDirectoryOnlyDoubleStarAndNestedScopes() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    try makeDirectory(at: "\(root)/nested")
    try makeDirectory(at: "\(root)/dir-only/child")
    try makeDirectory(at: "\(root)/src/generated/deep")
    try writeFile(
      "*.log\n!important.log\n/root-only.txt\ndir-only/\n**/generated/**\n",
      at: "\(root)/.gitignore")
    try writeFile("!nested.log\nlocal.tmp\n", at: "\(root)/nested/.gitignore")
    try makeDirectory(at: "\(root)/.git/info")
    try writeFile("excluded.txt\n", at: "\(root)/.git/info/exclude")
    try writeFile("ignored", at: "\(root)/ignored.log")
    try writeFile("kept", at: "\(root)/important.log")
    try writeFile("ignored", at: "\(root)/root-only.txt")
    try writeFile("kept", at: "\(root)/nested/root-only.txt")
    try writeFile("ignored", at: "\(root)/dir-only/child/file.txt")
    try writeFile("kept", at: "\(root)/plain/dir-only")
    try writeFile("ignored", at: "\(root)/src/generated/deep/data.txt")
    try writeFile("kept", at: "\(root)/nested/nested.log")
    try writeFile("ignored", at: "\(root)/nested/local.tmp")
    try writeFile("kept", at: "\(root)/local.tmp")
    try writeFile("ignored", at: "\(root)/excluded.txt")

    let files = try Scanner.scan(root: root).files

    #expect(
      files.keys.sorted() == [
        ".gitignore", "important.log", "local.tmp", "nested", "nested/.gitignore",
        "nested/nested.log", "nested/root-only.txt", "plain", "plain/dir-only", "src",
      ])
  }
  @Test func invalidUTF8IgnoreFileDoesNotAbortAndValidPatternsStillApply() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    try FileSystem.writeAtomically(
      [0xFF, 0x0A] + Array("*.tmp\n".utf8), to: root + "/.gitignore", mode: 0o600,
      durable: false)
    try writeFile("ignored", at: root + "/file.tmp")
    try writeFile("kept", at: root + "/file.txt")

    #expect(try Scanner.scan(root: root).files.keys.sorted() == [".gitignore", "file.txt"])
  }

  @Test func environmentFilesAreKeptEvenWhenTheirFilesOrParentsAreIgnored() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    try makeDirectory(at: "\(root)/private")
    try writeFile("*\n", at: "\(root)/.gitignore")
    try writeFile("value", at: "\(root)/.env")
    try writeFile("value", at: "\(root)/.env.local")
    try writeFile("value", at: "\(root)/private/.env.secret")
    try writeFile("value", at: "\(root)/private/ordinary.txt")

    let files = try Scanner.scan(root: root).files

    #expect(files.keys.sorted() == [".env", ".env.local", "private/.env.secret"])
  }

  @Test func undoTurnIgnoreKeepsPathsOutOfScansAlsoEnvironmentFiles() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    try writeFile("secrets/\n.env.local\n", at: "\(root)/.undoturnignore")
    try writeFile("key", at: "\(root)/secrets/deploy.pem")
    try writeFile("key", at: "\(root)/.env.local")
    try writeFile("key", at: "\(root)/.env")

    let files = try Scanner.scan(root: root).files
    let delta = try Scanner.rescan(root: root, paths: ["secrets/deploy.pem", ".env.local", ".env"])
    let folderDelta = try Scanner.rescan(root: root, paths: ["secrets"])

    #expect(files.keys.sorted() == [".env", ".undoturnignore"])
    #expect(delta?.observedFiles.keys.sorted() == [".env"])
    #expect(folderDelta?.observedFiles.isEmpty == true)
  }

  @Test func recordsSymlinksWithoutFollowingThem() throws {
    let directory = try TemporaryDirectory()
    let external = try TemporaryDirectory()
    let root = directory.path
    try makeDirectory(at: "\(root)/real-dir")
    try writeFile("inside", at: "\(root)/real-dir/file.txt")
    try writeFile("outside", at: "\(external.path)/outside.txt")
    try makeSymlink(target: "\(root)/real-dir/file.txt", at: "\(root)/file-link")
    try makeSymlink(target: external.path, at: "\(root)/directory-link")

    let files = try Scanner.scan(root: root).files

    #expect(
      files.keys.sorted() == ["directory-link", "file-link", "real-dir", "real-dir/file.txt"])
    #expect(files["file-link"] == (try statKey("\(root)/file-link")))
    #expect(files["directory-link"] == (try statKey("\(root)/directory-link")))
  }

  @Test func recordsFoldersWithTheirModesButNotIgnoredFolders() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    try makeDirectory(at: "\(root)/empty/inner")
    try makeDirectory(at: "\(root)/build/output")
    try writeFile("build/\n", at: "\(root)/.gitignore")
    guard chmod("\(root)/empty/inner", 0o700) == 0 else {
      throw SystemError(operation: "chmod", path: "\(root)/empty/inner", code: errno)
    }

    let files = try Scanner.scan(root: root).files

    #expect(files.keys.sorted() == [".gitignore", "empty", "empty/inner"])
    #expect(files["empty/inner"] == StatKey.directory(mode: 0o700))
    #expect(files["empty"] == StatKey.directory(mode: try fileMode("\(root)/empty")))
  }

  @Test func unreadableDirectoryIsReportedAndItsContentIsLeftOut() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    let blocked = "\(root)/nested/blocked"
    try writeFile("secret", at: "\(blocked)/file.txt")
    try writeFile("kept", at: "\(root)/nested/kept.txt")
    guard chmod(blocked, 0) == 0 else {
      throw SystemError(operation: "chmod", path: blocked, code: errno)
    }
    defer { _ = chmod(blocked, 0o700) }

    let result = try Scanner.scan(root: root)

    #expect(result.files.keys.sorted() == ["nested", "nested/blocked", "nested/kept.txt"])
    #expect(result.unreadableDirectories == ["nested/blocked"])
  }

  @Test func statKeyMatchesLstatAndChangesAfterEditAndRenameReplacement() throws {
    let directory = try TemporaryDirectory()
    let root = directory.path
    let tracked = "\(root)/file.txt"
    try writeFile("before", at: tracked)
    let original = try #require(Scanner.scan(root: root).files["file.txt"])
    var metadata = stat()
    #expect(lstat(tracked, &metadata) == 0)
    #expect(
      original
        == StatKey(
          device: Int64(metadata.st_dev),
          inode: UInt64(metadata.st_ino),
          size: Int64(metadata.st_size),
          modified: Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(metadata.st_mtimespec.tv_nsec),
          mode: UInt16(metadata.st_mode & 0o7777)
        )
    )

    try writeFile("after edit", at: tracked)
    let edited = try #require(Scanner.scan(root: root).files["file.txt"])
    #expect(edited != original)

    try writeFile("replacement", at: "\(root)/replacement.txt")
    let renameResult = "\(root)/replacement.txt".withCString { source in
      tracked.withCString { destination in rename(source, destination) }
    }
    guard renameResult == 0 else {
      throw SystemError(operation: "rename", path: tracked, code: errno)
    }
    let replaced = try #require(Scanner.scan(root: root).files["file.txt"])
    #expect(replaced != edited)
  }
  @Test func vanishedChildDirectoryBetweenListingAndOpenIsAbsent() throws {
    let directory = try TemporaryDirectory()
    let external = try TemporaryDirectory()
    let root = directory.path
    try makeDirectory(at: root + "/vanishing")
    var replaced = false

    let result = try Scanner.scan(
      root: root,
      beforeOpeningDirectory: { path in
        guard path == "vanishing", !replaced else { return }
        let removed = (root + "/vanishing").withCString { rmdir($0) }
        let linked = external.path.withCString { target in
          (root + "/vanishing").withCString { symlink(target, $0) }
        }
        replaced = removed == 0 && linked == 0
      })

    #expect(replaced)
    #expect(result.files.keys.sorted() == ["vanishing"])
  }

  @Test func parallelScanMatchesSequentialScanAcrossSeededTrees() throws {
    let baseSeed: UInt64 = 0x71C3_58A2_0D4E_96BF

    for iteration in 0..<30 {
      let seed = baseSeed &+ UInt64(iteration)
      var generator = ScannerTestGenerator(state: seed)
      let directory = try TemporaryDirectory()
      let root = directory.path
      try makeParallelRandomTree(root: root, generator: &generator)

      let blocked = ["blocked-a", "branch-b/blocked"]
      defer {
        for path in blocked { _ = chmod("\(root)/\(path)", 0o755) }
      }
      for path in blocked {
        let absolute = "\(root)/\(path)"
        guard chmod(absolute, 0) == 0 else {
          throw SystemError(operation: "chmod", path: absolute, code: errno)
        }
      }

      let sequential = try Scanner.scan(root: root, threadCount: 1)
      let parallel = try Scanner.scan(root: root, threadCount: 4)

      #expect(parallel == sequential, "seed \(seed)")
      #expect(
        parallel.unreadableDirectories == parallel.unreadableDirectories.sorted(), "seed \(seed)")
    }
  }

  @Test func parallelScanDoesNotKeepDescriptorsForAllPendingDirectories() throws {
    let directory = try TemporaryDirectory()
    for index in 0..<320 {
      try makeDirectory(at: "\(directory.path)/folder-\(index)")
    }

    let result = try Scanner.scan(root: directory.path, threadCount: 4)

    #expect(result.files.count == 320)
  }

  @Test func parallelScanUsesAStackLargeEnoughForDeepTrees() throws {
    let directory = try TemporaryDirectory()
    for index in 0..<15 {
      try makeDirectory(at: "\(directory.path)/sibling-\(index)")
    }
    var path = "\(directory.path)/deep"
    try makeDirectory(at: path)
    for _ in 0..<220 {
      path += "/d"
      try makeDirectory(at: path)
    }

    let result = try Scanner.scan(root: directory.path, threadCount: 4)

    #expect(result.files.count == 15 + 221)
  }

}

private struct ScannerTestGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

private func makeParallelRandomTree(
  root: String,
  generator: inout ScannerTestGenerator
) throws(SystemError) {
  for path in [
    ".git/info", "node_modules/pkg", "target/debug", "branch-a/target/debug",
    "branch-b/target/debug", "blocked-a", "branch-b/blocked", "ignored-dir",
    "external-target", "branch-c/hidden",
  ] {
    try makeDirectory(at: "\(root)/\(path)")
  }
  var generatedLeaves: [String] = []
  for branch in 0..<3 {
    let middleCount = 2 + Int(generator.next() % 3)
    for middle in 0..<middleCount {
      let leafCount = 1 + Int(generator.next() % 3)
      for leaf in 0..<leafCount {
        let base = "branch-\(branch)/level-0-\(middle)/level-1-\(leaf)"
        generatedLeaves.append(base)
        try makeDirectory(at: "\(root)/\(base)/deep")
        if generator.next() & 1 == 0 {
          try makeDirectory(at: "\(root)/\(base)/extra-\(generator.next() % 3)")
        }
      }
    }
  }

  try writeFile(
    "*.log\n!important.log\n/anchored.txt\nignored-dir/\nbranch-c/hidden/\n",
    at: "\(root)/.gitignore")
  try writeFile("*.tmp\n!keep.tmp\nnested-ignore/\n", at: "\(root)/branch-a/.gitignore")
  try writeFile(
    "*.txt\n!nested-kept.txt\nnested-folder/\n", at: "\(root)/branch-a/level-0-1/.gitignore")
  try writeFile("", at: "\(root)/.git/info/exclude")
  if generator.next() & 1 == 0 { try writeFile("[package]\n", at: "\(root)/Cargo.toml") }
  if generator.next() & 1 == 0 {
    try writeFile("[package]\n", at: "\(root)/branch-a/Cargo.toml")
  }

  for path in [
    "root.log", "important.log", "anchored.txt", "branch-c/hidden/file.txt",
    "ignored-dir/ordinary.txt", "ignored-dir/.env.secret", "blocked-a/file.txt",
    "branch-b/blocked/file.txt", "target/debug/app", "branch-a/target/debug/app",
    "branch-b/target/debug/app", "node_modules/pkg/index.js", ".git/config",
    "external-target/outside.txt", "branch-a/ignored.tmp", "branch-a/keep.tmp",
    "branch-a/nested-ignore/file.txt", "branch-a/level-0-1/ignored.txt",
    "branch-a/level-0-1/nested-kept.txt", "branch-a/level-0-1/nested-folder/file.txt",
  ] {
    try writeFile("content-\(generator.next())", at: "\(root)/\(path)")
  }
  for base in generatedLeaves {
    let fileName = "file-\(generator.next() % 7).txt"
    try writeFile("content-\(generator.next())", at: "\(root)/\(base)/\(fileName)")
    try writeFile("content-\(generator.next())", at: "\(root)/\(base)/deep/file.tmp")
  }
  try makeSymlink(target: "\(root)/external-target", at: "\(root)/directory-link")
}

/// Creates `path` and any missing parents.
private func makeDirectory(at path: String) throws(SystemError) {
  try FileSystem.makeDirectories(path, mode: 0o755)
}

private func writeFile(_ contents: String, at path: String) throws(SystemError) {
  let parent = FileSystem.parent(of: path)
  try FileSystem.makeDirectories(parent, mode: 0o755)
  try FileSystem.writeAtomically(Array(contents.utf8), to: path, mode: 0o600, durable: false)
}

private func makeSymlink(target: String, at path: String) throws(SystemError) {
  guard
    target.withCString({ targetPointer in
      path.withCString { symlink(targetPointer, $0) }
    }) == 0
  else {
    throw SystemError(operation: "symlink", path: path, code: errno)
  }
}
