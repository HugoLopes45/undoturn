import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct ObjectStoreTests {
  @Test func storedBytesSurviveInPlaceOverwriteAndUsePrivateModes() throws {
    let temporary = try TemporaryDirectory()
    let source = temporary.path + "/source"
    let destination = temporary.path + "/restored"
    let original = Array("before overwrite".utf8)
    try writeFile(original, to: source)

    let store = try ObjectStore(directory: temporary.path + "/objects")
    let id: ObjectID
    guard case .stored(let storedID, _) = try store.store(path: source, stat: statKey(source))
    else {
      #expect(Bool(false))
      return
    }
    id = storedID

    try writeInPlace(source, bytes: Array("after overwrite!".utf8))
    _ = try store.restore(id, to: destination, mode: 0o600)
    #expect(try readFile(destination) == original)
    #expect(try fileMode(temporary.path + "/objects") == 0o700)
    #expect(try fileMode(temporary.path + "/objects/" + id.rawValue) == 0o600)
  }

  @Test func cloneFailureFallsBackToAPlainCopy() throws {
    let temporary = try TemporaryDirectory()
    let source = temporary.path + "/source"
    let destination = temporary.path + "/restored"
    let contents = Array("fallback bytes".utf8)
    try writeFile(contents, to: source)

    let store = try ObjectStore(
      directory: temporary.path + "/objects",
      sizeLimit: 1024,
      cloneOperation: { _, _ in
        errno = EXDEV
        return -1
      })
    guard case .stored(let id, _) = try store.store(path: source, stat: statKey(source)) else {
      #expect(Bool(false))
      return
    }

    _ = try store.restore(id, to: destination, mode: 0o640)
    #expect(try readFile(destination) == contents)
    #expect(try fileMode(temporary.path + "/objects/" + id.rawValue) == 0o600)
  }

  @Test func oversizedFileIsUnstoredWithoutCreatingAnObject() throws {
    let temporary = try TemporaryDirectory()
    let source = temporary.path + "/source"
    try writeFile(Array("12345".utf8), to: source)
    let store = try ObjectStore(directory: temporary.path + "/objects", sizeLimit: 4)

    #expect(try store.store(path: source, stat: statKey(source)) == .unstored(statKey(source)))
    #expect(try store.enumerate().isEmpty)
  }

  @Test func restoreCreatesParentsSetsModeAndIsIdempotent() throws {
    let temporary = try TemporaryDirectory()
    let source = temporary.path + "/source"
    let destination = temporary.path + "/one/two/restored"
    let contents = Array("restore me".utf8)
    try writeFile(contents, to: source)
    let store = try ObjectStore(directory: temporary.path + "/objects")
    guard case .stored(let id, _) = try store.store(path: source, stat: statKey(source)) else {
      #expect(Bool(false))
      return
    }

    let first = try store.restore(id, to: destination, mode: 0o640)
    let second = try store.restore(id, to: destination, mode: 0o640)
    #expect(try readFile(destination) == contents)
    #expect(try fileMode(destination) == 0o640)
    #expect(first.mode == 0o640)
    #expect(second.mode == 0o640)
    #expect(try directoryNames(temporary.path + "/one/two") == ["restored"])
  }

  @Test func contentHashesAreSha256AndEnumerationTracksRemoval() throws {
    let temporary = try TemporaryDirectory()
    let source = temporary.path + "/source"
    try writeFile(Array("abc".utf8), to: source)
    let store = try ObjectStore(directory: temporary.path + "/objects")
    guard case .stored(let id, _) = try store.store(path: source, stat: statKey(source)) else {
      #expect(Bool(false))
      return
    }
    let expected = ContentID("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    #expect(try store.contentHash(of: id) == expected)
    #expect(try store.contentHash(ofFile: source) == expected)
    #expect(try store.enumerate() == [StoredObject(id: id, size: 3)])
    #expect(try store.contains(id))
    try store.remove(id)
    #expect(try !store.contains(id))
    #expect(try store.enumerate().isEmpty)
  }

  @Test func changedSourceDoesNotGetStoredUnderAnOldStatKey() throws {
    let temporary = try TemporaryDirectory()
    let source = temporary.path + "/source"
    try writeFile(Array("before".utf8), to: source)
    let oldKey = try statKey(source)
    try writeInPlace(source, bytes: Array("after grew the file".utf8))
    let store = try ObjectStore(directory: temporary.path + "/objects")

    #expect(throws: ObjectStoreError.sourceChanged(path: source)) {
      try store.store(path: source, stat: oldKey)
    }
  }
  @Test func storeRejectsSymlinkSources() throws {
    let temporary = try TemporaryDirectory()
    let source = temporary.path + "/source"
    let link = temporary.path + "/source-link"
    try writeFile(Array("source".utf8), to: source)
    guard source.withCString({ target in link.withCString { Darwin.symlink(target, $0) } }) == 0
    else {
      throw SystemError(operation: "symlink", path: link, code: errno)
    }
    let store = try ObjectStore(directory: temporary.path + "/objects")

    #expect(throws: ObjectStoreError.notRegularFile(link)) {
      try store.store(path: link, stat: statKey(source))
    }
    #expect(try store.enumerate().isEmpty)
  }

}

/// Overwrites the start of an existing file without replacing its inode.
private func writeInPlace(_ path: String, bytes: [UInt8]) throws(SystemError) {
  let descriptor = path.withCString { open($0, O_WRONLY) }
  guard descriptor >= 0 else { throw SystemError(operation: "open", path: path, code: errno) }
  defer { _ = close(descriptor) }
  var offset = 0
  while offset < bytes.count {
    let result = bytes[offset...].withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    if result < 0 && errno == EINTR { continue }
    guard result > 0 else { throw SystemError(operation: "write", path: path, code: errno) }
    offset += result
  }
}

private func directoryNames(_ path: String) throws(SystemError) -> [String] {
  guard let directory = path.withCString({ opendir($0) }) else {
    throw SystemError(operation: "opendir", path: path, code: errno)
  }
  defer { _ = closedir(directory) }
  var names: [String] = []
  while let entry = readdir(directory) {
    let name = withUnsafePointer(to: entry.pointee.d_name) { namePointer in
      namePointer.withMemoryRebound(
        to: CChar.self,
        capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
      ) { String(cString: $0) }
    }
    if name != "." && name != ".." { names.append(name) }
  }
  return names.sorted()
}
