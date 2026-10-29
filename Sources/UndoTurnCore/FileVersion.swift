/// Change-detection key from `lstat`. Two equal keys mean the bytes did not change.
public struct StatKey: Hashable, Sendable {
  public var device: Int64
  public var inode: UInt64
  public var size: Int64
  /// Modification time in nanoseconds since 1970.
  public var modified: Int64
  /// Permission bits (`st_mode & 0o7777`).
  public var mode: UInt16

  public init(device: Int64, inode: UInt64, size: Int64, modified: Int64, mode: UInt16) {
    self.device = device
    self.inode = inode
    self.size = size
    self.modified = modified
    self.mode = mode
  }

  /// The key of a folder holds only its permission bits, so adding or removing a child does not
  /// change it. A regular file never has inode 0, so this key never equals a file's key.
  public static func directory(mode: UInt16) -> StatKey {
    StatKey(device: 0, inode: 0, size: 0, modified: 0, mode: mode)
  }
}

/// Name of one object in the store.
public struct ObjectID: Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

/// One version of a path as recorded in history and in the mirror.
public enum FileVersion: Hashable, Sendable {
  case absent
  /// Bytes are in the store under `ObjectID`. `StatKey` describes the file they were copied from.
  case stored(ObjectID, StatKey)
  /// Bytes were seen but not kept, for example because the file is over the size limit.
  case unstored(StatKey)
  /// A symbolic link and its target. A target that is not UTF-8 is recorded as `unstored`.
  case link(String, StatKey)
  /// A folder and its permission bits. Its children are separate paths.
  case directory(mode: UInt16)
}

/// A failed system call, with the `errno` it set.
public struct SystemError: Error, Equatable, Sendable {
  public let operation: String
  public let path: String
  public let code: Int32

  public init(operation: String, path: String, code: Int32) {
    self.operation = operation
    self.path = path
    self.code = code
  }
}
