import CommonCrypto
import Darwin

/// A stored object and its byte count, for garbage-collection inventory.
public struct StoredObject: Equatable, Sendable {
  public let id: ObjectID
  public let size: Int64

  public init(id: ObjectID, size: Int64) {
    self.id = id
    self.size = size
  }
}

public enum ObjectStoreError: Error, Equatable, Sendable {
  case system(SystemError)
  case invalidPath(String)
  case invalidObjectID(ObjectID)
  case invalidSizeLimit(Int64)
  case notRegularFile(String)
  case sourceChanged(path: String)
  case hashFailure(path: String)
}

/// Stores immutable file versions as clones, falling back to byte copies across volumes.
public struct ObjectStore: Sendable {
  public static let defaultSizeLimit: Int64 = 50 * 1024 * 1024

  private let directory: String
  private let sizeLimit: Int64
  private let cloneOperation: @Sendable (String, String) -> Int32

  public init(directory: String, sizeLimit: Int64 = Self.defaultSizeLimit) throws(ObjectStoreError)
  {
    try self.init(directory: directory, sizeLimit: sizeLimit, cloneOperation: Self.clone)
  }

  init(
    directory: String,
    sizeLimit: Int64,
    cloneOperation: @escaping @Sendable (String, String) -> Int32
  ) throws(ObjectStoreError) {
    guard sizeLimit >= 0 else { throw .invalidSizeLimit(sizeLimit) }
    guard directory.hasPrefix("/"), directory != "/" else { throw .invalidPath(directory) }
    try ensureDirectory(directory, mode: 0o700)
    guard chmodPath(directory, mode: 0o700) == 0 else {
      throw systemError("chmod", directory)
    }
    self.directory = directory
    self.sizeLimit = sizeLimit
    self.cloneOperation = cloneOperation
  }

  /// Stores the bytes described by `stat`, or returns `.unstored` above the configured size limit.
  public func store(path: String, stat expected: StatKey) throws(ObjectStoreError) -> FileVersion {
    guard path.hasPrefix("/") else { throw .invalidPath(path) }
    let before = try regularFileStat(path)
    guard StatKey(before) == expected else { throw .sourceChanged(path: path) }
    guard before.st_size <= sizeLimit else { return .unstored(expected) }

    let id = try uniqueObjectID()
    let destination = objectPath(id)
    var ownsDestination = false
    defer {
      if ownsDestination { _ = unlinkPath(destination) }
    }

    let cloneResult = cloneOperation(path, destination)
    if cloneResult == 0 {
      ownsDestination = true
      guard chmodPath(destination, mode: 0o600) == 0 else {
        throw systemError("chmod", destination)
      }
    } else {
      let cloneError = errno
      guard cloneError == EXDEV || cloneError == ENOTSUP else {
        throw .system(SystemError(operation: "clonefile", path: path, code: cloneError))
      }
      try copyFile(path, to: destination, expected: expected)
      ownsDestination = true
    }

    let after = try regularFileStat(path)
    guard StatKey(after) == expected else { throw .sourceChanged(path: path) }
    let objectInfo = try regularFileStat(destination)
    guard objectInfo.st_size == expected.size else { throw .sourceChanged(path: path) }
    ownsDestination = false
    return .stored(id, expected)
  }

  func store(
    parentDescriptor: Int32,
    name: String,
    path: String,
    stat expected: StatKey
  ) throws(ObjectStoreError) -> FileVersion {
    guard path.hasPrefix("/"), isValidComponent(name) else { throw .invalidPath(path) }
    let before = try regularFileStat(parentDescriptor, name: name, path: path)
    guard StatKey(before) == expected else { throw .sourceChanged(path: path) }
    guard before.st_size <= sizeLimit else { return .unstored(expected) }

    let id = try uniqueObjectID()
    let destination = objectPath(id)
    var ownsDestination = false
    defer {
      if ownsDestination { _ = unlinkPath(destination) }
    }
    let cloneResult = name.withCString { source in
      destination.withCString { target in
        Darwin.clonefileat(
          parentDescriptor, source, AT_FDCWD, target, UInt32(CLONE_NOFOLLOW))
      }
    }
    if cloneResult == 0 {
      ownsDestination = true
      guard chmodPath(destination, mode: 0o600) == 0 else {
        throw systemError("chmod", destination)
      }
    } else {
      let cloneError = errno
      guard cloneError == EXDEV || cloneError == ENOTSUP else {
        if cloneError == ELOOP || cloneError == ENOENT {
          throw .sourceChanged(path: path)
        }
        throw .system(SystemError(operation: "clonefileat", path: path, code: cloneError))
      }
      try copyFile(
        parentDescriptor: parentDescriptor,
        name: name,
        path: path,
        to: destination,
        expected: expected
      )
      ownsDestination = true
    }

    let after = try regularFileStat(parentDescriptor, name: name, path: path)
    guard StatKey(after) == expected else { throw .sourceChanged(path: path) }
    let objectInfo = try regularFileStat(destination)
    guard objectInfo.st_size == expected.size else { throw .sourceChanged(path: path) }
    ownsDestination = false
    return .stored(id, expected)
  }

  /// Atomically replaces `path` with the object bytes and returns the resulting stat key.
  @discardableResult
  public func restore(_ id: ObjectID, to path: String, mode: UInt16) throws(ObjectStoreError)
    -> StatKey
  {
    guard path.hasPrefix("/"), path.last != "/", let parent = parentDirectory(of: path),
      let finalComponent = path.split(separator: "/", omittingEmptySubsequences: true).last
    else {
      throw .invalidPath(path)
    }
    try ensureDirectory(parent, mode: 0o755)
    let parentDescriptor = parent.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }
    guard parentDescriptor >= 0 else { throw systemError("open", parent) }
    defer { _ = close(parentDescriptor) }
    return try restore(
      id,
      in: parentDescriptor,
      name: String(finalComponent),
      path: path,
      mode: mode
    )
  }

  @discardableResult
  func restore(
    _ id: ObjectID,
    in parentDescriptor: Int32,
    name: String,
    path: String,
    mode: UInt16
  ) throws(ObjectStoreError) -> StatKey {
    guard path.hasPrefix("/"), isValidComponent(name) else { throw .invalidPath(path) }
    let sourcePath = try objectPath(for: id)
    let sourceDescriptor = try openRegularFile(sourcePath)
    defer { _ = close(sourceDescriptor) }
    let sourceBefore = try descriptorStat(sourceDescriptor, path: sourcePath)

    let parent = FileSystem.parent(of: path)
    let (temporaryName, destinationDescriptor) =
      try createTemporaryFile(in: parentDescriptor, directory: parent)
    let temporaryPath = parent == "/" ? "/" + temporaryName : parent + "/" + temporaryName
    var temporaryIsOpen = true
    var committed = false
    defer {
      if temporaryIsOpen { _ = close(destinationDescriptor) }
      if !committed { _ = unlinkAt(parentDescriptor, temporaryName) }
    }

    try copyDescriptors(sourceDescriptor, to: destinationDescriptor, path: sourcePath)
    let sourceAfter = try descriptorStat(sourceDescriptor, path: sourcePath)
    guard StatKey(sourceAfter) == StatKey(sourceBefore) else {
      throw .sourceChanged(path: sourcePath)
    }
    guard fchmod(destinationDescriptor, mode_t(mode)) == 0 else {
      throw systemError("fchmod", temporaryPath)
    }
    guard fsync(destinationDescriptor) == 0 else { throw systemError("fsync", temporaryPath) }
    guard close(destinationDescriptor) == 0 else {
      temporaryIsOpen = false
      throw systemError("close", temporaryPath)
    }
    temporaryIsOpen = false
    guard renameAt(parentDescriptor, temporaryName, parentDescriptor, name) == 0 else {
      throw systemError("renameat", path)
    }
    committed = true
    return StatKey(try regularFileStat(parentDescriptor, name: name, path: path))
  }

  /// Removes an object. Removing an already absent object is harmless.
  public func remove(_ id: ObjectID) throws(ObjectStoreError) {
    let path = try objectPath(for: id)
    guard unlinkPath(path) != 0 else { return }
    let code = errno
    if code != ENOENT { throw .system(SystemError(operation: "unlink", path: path, code: code)) }
  }

  /// Returns whether a regular object with this ID exists.
  public func contains(_ id: ObjectID) throws(ObjectStoreError) -> Bool {
    let path = try objectPath(for: id)
    var info = stat()
    let result = path.withCString { Darwin.lstat($0, &info) }
    if result == 0 { return isRegularFile(info.st_mode) }
    let code = errno
    if code == ENOENT { return false }
    throw .system(SystemError(operation: "lstat", path: path, code: code))
  }

  /// Lists regular objects and their sizes, sorted by ID.
  public func enumerate() throws(ObjectStoreError) -> [StoredObject] {
    guard let stream = directory.withCString({ opendir($0) }) else {
      throw systemError("opendir", directory)
    }
    defer { _ = closedir(stream) }
    var result: [StoredObject] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        let code = errno
        if code != 0 {
          throw .system(SystemError(operation: "readdir", path: directory, code: code))
        }
        break
      }
      let nameCapacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
      let name = withUnsafePointer(to: entry.pointee.d_name) { namePointer in
        namePointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
          String(cString: $0)
        }
      }
      let id = ObjectID(rawValue: name)
      guard isValidObjectID(id) else { continue }
      let path = objectPath(id)
      var info = stat()
      let statResult = path.withCString { Darwin.lstat($0, &info) }
      if statResult != 0 {
        let code = errno
        if code == ENOENT { continue }
        throw .system(SystemError(operation: "lstat", path: path, code: code))
      }
      guard isRegularFile(info.st_mode) else { continue }
      result.append(StoredObject(id: id, size: Int64(info.st_size)))
    }
    result.sort { $0.id.rawValue < $1.id.rawValue }
    return result
  }

  /// Computes the SHA-256 digest of a stored object.
  public func contentHash(of id: ObjectID) throws(ObjectStoreError) -> ContentID {
    let path = try objectPath(for: id)
    let descriptor = try openRegularFile(path)
    defer { _ = close(descriptor) }
    return try contentHash(descriptor: descriptor, path: path)
  }

  /// Computes the SHA-256 digest of a regular file without retaining it in the store.
  public func contentHash(ofFile path: String) throws(ObjectStoreError) -> ContentID {
    guard path.hasPrefix("/") else { throw .invalidPath(path) }
    let descriptor = try openRegularFile(path)
    defer { _ = close(descriptor) }
    return try contentHash(descriptor: descriptor, path: path)
  }

  func contentHash(ofFile parentDescriptor: Int32, name: String, path: String)
    throws(ObjectStoreError) -> ContentID
  {
    guard path.hasPrefix("/"), isValidComponent(name) else { throw .invalidPath(path) }
    let descriptor = try openRegularFile(parentDescriptor, name: name, path: path)
    defer { _ = close(descriptor) }
    return try contentHash(descriptor: descriptor, path: path)
  }

  /// The bytes of a stored object.
  public func contents(of id: ObjectID) throws(ObjectStoreError) -> [UInt8] {
    let path = try objectPath(for: id)
    do {
      return try FileSystem.readFile(path)
    } catch let error {
      throw .system(error)
    }
  }

  private func uniqueObjectID() throws(ObjectStoreError) -> ObjectID {
    for _ in 0..<16 {
      let id = ObjectID(rawValue: FileSystem.randomHex(byteCount: 16))
      let path = objectPath(id)
      var info = stat()
      if path.withCString({ Darwin.lstat($0, &info) }) == 0 { continue }
      let code = errno
      if code == ENOENT { return id }
      throw .system(SystemError(operation: "lstat", path: path, code: code))
    }
    throw .system(SystemError(operation: "create", path: directory, code: EEXIST))
  }

  private func objectPath(_ id: ObjectID) -> String {
    directory.hasSuffix("/") ? directory + id.rawValue : directory + "/" + id.rawValue
  }

  private func objectPath(for id: ObjectID) throws(ObjectStoreError) -> String {
    guard isValidObjectID(id) else { throw .invalidObjectID(id) }
    return objectPath(id)
  }

  private func contentHash(descriptor: Int32, path: String) throws(ObjectStoreError) -> ContentID {
    let before = try descriptorStat(descriptor, path: path)
    var context = CC_SHA256_CTX()
    guard CC_SHA256_Init(&context) == 1 else { throw .hashFailure(path: path) }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
      }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw systemError("read", path) }
      if count == 0 { break }
      let updated = buffer.withUnsafeBytes { rawBuffer in
        CC_SHA256_Update(&context, rawBuffer.baseAddress, CC_LONG(count))
      }
      guard updated == 1 else { throw .hashFailure(path: path) }
    }
    let after = try descriptorStat(descriptor, path: path)
    guard StatKey(after) == StatKey(before) else { throw .sourceChanged(path: path) }

    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    let finalized = digest.withUnsafeMutableBufferPointer { buffer in
      CC_SHA256_Final(buffer.baseAddress, &context)
    }
    guard finalized == 1 else { throw .hashFailure(path: path) }
    return ContentID(FileSystem.hex(digest))
  }

  private static func clone(_ source: String, _ destination: String) -> Int32 {
    source.withCString { sourcePointer in
      destination.withCString { destinationPointer in
        Darwin.clonefile(sourcePointer, destinationPointer, UInt32(CLONE_NOFOLLOW))
      }
    }
  }
}

private func regularFileStat(_ path: String) throws(ObjectStoreError) -> stat {
  var info = stat()
  let result = path.withCString { Darwin.lstat($0, &info) }
  guard result == 0 else { throw systemError("lstat", path) }
  guard isRegularFile(info.st_mode) else { throw .notRegularFile(path) }
  return info
}

private func regularFileStat(_ parentDescriptor: Int32, name: String, path: String)
  throws(ObjectStoreError) -> stat
{
  var info = stat()
  let result = name.withCString {
    fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
  }
  guard result == 0 else {
    let code = errno
    if code == ENOENT { throw .sourceChanged(path: path) }
    throw .system(SystemError(operation: "fstatat", path: path, code: code))
  }
  guard isRegularFile(info.st_mode) else { throw .notRegularFile(path) }
  return info
}

private func descriptorStat(_ descriptor: Int32, path: String) throws(ObjectStoreError) -> stat {
  var info = stat()
  guard fstat(descriptor, &info) == 0 else { throw systemError("fstat", path) }
  guard isRegularFile(info.st_mode) else { throw .notRegularFile(path) }
  return info
}

private func openRegularFile(_ path: String) throws(ObjectStoreError) -> Int32 {
  let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
  guard descriptor >= 0 else { throw systemError("open", path) }
  do {
    _ = try descriptorStat(descriptor, path: path)
    return descriptor
  } catch {
    _ = close(descriptor)
    throw error
  }
}

private func openRegularFile(_ parentDescriptor: Int32, name: String, path: String)
  throws(ObjectStoreError) -> Int32
{
  let descriptor = name.withCString {
    openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  }
  guard descriptor >= 0 else {
    let code = errno
    if code == ELOOP || code == ENOENT { throw .sourceChanged(path: path) }
    throw .system(SystemError(operation: "openat", path: path, code: code))
  }
  do {
    _ = try descriptorStat(descriptor, path: path)
    return descriptor
  } catch {
    _ = close(descriptor)
    throw error
  }
}

private func copyFile(
  _ source: String,
  to destination: String,
  expected: StatKey
) throws(ObjectStoreError) {
  let sourceDescriptor = try openRegularFile(source)
  defer { _ = close(sourceDescriptor) }
  try copyDescriptorToObject(sourceDescriptor, source: source, to: destination, expected: expected)
}

private func copyFile(
  parentDescriptor: Int32,
  name: String,
  path: String,
  to destination: String,
  expected: StatKey
) throws(ObjectStoreError) {
  let sourceDescriptor = try openRegularFile(parentDescriptor, name: name, path: path)
  defer { _ = close(sourceDescriptor) }
  try copyDescriptorToObject(sourceDescriptor, source: path, to: destination, expected: expected)
}

private func copyDescriptorToObject(
  _ sourceDescriptor: Int32,
  source: String,
  to destination: String,
  expected: StatKey
) throws(ObjectStoreError) {
  let before = try descriptorStat(sourceDescriptor, path: source)
  guard StatKey(before) == expected else { throw .sourceChanged(path: source) }
  let destinationDescriptor = destination.withCString {
    open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
  }
  guard destinationDescriptor >= 0 else { throw systemError("open", destination) }
  var destinationIsOpen = true
  var complete = false
  defer {
    if destinationIsOpen { _ = close(destinationDescriptor) }
    if !complete { _ = unlinkPath(destination) }
  }

  try copyDescriptors(sourceDescriptor, to: destinationDescriptor, path: source)
  let after = try descriptorStat(sourceDescriptor, path: source)
  guard StatKey(after) == expected else { throw .sourceChanged(path: source) }
  guard fchmod(destinationDescriptor, 0o600) == 0 else {
    throw systemError("fchmod", destination)
  }
  guard fsync(destinationDescriptor) == 0 else { throw systemError("fsync", destination) }
  guard close(destinationDescriptor) == 0 else {
    destinationIsOpen = false
    throw systemError("close", destination)
  }
  destinationIsOpen = false
  complete = true
}

private func copyDescriptors(_ source: Int32, to destination: Int32, path: String)
  throws(ObjectStoreError)
{
  var buffer = [UInt8](repeating: 0, count: 64 * 1024)
  while true {
    let count = buffer.withUnsafeMutableBytes { rawBuffer in
      Darwin.read(source, rawBuffer.baseAddress, rawBuffer.count)
    }
    if count < 0 && errno == EINTR { continue }
    guard count >= 0 else { throw systemError("read", path) }
    if count == 0 { return }
    var written = 0
    while written < count {
      let result = buffer.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return -1 }
        return Darwin.write(
          destination,
          baseAddress.advanced(by: written),
          count - written)
      }
      if result < 0 && errno == EINTR { continue }
      guard result > 0 else { throw systemError("write", path) }
      written += result
    }
  }
}

private func ensureDirectory(_ path: String, mode: mode_t) throws(ObjectStoreError) {
  guard path.hasPrefix("/"), path != "/" else { throw .invalidPath(path) }
  do {
    try FileSystem.makeDirectories(path, mode: mode)
  } catch let error {
    throw .system(error)
  }
}

private func createTemporaryFile(in directoryDescriptor: Int32, directory: String)
  throws(ObjectStoreError) -> (String, Int32)
{
  for _ in 0..<16 {
    let name = FileSystem.temporaryName()
    let descriptor = name.withCString {
      openat(
        directoryDescriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0o600)
    }
    if descriptor >= 0 { return (name, descriptor) }
    let code = errno
    guard code == EEXIST else {
      throw .system(SystemError(operation: "openat", path: directory + "/" + name, code: code))
    }
  }
  throw .system(SystemError(operation: "openat", path: directory, code: EEXIST))
}

private func isValidObjectID(_ id: ObjectID) -> Bool {
  let bytes = id.rawValue.utf8
  guard bytes.count == 32 else { return false }
  return bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func isRegularFile(_ mode: mode_t) -> Bool {
  (mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
}

private func parentDirectory(of path: String) -> String? {
  guard path.last != "/", let separator = path.lastIndex(of: "/") else { return nil }
  let parent = String(path[..<separator])
  return parent.isEmpty ? "/" : parent
}

private func isValidComponent(_ name: String) -> Bool {
  !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
}

private func chmodPath(_ path: String, mode: mode_t) -> Int32 {
  path.withCString { chmod($0, mode) }
}

private func unlinkPath(_ path: String) -> Int32 {
  path.withCString { unlink($0) }
}

private func unlinkAt(_ directoryDescriptor: Int32, _ name: String) -> Int32 {
  name.withCString { unlinkat(directoryDescriptor, $0, 0) }
}

private func renameAt(
  _ oldDirectory: Int32,
  _ oldName: String,
  _ newDirectory: Int32,
  _ newName: String
) -> Int32 {
  oldName.withCString { oldPointer in
    newName.withCString { newPointer in
      Darwin.renameat(oldDirectory, oldPointer, newDirectory, newPointer)
    }
  }
}

private func systemError(_ operation: String, _ path: String) -> ObjectStoreError {
  .system(SystemError(operation: operation, path: path, code: errno))
}
