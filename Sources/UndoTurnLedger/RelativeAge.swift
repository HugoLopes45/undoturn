import Darwin

public enum RelativeAge {
  public static func short(from time: Int64, now: Int64) -> String {
    guard let elapsed = elapsedSeconds(from: time, to: now) else { return "now" }
    if elapsed < 60 { return "now" }
    if elapsed < 3_600 { return "\(elapsed / 60) min" }
    if elapsed < 86_400 { return "\(elapsed / 3_600) h" }
    if elapsed < 30 * 86_400 { return "\(elapsed / 86_400) d" }
    return localDate(time)
  }

  public static func spoken(from time: Int64, now: Int64) -> String {
    guard let elapsed = elapsedSeconds(from: time, to: now) else { return "just now" }
    if elapsed < 60 { return "just now" }
    if elapsed < 3_600 {
      let minutes = elapsed / 60
      return "\(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
    }
    if elapsed < 86_400 {
      let hours = elapsed / 3_600
      return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
    }
    if elapsed < 30 * 86_400 {
      let days = elapsed / 86_400
      return "\(days) \(days == 1 ? "day" : "days") ago"
    }
    return "on \(localDate(time))"
  }

  private static func elapsedSeconds(from time: Int64, to now: Int64) -> Int64? {
    guard time < now else { return nil }
    let (elapsed, overflow) = now.subtractingReportingOverflow(time)
    return overflow ? Int64.max : elapsed
  }

  private static func localDate(_ timestamp: Int64) -> String {
    var seconds = time_t(timestamp)
    var components = tm()
    guard localtime_r(&seconds, &components) != nil else { return "unknown date" }

    var buffer = [CChar](repeating: 0, count: 64)
    let count = withUnsafeMutablePointer(to: &components) { componentsPointer in
      buffer.withUnsafeMutableBufferPointer { bufferPointer in
        strftime(bufferPointer.baseAddress, bufferPointer.count, "%Y-%m-%d", componentsPointer)
      }
    }
    guard count > 0 else { return "unknown date" }
    let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
