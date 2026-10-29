public struct HookDiagnostic: Equatable, Sendable {
  public let line: String
  public let time: Int64
}

public enum HookDiagnostics {
  public static func recentErrors(at path: String, now: Int64) throws(SystemError)
    -> [HookDiagnostic]
  {
    guard try FileSystem.lstatIfPresent(path) != nil else { return [] }
    return recentErrors(try FileSystem.readFile(path), now: now)
  }

  public static func recentErrors(_ bytes: [UInt8], now: Int64) -> [HookDiagnostic] {
    String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line in
      guard let separator = line.firstIndex(of: " "),
        let time = Int64(line[..<separator]), time >= 0, time <= now, now - time <= 86_400
      else { return nil }
      return HookDiagnostic(line: String(line), time: time)
    }
  }
}
