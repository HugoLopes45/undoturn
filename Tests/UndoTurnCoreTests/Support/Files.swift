import Darwin

@testable import UndoTurnCore

func writeFile(_ bytes: [UInt8], to path: String, mode: mode_t = 0o600) throws(SystemError) {
  try FileSystem.writeAtomically(bytes, to: path, mode: mode, durable: false)
}

func readFile(_ path: String) throws(SystemError) -> [UInt8] {
  try FileSystem.readFile(path)
}

func makeDirectories(_ path: String, mode: mode_t = 0o755) throws(SystemError) {
  try FileSystem.makeDirectories(path, mode: mode)
}

func fileMode(_ path: String) throws(SystemError) -> UInt16 {
  guard let info = try FileSystem.lstatIfPresent(path) else {
    throw SystemError(operation: "lstat", path: path, code: ENOENT)
  }
  return UInt16(info.st_mode & 0o7777)
}

func statKey(_ path: String) throws(SystemError) -> StatKey {
  guard let info = try FileSystem.lstatIfPresent(path) else {
    throw SystemError(operation: "lstat", path: path, code: ENOENT)
  }
  return StatKey(info)
}

func makeSymbolicLink(_ target: String, at path: String) throws(SystemError) {
  guard target.withCString({ target in path.withCString { symlink(target, $0) } }) == 0 else {
    throw SystemError(operation: "symlink", path: path, code: errno)
  }
}

func linkTarget(_ path: String) throws(SystemError) -> String {
  var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
  let count = path.withCString { readlink($0, &buffer, buffer.count) }
  guard count >= 0 else { throw SystemError(operation: "readlink", path: path, code: errno) }
  return String(decoding: buffer[..<count], as: UTF8.self)
}

func removeFile(_ path: String) throws(SystemError) {
  guard path.withCString({ unlink($0) }) == 0 else {
    throw SystemError(operation: "unlink", path: path, code: errno)
  }
}
