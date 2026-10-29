import Darwin

@testable import UndoTurnCore

/// A fresh directory under the system temporary folder. It is removed with its content when the value ends.
struct TemporaryDirectory: ~Copyable {
  let path: String

  init() throws(SystemError) {
    var template = Array("/tmp/undoturn-test.XXXXXX".utf8CString)
    guard let created = mkdtemp(&template) else {
      throw SystemError(operation: "mkdtemp", path: "/tmp", code: errno)
    }
    guard let resolved = realpath(created, nil) else {
      let code = errno
      _ = rmdir(created)
      throw SystemError(operation: "realpath", path: String(cString: created), code: code)
    }
    defer { free(resolved) }
    path = String(cString: resolved)
  }

  deinit {
    _ = nftw(
      path, { entry, _, _, _ in entry.map { Darwin.remove($0) } ?? -1 }, 16, FTW_DEPTH | FTW_PHYS)
  }
}
