import CommonCrypto
import Darwin

/// Shared Darwin file helpers. Every failure carries the operation, path, and errno.
enum FileSystem {
  /// Creates `path` and its missing parents with `mode`. Existing directories are kept as they are;
  /// an existing component may be a symlink to a directory, as `/tmp` is.
  static func makeDirectories(_ path: String, mode: mode_t) throws(SystemError) {
    guard path.hasPrefix("/") else {
      throw SystemError(operation: "mkdir", path: path, code: EINVAL)
    }
    var current = ""
    for component in path.split(separator: "/") {
      current += "/" + component
      if current.withCString({ mkdir($0, mode) }) == 0 { continue }
      let code = errno
      guard code == EEXIST else { throw SystemError(operation: "mkdir", path: current, code: code) }
      var info = stat()
      guard current.withCString({ stat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        throw SystemError(operation: "mkdir", path: current, code: ENOTDIR)
      }
    }
  }

  /// Returns `nil` when the path does not exist.
  static func lstatIfPresent(_ path: String) throws(SystemError) -> stat? {
    var info = stat()
    if path.withCString({ lstat($0, &info) }) == 0 { return info }
    let code = errno
    if code == ENOENT || code == ENOTDIR { return nil }
    throw SystemError(operation: "lstat", path: path, code: code)
  }

  /// Splits at every `/` byte, as the kernel does, keeping empty components. Splitting by
  /// Character keeps a slash that combines with the next scalar inside a component.
  static func pathComponents(_ path: String) -> [String] {
    path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
      .map { String(decoding: $0, as: UTF8.self) }
  }

  /// Whether `path` is `root` or below it, compared by bytes for the same reason.
  static func isWithin(_ path: String, root: String) -> Bool {
    path.utf8.elementsEqual(root.utf8)
      || path.utf8.starts(with: (root == "/" ? "/" : root + "/").utf8)
  }

  /// Opens the directory containing `relativeComponents.last` without following any descendant
  /// symlinks. The returned descriptor belongs to the caller.
  static func openParent(anchor: String, relativeComponents: [String], create: Bool)
    throws(SystemError)
    -> (dirfd: Int32, name: String)
  {
    guard anchor.hasPrefix("/"),
      let name = relativeComponents.last,
      relativeComponents.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(UInt8(ascii: "/"))
          && !$0.utf8.contains(0)
      })
    else {
      throw SystemError(operation: "open", path: anchor, code: EINVAL)
    }

    let relativePath = relativeComponents.joined(separator: "/")
    let path = anchor == "/" ? anchor + relativePath : anchor + "/" + relativePath
    let descriptor = anchor.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw SystemError(operation: "open", path: anchor, code: errno)
    }

    var current = descriptor
    for component in relativeComponents.dropLast() {
      let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      var next = component.withCString { openat(current, $0, flags) }
      if next < 0 {
        let openCode = errno
        if openCode == ENOENT && create {
          let made = component.withCString { mkdirat(current, $0, 0o755) }
          if made != 0 {
            let makeCode = errno
            guard makeCode == EEXIST else {
              _ = close(current)
              throw SystemError(operation: "mkdirat", path: path, code: makeCode)
            }
          }
          next = component.withCString { openat(current, $0, flags) }
        } else {
          _ = close(current)
          throw SystemError(operation: "openat", path: path, code: openCode)
        }
      }
      guard next >= 0 else {
        let code = errno
        _ = close(current)
        throw SystemError(operation: "openat", path: path, code: code)
      }
      _ = close(current)
      current = next
    }
    return (current, name)
  }

  static func storedName(_ name: String, in directory: Int32) -> [UInt8]? {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.reserved = 0
    attributes.commonattr = UInt32(ATTR_CMN_NAME)
    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1024) { buffer -> [UInt8]? in
      guard let baseAddress = buffer.baseAddress else { return nil }
      let status = name.withCString {
        getattrlistat(
          directory, $0, &attributes, baseAddress, buffer.count, UInt(FSOPT_NOFOLLOW))
      }
      let rawBuffer = UnsafeRawBufferPointer(start: baseAddress, count: buffer.count)
      let referenceOffset = MemoryLayout<UInt32>.size
      guard status == 0, rawBuffer.count >= referenceOffset else { return nil }
      let rawBaseAddress = UnsafeRawPointer(baseAddress)
      let lengthValue = rawBaseAddress.loadUnaligned(as: UInt32.self)
      let returnedLength = Int(lengthValue)
      guard returnedLength >= referenceOffset + MemoryLayout<attrreference_t>.size,
        returnedLength <= buffer.count
      else { return nil }
      let reference = rawBaseAddress.advanced(by: referenceOffset)
        .loadUnaligned(as: attrreference_t.self)
      let dataOffset = Int(reference.attr_dataoffset)
      let nameLength = Int(reference.attr_length)
      guard dataOffset >= 0 else { return nil }
      let nameStart = referenceOffset + dataOffset
      guard nameStart <= returnedLength,
        nameLength > 0, nameLength <= returnedLength - nameStart
      else { return nil }
      let nameBytes = UnsafeBufferPointer(
        start: baseAddress.advanced(by: nameStart), count: nameLength)
      guard nameBytes.last == 0 else { return nil }
      return Array(nameBytes.dropLast())
    }
  }

  static func readFile(_ path: String) throws(SystemError) -> [UInt8] {
    let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw SystemError(operation: "open", path: path, code: errno) }
    defer { _ = close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw SystemError(operation: "fstat", path: path, code: errno)
    }
    // One spare byte: the read that returns 0 confirms the end without growing the buffer.
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
    var count = 0
    while true {
      if count == bytes.count { bytes.append(contentsOf: repeatElement(0, count: count)) }
      let amount = bytes.withUnsafeMutableBytes { buffer in
        read(descriptor, buffer.baseAddress?.advanced(by: count), buffer.count - count)
      }
      if amount < 0 && errno == EINTR { continue }
      guard amount >= 0 else { throw SystemError(operation: "read", path: path, code: errno) }
      if amount == 0 { break }
      count += amount
    }
    bytes.removeSubrange(count...)
    return bytes
  }

  /// Writes through a private temporary file in the same folder, then renames it over `path`.
  /// With `durable`, the file and its folder are flushed before this returns.
  static func writeAtomically(_ bytes: [UInt8], to path: String, mode: mode_t, durable: Bool)
    throws(SystemError)
  {
    let folder = parent(of: path)
    let (temporary, descriptor) = try createTemporaryFile(in: folder)
    var isOpen = true
    var committed = false
    defer {
      if isOpen { _ = close(descriptor) }
      if !committed { _ = temporary.withCString { unlink($0) } }
    }
    guard fchmod(descriptor, mode) == 0 else {
      throw SystemError(operation: "fchmod", path: temporary, code: errno)
    }
    try writeAll(descriptor, bytes, path: temporary)
    if durable, fsync(descriptor) != 0 {
      throw SystemError(operation: "fsync", path: temporary, code: errno)
    }
    isOpen = false
    guard close(descriptor) == 0 else {
      throw SystemError(operation: "close", path: temporary, code: errno)
    }
    let renamed = temporary.withCString { source in path.withCString { rename(source, $0) } }
    guard renamed == 0 else { throw SystemError(operation: "rename", path: path, code: errno) }
    committed = true
    if durable { try syncDirectory(folder) }
  }

  /// Creates an empty `0600` file with a random name in `folder`, opened for writing.
  static func createTemporaryFile(in folder: String) throws(SystemError) -> (
    path: String, descriptor: Int32
  ) {
    for _ in 0..<16 {
      let candidate = folder + "/" + temporaryName()
      let descriptor = candidate.withCString {
        open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      }
      if descriptor >= 0 { return (candidate, descriptor) }
      let code = errno
      guard code == EEXIST else {
        throw SystemError(operation: "open", path: candidate, code: code)
      }
    }
    throw SystemError(operation: "open", path: folder, code: EEXIST)
  }

  private static let temporaryPrefix = ".undoturn-"

  /// A random name for a temporary file or link, which `removeTemporaryFiles` recognizes.
  static func temporaryName() -> String {
    temporaryPrefix + randomHex(byteCount: 8)
  }

  /// Removes the temporary files and links that a killed process left in `directory`.
  static func removeTemporaryFiles(in directory: Int32, path: String) throws(SystemError) {
    let duplicate = dup(directory)
    guard duplicate >= 0 else { throw SystemError(operation: "dup", path: path, code: errno) }
    guard let stream = fdopendir(duplicate) else {
      let code = errno
      _ = close(duplicate)
      throw SystemError(operation: "fdopendir", path: path, code: code)
    }
    defer { _ = closedir(stream) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        let code = errno
        guard code == 0 else { throw SystemError(operation: "readdir", path: path, code: code) }
        break
      }
      let type = Int32(entry.pointee.d_type)
      let name = withUnsafeBytes(of: entry.pointee.d_name) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      if (type == DT_REG || type == DT_LNK) && isTemporaryName(name) { names.append(name) }
    }
    for name in names where unlinkat(directory, name, 0) != 0 {
      let code = errno
      guard code == ENOENT else {
        throw SystemError(operation: "unlinkat", path: path + "/" + name, code: code)
      }
    }
  }

  private static func isTemporaryName(_ name: String) -> Bool {
    let digits = name.utf8.dropFirst(temporaryPrefix.utf8.count)
    return name.utf8.starts(with: temporaryPrefix.utf8) && digits.count == 16
      && digits.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  /// The version of the symbolic link `name` in `directory`, or nil when `name` is absent or is
  /// not a link. `directory` can be `AT_FDCWD` with an absolute `name`.
  static func linkVersion(at directory: Int32, name: String, path: String) throws(SystemError)
    -> FileVersion?
  {
    var before = stat()
    guard name.withCString({ fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0 else {
      let code = errno
      if code == ENOENT || code == ENOTDIR { return nil }
      throw SystemError(operation: "fstatat", path: path, code: code)
    }
    guard before.st_mode & S_IFMT == S_IFLNK else { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(before.st_size) + 1)
    let count = name.withCString { readlinkat(directory, $0, &buffer, buffer.count) }
    guard count >= 0 else {
      throw SystemError(operation: "readlinkat", path: path, code: errno)
    }
    // A link never changes in place, so the same key before and after proves the target.
    var after = stat()
    guard name.withCString({ fstatat(directory, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
      StatKey(after) == StatKey(before), count < buffer.count
    else {
      throw SystemError(operation: "readlinkat", path: path, code: EBUSY)
    }
    let bytes = buffer[..<count]
    let target = String(decoding: bytes, as: UTF8.self)
    guard target.utf8.elementsEqual(bytes) else { return .unstored(StatKey(before)) }
    return .link(target, StatKey(before))
  }

  /// Replaces `name` in `directory` with a symbolic link to `target`, through a temporary name
  /// in the same folder.
  static func replaceWithLink(_ target: String, at directory: Int32, name: String, path: String)
    throws(SystemError) -> StatKey
  {
    let parent = FileSystem.parent(of: path)
    var temporary: String?
    for _ in 0..<16 where temporary == nil {
      let candidate = temporaryName()
      guard symlinkat(target, directory, candidate) != 0 else {
        temporary = candidate
        continue
      }
      let code = errno
      guard code == EEXIST else {
        throw SystemError(operation: "symlinkat", path: parent + "/" + candidate, code: code)
      }
    }
    guard let temporary else {
      throw SystemError(operation: "symlinkat", path: parent, code: EEXIST)
    }
    guard renameat(directory, temporary, directory, name) == 0 else {
      let code = errno
      _ = unlinkat(directory, temporary, 0)
      throw SystemError(operation: "renameat", path: path, code: code)
    }
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw SystemError(operation: "fstatat", path: path, code: errno)
    }
    return StatKey(info)
  }

  static func writeAll(_ descriptor: Int32, _ bytes: [UInt8], path: String) throws(SystemError) {
    var offset = 0
    while offset < bytes.count {
      let amount = bytes.withUnsafeBytes { buffer in
        write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
      }
      if amount < 0 && errno == EINTR { continue }
      guard amount > 0 else {
        throw SystemError(operation: "write", path: path, code: amount < 0 ? errno : EIO)
      }
      offset += amount
    }
  }

  /// Flushes a folder so that renames and unlinks inside it survive a crash.
  static func syncDirectory(_ path: String) throws(SystemError) {
    let descriptor = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw SystemError(operation: "open", path: path, code: errno) }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw SystemError(operation: "fsync", path: path, code: errno)
    }
  }

  static func parent(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "." }
    return slash == path.startIndex ? "/" : String(path[..<slash])
  }

  static func randomHex(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
    return hex(bytes)
  }

  static func sha256Hex(_ bytes: [UInt8]) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    bytes.withUnsafeBytes { input in
      digest.withUnsafeMutableBytes { output in
        _ = CC_SHA256(
          input.baseAddress, CC_LONG(input.count),
          output.baseAddress?.assumingMemoryBound(to: UInt8.self))
      }
    }
    return hex(digest)
  }

  static func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      output.append(digits[Int(byte >> 4)])
      output.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: output, as: UTF8.self)
  }

  /// Resolves symlinks and `..`; the path must exist.
  static func realPath(_ path: String) throws(SystemError) -> String {
    guard let resolved = realpath(path, nil) else {
      throw SystemError(operation: "realpath", path: path, code: errno)
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

extension StatKey {
  init(_ info: stat) {
    self.init(
      device: Int64(info.st_dev),
      inode: UInt64(info.st_ino),
      size: Int64(info.st_size),
      modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
      mode: UInt16(info.st_mode & 0o7777)
    )
  }
}
