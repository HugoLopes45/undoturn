import Darwin

extension GarbageCollector {
  /// Returns nil before the next daily collection. Incomplete collection throws and remains due.
  public func collectIfDue(home: String, now: Int64) throws(GarbageCollectorError)
    -> [String: EvictionResult]?
  {
    let lockPath = home + "/maintenance.lock"
    let descriptor = lockPath.withCString {
      open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: lockPath, code: errno))
    }
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw .system(SystemError(operation: "flock", path: lockPath, code: errno))
    }
    let successPath = home + "/maintenance-success"
    do {
      if let last = try lastCollection(at: successPath) {
        let elapsed = now.subtractingReportingOverflow(last)
        if now < last || (!elapsed.overflow && elapsed.partialValue < 86_400) { return nil }
      }
    } catch let error { throw .system(error) }

    let results = try collect(home: home, now: now, scheduled: true)
    do {
      try FileSystem.writeAtomically(
        Array(String(now).utf8), to: successPath, mode: 0o600, durable: true)
    } catch let error { throw .system(error) }
    return results
  }
}

private func lastCollection(at path: String) throws(SystemError) -> Int64? {
  guard let info = try FileSystem.lstatIfPresent(path) else { return nil }
  guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 20,
    let value = Int64(String(decoding: try FileSystem.readFile(path), as: UTF8.self))
  else { throw SystemError(operation: "read maintenance timestamp", path: path, code: EINVAL) }
  return value
}
