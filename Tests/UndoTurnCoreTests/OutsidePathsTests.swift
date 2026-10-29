import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct OutsidePathsTests {
  @Test func mvAndFileOperationsCollectOutsidePathsAndRedirections() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(
      "mv notes.txt ../other/; rm -rf ../other/build; cp a.txt ~/other/b.txt; echo x > ../out.log; echo y >> ../append.log; echo z 2>&1; echo z >&2; cat < ../other/in.txt",
      cwd: tree.root, filter: tree.filter)

    #expect(
      result.paths == [
        "\(tree.other)/notes.txt", "\(tree.other)/build", "\(tree.home)/other/b.txt",
        "\(tree.home)/out.log", "\(tree.home)/append.log",
      ])
    #expect(result.unresolved == 0)
    #expect(result.refused.isEmpty)
  }

  @Test func quotedWordsAndDynamicSyntaxAreHandled() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(
      "rm '../other/a b.txt'; rm \"../other/c d.txt\"; rm ../other/e\\ f.txt; rm \"$HOME/x\"; rm $(pwd)/../x; rm `pwd`/x; rm '$HOME'",
      cwd: tree.root, filter: tree.filter)

    #expect(
      result.paths == [
        "\(tree.other)/a b.txt", "\(tree.other)/c d.txt", "\(tree.other)/e f.txt",
      ])
    #expect(result.unresolved == 3)
  }

  @Test func cdAndSubshellBasesAreScoped() throws(SystemError) {
    let tree = try OutsidePathTree()
    let changed = OutsidePaths.shell(
      "cd ../other && rm f.txt", cwd: tree.root, filter: tree.filter)
    let subshell = OutsidePaths.shell(
      "(cd ../other && touch g) ; rm h", cwd: tree.root, filter: tree.filter)

    #expect(changed.paths == ["\(tree.other)/f.txt"])
    #expect(subshell.paths == ["\(tree.other)/g"])
  }

  @Test func globsExpandInSortedOrderAndUnmatchedPatternsStayLiteral() throws(SystemError) {
    let tree = try OutsidePathTree()
    let matched = OutsidePaths.shell(
      "rm ../other/*.log", cwd: tree.root, filter: tree.filter)
    let unmatched = OutsidePaths.shell(
      "rm ../other/no-match-*.txt", cwd: tree.root, filter: tree.filter)

    #expect(matched.paths == ["\(tree.other)/a.log", "\(tree.other)/b.log"])
    #expect(unmatched.paths == ["\(tree.other)/no-match-*.txt"])
  }

  @Test func refusedAndDroppedPathsAreSeparated() throws(SystemError) {
    let tree = try OutsidePathTree()
    let refused = OutsidePaths.shell(
      "rm -rf ..; rm -rf ~; rm -rf /", cwd: tree.root, filter: tree.filter)
    let dropped = OutsidePaths.shell(
      "rm -rf .; rm -rf ../store/file; rm /usr/bin/x; rm /dev/null",
      cwd: tree.root, filter: tree.filter)

    #expect(refused.paths.isEmpty)
    #expect(refused.refused == [tree.home, "/"])
    #expect(dropped.paths.isEmpty)
    #expect(dropped.refused.isEmpty)
  }

  @Test func wrappersAndReservedWordsFindCommands() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(
      "sudo rm ../other/x; FOO=1 env BAR=2 rm ../other/y; if true; then rm ../other/z; fi",
      cwd: tree.root, filter: tree.filter)

    #expect(
      result.paths == ["\(tree.other)/x", "\(tree.other)/y", "\(tree.other)/z"])
  }

  @Test func allOutputRedirectionFormsExcludeInputsAndDuplicates() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(
      "echo 1 &> ../other/both.out; echo 2 &>> ../other/both-append.out; echo 3 2> ../other/fd.out; echo 4 2>> ../other/fd-append.out; echo 5 2>&1; echo 6 >&2; echo 7 >| ../other/clobber.out; cat <<< ../other/data; cat < ../other/input; > ../other/only-redirection.out",
      cwd: tree.root, filter: tree.filter)

    #expect(
      result.paths == [
        "\(tree.other)/both.out", "\(tree.other)/both-append.out", "\(tree.other)/fd.out",
        "\(tree.other)/fd-append.out", "\(tree.other)/clobber.out",
        "\(tree.other)/only-redirection.out",
      ])
  }

  @Test func processSubstitutionsAndBracedVariablesAreUnresolved() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(
      "rm <(echo ../other/hidden); rm >(cat); rm ${HOME}/x; rm \"\\$HOME\"; rm '$HOME'",
      cwd: tree.root, filter: tree.filter)

    #expect(result.paths.isEmpty)
    #expect(result.unresolved == 3)
  }

  @Test func cdWithoutKnownBaseAndOptionsAreHandled() throws(SystemError) {
    let tree = try OutsidePathTree()
    let unknown = OutsidePaths.shell(
      "cd - && rm bare", cwd: tree.root, filter: tree.filter)
    let changed = OutsidePaths.shell(
      "cd -- ../other && rm f", cwd: tree.root, filter: tree.filter)
    let options = OutsidePaths.shell(
      """
      rm ../other/a # ../other/commented
      """, cwd: tree.root, filter: tree.filter)
    let optionArguments = OutsidePaths.shell(
      "rm -- ../other/-option; tool -o=../other/out.txt", cwd: tree.root, filter: tree.filter)

    #expect(unknown.paths.isEmpty)
    #expect(unknown.unresolved == 1)
    #expect(changed.paths == ["\(tree.other)/f"])
    #expect(
      options.paths + optionArguments.paths == [
        "\(tree.other)/a", "\(tree.other)/-option", "\(tree.other)/out.txt",
      ])
  }

  @Test func directoryMovesIncludeSourceAndDestinationButStayDeduplicated() throws(SystemError) {
    let tree = try OutsidePathTree()
    let destination = "\(tree.other)/destination"
    try makeDirectory(destination)
    let result = OutsidePaths.shell(
      "mv ../other/a.log ../other/destination/; mv ../other/a.log ../other/destination",
      cwd: tree.root, filter: tree.filter)
    let singleArgument = OutsidePaths.shell(
      "mv ../other/destination", cwd: tree.root, filter: tree.filter)

    #expect(result.paths == ["\(destination)/a.log", "\(tree.other)/a.log"])
    #expect(singleArgument.paths == [destination])
  }

  @Test func pathPrefixChecksUseWholeComponents() throws(SystemError) {
    let tree = try OutsidePathTree()
    let sibling = OutsidePaths.file(
      "\(tree.home)/proj-sibling/file", cwd: tree.root, filter: tree.filter)
    let outsideStore = OutsidePaths.file(
      "\(tree.home)/store-next/file", cwd: tree.root, filter: tree.filter)

    #expect(sibling.paths == ["\(tree.home)/proj-sibling/file"])
    #expect(outsideStore.paths == ["\(tree.home)/store-next/file"])
  }

  @Test func heredocBodiesAreSkipped() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(
      "cat > ../other/gen.txt <<'EOF'\n../other/notapath\nEOF\nrm ../other/after",
      cwd: tree.root, filter: tree.filter)

    #expect(result.paths == ["\(tree.other)/gen.txt", "\(tree.other)/after"])
  }

  @Test func realParentResolutionPreservesSymlinkCandidates() throws(SystemError) {
    let tree = try OutsidePathTree()
    let link = "\(tree.home)/link"
    guard link.withCString({ symlink(tree.other, $0) }) == 0 else {
      throw SystemError(operation: "symlink", path: link, code: errno)
    }
    let child = OutsidePaths.shell(
      "rm ~/link/x", cwd: tree.root, filter: tree.filter)
    let linkItself = OutsidePaths.shell(
      "rm ~/link", cwd: tree.root, filter: tree.filter)

    #expect(child.paths == ["\(tree.other)/x"])
    #expect(linkItself.paths == [link])
  }

  @Test func optionsAndPatchHeadersAreDerived() throws(SystemError) {
    let tree = try OutsidePathTree()
    let shell = OutsidePaths.shell(
      "sed -i '' s/a/b/ ../other/f; tool --output=../other/o.txt",
      cwd: tree.root, filter: tree.filter)
    let patch = OutsidePaths.patch(
      "*** Begin Patch\n*** Add File: ../other/new file.txt   \r\n*** Update File: inside.txt\n*** Delete File: /usr/bin/x\n*** Move to: \(tree.other)/moved.txt\n*** End Patch",
      cwd: tree.root, filter: tree.filter)

    #expect(shell.paths == ["\(tree.other)/f", "\(tree.other)/o.txt"])
    #expect(
      patch.paths == ["\(tree.other)/new file.txt", "\(tree.other)/moved.txt"])
  }

  @Test func readingCommandsLeaveScansAndPatternsOut() throws(SystemError) {
    let tree = try OutsidePathTree()
    // Longer than a file name may be: as a candidate, its lstat failed with ENAMETOOLONG.
    let pattern = String(repeating: "alpha\\|beta\\|", count: 24)
    let result = OutsidePaths.shell(
      """
      cd ~/other && grep -rn '\(pattern)' . 2>/dev/null | head -n 20
      rg -n -e 'a|b' -g '*.log' ~/other | sort | uniq -c >/dev/null
      ls -la ..; du -sh ~ ~/other; [ -d ~/other ] && echo ~/other/*.log
      find .. -name '*.log' -type f | wc -l; sed -n '1,20p' a.log b.log
      cat a.log | jq . | tail -n 1
      """, cwd: tree.root, filter: tree.filter)

    #expect(result.paths.isEmpty)
    #expect(result.unresolved == 0)
    #expect(result.refused.isEmpty)
  }

  // What a scan prints reaches a command left unparsed: through a file a later command may read,
  // an expansion running a command on the same input, or a reading command's name redefined.
  @Test(arguments: [
    "find ../other/target -type f > ../other/list; xargs -a ../other/list rm",
    "find ../other/target -type f | sort | tee ../other/list",
    "find ../other/target -type f -print0 | tee >(xargs -0 rm) >/dev/null",
    "find ../other/target -type f | cat <(xargs rm)",
    "find ../other/target -type f | echo $(xargs rm)",
    "cat() { /bin/rm \"$@\"; }; cat ../other/target",
    "function cat { /bin/rm \"$@\"; }\ncat ../other/target",
    "alias grep='rm -r'\ngrep -r x ../other/target",
  ])
  func scansReachingUnparsedCommandsKeepTheirOperands(_ command: String) throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(command, cwd: tree.root, filter: tree.filter)

    #expect(result.paths.contains("\(tree.other)/target"))
  }

  // The Recorder walks candidates in order within one entry budget.
  @Test func writtenPathsComeBeforeOperandsKeptForScanOutput() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(
      "grep -rn x ../other/target | head -n 1 > ../other/out; rm ../other/old",
      cwd: tree.root, filter: tree.filter)

    #expect(
      result.paths == ["\(tree.other)/out", "\(tree.other)/old", "\(tree.other)/target"])
  }

  @Test(arguments: [
    "find ../other/target -name '*.tmp' -delete",
    "find ../other/target -exec rm {} +",
    "fd . ../other/target -X rm",
    "rg --pre cat pattern ../other/target",
    "sed -i '' 's/a/b/' ../other/target",
    "sed 's/a/b/w /dev/stdout' ../other/target",
    "sed -n \"$lines\" ../other/target",
    "sort -o ../other/target input",
    "uniq input ../other/target",
    "grep -rn x . >& ../other/target",
    "uniq - ../other/target",
    "sort data | uniq - ../other/target",
  ])
  func writingFormsOfReadingCommandsKeepTheirOperands(_ command: String) throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(command, cwd: tree.root, filter: tree.filter)

    #expect(result.paths == ["\(tree.other)/target"])
  }

  // The variable stands where a command name would, and is named like a reading command.
  @Test func forLoopWordsStayCandidatesWhateverTheVariableName() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(
      "for test in ../other/*.log; do sed -i '' 's/a/b/' \"$test\"; done",
      cwd: tree.root, filter: tree.filter)

    #expect(result.paths == ["\(tree.other)/a.log", "\(tree.other)/b.log"])
    #expect(result.unresolved == 1)
  }

  @Test func scansFeedingCommandsThatActOnTheirInputKeepTheirOperands() throws(SystemError) {
    let tree = try OutsidePathTree()
    let xargs = OutsidePaths.shell(
      "find ../other -name '*.log' -print0 |& xargs -0 rm", cwd: tree.root, filter: tree.filter)
    let loop = OutsidePaths.shell(
      "ls ../other/a.log | while read f; do rm \"$f\"; done", cwd: tree.root, filter: tree.filter)
    let group = OutsidePaths.shell(
      "{ grep -l a ../other/b.log; } | xargs rm", cwd: tree.root, filter: tree.filter)
    let readers = OutsidePaths.shell(
      "find ../other -name '*.log' | grep log |\n  head -n 1", cwd: tree.root, filter: tree.filter)
    let listed = OutsidePaths.shell(
      "grep -l a ../other/*.log > ../other/list; xargs rm < ../other/list",
      cwd: tree.root, filter: tree.filter)

    #expect(xargs.paths == [tree.other])
    #expect(loop.paths == ["\(tree.other)/a.log"])
    #expect(loop.unresolved == 1)
    #expect(group.paths == ["\(tree.other)/b.log"])
    #expect(readers.paths.isEmpty)
    #expect(listed.paths == ["\(tree.other)/list", "\(tree.other)/a.log", "\(tree.other)/b.log"])
  }

  @Test func dynamicWordsOfReadingCommandsStayUnresolved() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.shell(
      "grep -rn a $(pwd)/.. `pwd`; cat <(rm -rf ../other)", cwd: tree.root, filter: tree.filter)

    #expect(result.paths.isEmpty)
    #expect(result.unresolved == 3)
  }

  @Test func lineContinuationsAndEmptyArgumentsNameNoFile() throws(SystemError) {
    let tree = try OutsidePathTree()
    let continued = OutsidePaths.shell(
      "cd ../other && LC_ALL=C \\\n  mv a.log \\\n  b.log \\\n  2> out.txt",
      cwd: tree.root, filter: tree.filter)
    // BSD sed takes its in-place backup suffix as a separate argument, empty for none.
    let empty = OutsidePaths.shell(
      "cd ../other && sed -i '' '/^#/d' a.log", cwd: tree.root, filter: tree.filter)

    #expect(
      continued.paths == [
        "\(tree.other)/a.log", "\(tree.other)/b.log", "\(tree.other)/out.txt",
      ])
    #expect(empty.paths == ["\(tree.other)/a.log"])
  }

  @Test func tooLongNamesAreNoCandidatesButLongValidNamesStay() throws(SystemError) {
    let tree = try OutsidePathTree()
    // Inline code is an operand of a command UndoTurn does not know: 300 ASCII bytes, longer
    // than any name a macOS file system accepts. As a candidate, its lstat failed.
    let code = "import sys; print(" + String(repeating: "1+", count: 140) + "1)"
    // 150 "é" take 300 bytes but 150 UTF-16 units, a name APFS accepts.
    let longName = String(repeating: "\u{E9}", count: 150)
    let result = OutsidePaths.shell(
      "cd ../other && python3 -c '\(code)' && touch '\(longName)'",
      cwd: tree.root, filter: tree.filter)

    #expect(result.paths == ["\(tree.other)/\(longName)"])
  }

  @Test func fileCandidatesAreNormalizedAndFiltered() throws(SystemError) {
    let tree = try OutsidePathTree()
    let outside = OutsidePaths.file(
      "\(tree.other)/nested/../absolute.txt", cwd: tree.root, filter: tree.filter)
    let inside = OutsidePaths.file("notes.txt", cwd: tree.root, filter: tree.filter)

    #expect(outside.paths == ["\(tree.other)/absolute.txt"])
    #expect(inside.paths.isEmpty)
  }

  @Test func fileListsShareFilteringAndDeduplication() throws(SystemError) {
    let tree = try OutsidePathTree()
    let result = OutsidePaths.files(
      ["../other/a.log", "\(tree.other)/a.log", "notes.txt", "..", "../other/new.txt", ".."],
      cwd: tree.root, filter: tree.filter)

    #expect(result.paths == ["\(tree.other)/a.log", "\(tree.other)/new.txt"])
    #expect(result.refused == [tree.home])
  }

  @Test func miscasedUndoTurnHomeLeafIsExcludedOnCaseInsensitiveVolumes() throws(SystemError) {
    let tree = try OutsidePathTree()
    let caseSensitive = tree.home.withCString { pathconf($0, _PC_CASE_SENSITIVE) }
    guard caseSensitive == 0 else { return }

    let result = OutsidePaths.file(
      tree.home + "/STORE", cwd: tree.root, filter: tree.filter)

    #expect(result.paths.isEmpty)
  }

  @Test func miscasedProjectAncestorIsRefusedOnCaseInsensitiveVolumes() throws(SystemError) {
    let tree = try OutsidePathTree()
    let caseSensitive = tree.home.withCString { pathconf($0, _PC_CASE_SENSITIVE) }
    guard caseSensitive == 0 else { return }
    try makeDirectory(tree.root + "/nested")
    let filter = OutsidePathFilter(
      root: tree.root + "/nested", home: tree.home, undoTurnHome: tree.store,
      allowedPrefixes: tree.filter.allowedPrefixes)

    let result = OutsidePaths.file(
      tree.home + "/PROJ", cwd: tree.root, filter: filter)

    #expect(result.paths.isEmpty)
    #expect(result.refused == [tree.root])
  }

}

private struct OutsidePathTree: ~Copyable {
  let home: String
  let root: String
  let other: String
  let store: String
  let filter: OutsidePathFilter

  init() throws(SystemError) {
    guard let temporaryDirectory = getenv("TMPDIR") else {
      throw SystemError(operation: "getenv", path: "TMPDIR", code: ENOENT)
    }
    let temporaryPath = String(
      decoding: UnsafeBufferPointer(start: temporaryDirectory, count: strlen(temporaryDirectory))
        .map { UInt8(bitPattern: $0) },
      as: UTF8.self)
    var template = Array("\(temporaryPath)/undoturn-outside.XXXXXX".utf8CString)
    let created: UnsafeMutablePointer<CChar>? =
      template.withUnsafeMutableBufferPointer({ buffer -> UnsafeMutablePointer<CChar>? in
        guard let baseAddress = buffer.baseAddress else { return nil }
        return mkdtemp(baseAddress)
      })
    guard created != nil else {
      throw SystemError(operation: "mkdtemp", path: temporaryPath, code: errno)
    }
    let resolved: UnsafeMutablePointer<CChar>? =
      template.withUnsafeBufferPointer({ buffer -> UnsafeMutablePointer<CChar>? in
        guard let baseAddress = buffer.baseAddress else { return nil }
        return realpath(baseAddress, nil)
      })
    guard let resolved else {
      throw SystemError(operation: "realpath", path: temporaryPath, code: errno)
    }
    defer { free(resolved) }
    let resolvedLength = strlen(resolved)
    let homePath = String(
      decoding: UnsafeBufferPointer(start: resolved, count: resolvedLength).map {
        UInt8(bitPattern: $0)
      },
      as: UTF8.self)
    let rootPath = "\(homePath)/proj"
    let otherPath = "\(homePath)/other"
    let storePath = "\(homePath)/store"
    var retainTemporaryDirectory = false
    defer {
      if !retainTemporaryDirectory {
        _ = nftw(
          homePath, { entry, _, _, _ in entry.map { Darwin.remove($0) } ?? -1 }, 16,
          FTW_DEPTH | FTW_PHYS)
      }
    }

    try makeDirectory(rootPath)
    try makeDirectory(otherPath)
    try makeDirectory(storePath)
    try makeFile("notes", at: "\(rootPath)/notes.txt")
    try makeFile("a", at: "\(rootPath)/a.txt")
    try makeFile("a", at: "\(otherPath)/a.log")
    try makeFile("b", at: "\(otherPath)/b.log")
    home = homePath
    root = rootPath
    other = otherPath
    store = storePath
    filter = OutsidePathFilter(
      root: rootPath, home: homePath, undoTurnHome: storePath, allowedPrefixes: [homePath])
    retainTemporaryDirectory = true
  }

  deinit {
    _ = nftw(
      home, { entry, _, _, _ in entry.map { Darwin.remove($0) } ?? -1 }, 16, FTW_DEPTH | FTW_PHYS)
  }
}

private func makeDirectory(_ path: String) throws(SystemError) {
  guard path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
    throw SystemError(operation: "mkdir", path: path, code: errno)
  }
}

private func makeFile(_ contents: String, at path: String) throws(SystemError) {
  let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600)) }
  guard descriptor >= 0 else {
    throw SystemError(operation: "open", path: path, code: errno)
  }
  defer { _ = close(descriptor) }
  let count = contents.withCString { Darwin.write(descriptor, $0, strlen($0)) }
  guard count == contents.utf8.count else {
    throw SystemError(operation: "write", path: path, code: errno)
  }
}
