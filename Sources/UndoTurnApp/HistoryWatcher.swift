import Darwin
import Dispatch

/// Calls `onChange` shortly after any watched file or folder changes. One hook writes several
/// files, so events within `delay` produce one call.
@MainActor final class HistoryWatcher {
  private let onChange: @MainActor () -> Void
  private let delay: DispatchTimeInterval
  private var sources: [String: any DispatchSourceFileSystemObject] = [:]
  private var scheduled: DispatchWorkItem?

  init(delay: DispatchTimeInterval = .milliseconds(250), onChange: @escaping @MainActor () -> Void)
  {
    self.delay = delay
    self.onChange = onChange
  }

  /// Watches exactly `paths`. A path that does not exist yet is skipped; the next change of its
  /// parent folder triggers a reload, which watches it again.
  func watch(_ paths: [String]) {
    let wanted = Set(paths)
    for (path, source) in sources where !wanted.contains(path) {
      source.cancel()
      sources[path] = nil
    }
    for path in paths where sources[path] == nil {
      let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.changed(path) }
      }
      source.setCancelHandler { _ = close(descriptor) }
      source.resume()
      sources[path] = source
    }
  }

  private func changed(_ path: String) {
    if let source = sources[path], !source.data.isDisjoint(with: [.delete, .rename]) {
      source.cancel()
      sources[path] = nil
    }
    scheduled?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.onChange() }
    }
    scheduled = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }
}
