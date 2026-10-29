import Darwin

/// One walk of a workspace.
public struct ScanResult: Equatable, Sendable {
  /// Tracked regular files, links and folders keyed by workspace-relative path with `/`
  /// separators. A folder's key is `StatKey.directory(mode:)`.
  public var files: [String: StatKey]
  /// Workspace-relative directories the walk could not open or list (`EACCES` or `EPERM`).
  /// Their content is unknown, not absent: callers keep earlier observations below them.
  public var unreadableDirectories: [String]

  public init(files: [String: StatKey], unreadableDirectories: [String]) {
    self.files = files
    self.unreadableDirectories = unreadableDirectories
  }
}

/// Changed-path observations and the roots whose prior entries they replace.
public struct RescanDelta: Equatable, Sendable {
  public let observedFiles: [String: StatKey]
  public let removedRoots: Set<String>
  public let preservedRoots: Set<String>
  public let unreadableDirectories: [String]

  public func applying(to previous: [String: StatKey]) -> ScanResult {
    let roots = RescanRoots(removed: removedRoots, preserved: preservedRoots)
    var files = previous
    for path in previous.keys {
      let (removed, preserved) = roots.match(path)
      if removed && !preserved { files[path] = nil }
    }
    files.merge(observedFiles) { _, new in new }
    return ScanResult(files: files, unreadableDirectories: unreadableDirectories)
  }
}

/// Walks a workspace with `getattrlistbulk(2)` and returns stat keys for tracked regular files,
/// links and folders.
public enum Scanner {
  /// Fails if the root, an ignore file, or a directory listing fails for a reason other than permissions.
  public static func scan(root: String) throws(SystemError) -> ScanResult {
    try scan(
      root: root, beforeOpeningDirectory: nil, threadCount: defaultScannerThreadCount())
  }

  static func scan(
    root: String,
    beforeOpeningDirectory: ((String) -> Void)?
  ) throws(SystemError) -> ScanResult {
    let threadCount = beforeOpeningDirectory == nil ? defaultScannerThreadCount() : 1
    return try scan(
      root: root, beforeOpeningDirectory: beforeOpeningDirectory, threadCount: threadCount)
  }

  static func scan(
    root: String, ignoreFileOverrides: [String: IgnoreFileOverride]
  ) throws(SystemError) -> ScanResult {
    try scan(
      root: root, threadCount: defaultScannerThreadCount(), ignoreFileOverrides: ignoreFileOverrides
    )
  }

  static func scan(
    root: String,
    beforeOpeningDirectory: ((String) -> Void)? = nil,
    threadCount: Int,
    ignoreFileOverrides: [String: IgnoreFileOverride] = [:]
  ) throws(SystemError) -> ScanResult {
    let rootDescriptor = root.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    guard rootDescriptor >= 0 else {
      throw SystemError(operation: "open directory", path: root, code: errno)
    }
    let descriptors = DirectoryDescriptorOwner(rootDescriptor: rootDescriptor)

    let rules = try IgnoreRules.loadRoot(
      directoryDescriptor: rootDescriptor, rootPath: root, fileOverrides: ignoreFileOverrides)
    var walker = Walker(root: root, beforeOpeningDirectory: beforeOpeningDirectory)
    try walker.walkParallel(
      directoryDescriptor: rootDescriptor,
      relativePath: "",
      ignoredAncestor: false,
      rules: rules,
      threadCount: threadCount,
      descriptorOwner: descriptors
    )
    return ScanResult(
      files: walker.files, unreadableDirectories: walker.unreadableDirectories.sorted())
  }
  /// Observes changed paths, or returns nil when a full walk is required.
  public static func rescan(root: String, paths: [String]) throws(SystemError) -> RescanDelta? {
    try rescan(root: root, paths: paths, ignoreFileOverrides: [:])
  }

  static func rescan(
    root: String, paths: [String], ignoreFileOverrides: [String: IgnoreFileOverride]
  ) throws(SystemError) -> RescanDelta? {
    guard let coalescedPaths = coalescedRescanPaths(paths) else { return nil }
    if coalescedPaths.isEmpty {
      return RescanDelta(
        observedFiles: [:],
        removedRoots: [],
        preservedRoots: [],
        unreadableDirectories: [])
    }

    let rootDescriptor = root.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    guard rootDescriptor >= 0 else {
      throw SystemError(operation: "open directory", path: root, code: errno)
    }
    defer { _ = close(rootDescriptor) }

    let rootRules = try IgnoreRules.loadRoot(
      directoryDescriptor: rootDescriptor, rootPath: root, fileOverrides: ignoreFileOverrides)
    var removedRoots = Set<String>()
    var preservedRoots = Set<String>()
    var observedFiles: [String: StatKey] = [:]
    var unreadableDirectories = Set<String>()

    for (path, components) in coalescedPaths {
      switch try observeRescanPath(
        root: root,
        rootDescriptor: rootDescriptor,
        rootRules: rootRules,
        path: path,
        components: components
      ) {
      case .absent:
        removedRoots.insert(path)
      case .file(let key):
        removedRoots.insert(path)
        observedFiles[path] = key
      case .subtree(let result):
        removedRoots.insert(path)
        observedFiles.merge(result.files) { _, new in new }
        for unreadable in result.unreadableDirectories {
          unreadableDirectories.insert(unreadable)
          preservedRoots.insert(unreadable)
        }
      case .unreadable(let directory):
        unreadableDirectories.insert(directory)
        preservedRoots.insert(directory)
        removedRoots.insert(directory)
      case .fullScanRequired:
        return nil
      }
    }

    return RescanDelta(
      observedFiles: observedFiles,
      removedRoots: removedRoots,
      preservedRoots: preservedRoots,
      unreadableDirectories: unreadableDirectories.sorted())
  }
}

private enum RescanObservation {
  case absent
  case file(StatKey)
  case subtree(ScanResult)
  case unreadable(String)
  case fullScanRequired
}

private func rescanPathComponents(_ path: String) -> [String]? {
  guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"), !path.utf8.contains(0) else {
    return nil
  }
  let components = path.split(separator: "/", omittingEmptySubsequences: false)
  guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
  return components.map(String.init)
}

/// Answers whether a path is at-or-below a removed root or strictly below a preserved root.
/// Checks only prefixes at root depths and allocates nothing, because it runs once per stored path.
struct RescanRoots {
  let removed: Set<Substring>
  let preserved: Set<Substring>
  let depths: ClosedRange<Int>?

  init(removed: Set<String>, preserved: Set<String>) {
    self.removed = Set(removed.lazy.map { Substring($0) })
    self.preserved = Set(preserved.lazy.map { Substring($0) })
    let componentCounts = removed.union(preserved).map { root in
      root.utf8.reduce(1) { count, byte in byte == UInt8(ascii: "/") ? count + 1 : count }
    }
    if let lowest = componentCounts.min(), let highest = componentCounts.max() {
      depths = lowest...highest
    } else {
      depths = nil
    }
  }

  func match(_ path: String) -> (removed: Bool, preserved: Bool) {
    guard let depths else { return (false, false) }
    var matchesRemoval = false
    var matchesPreservation = false
    let utf8 = path.utf8
    var componentStart = utf8.startIndex
    var depth = 1
    while depth <= depths.upperBound {
      let componentEnd = utf8[componentStart...].firstIndex(of: UInt8(ascii: "/")) ?? utf8.endIndex
      if depth >= depths.lowerBound {
        let prefix = path[..<componentEnd]
        matchesRemoval = matchesRemoval || removed.contains(prefix)
        if componentEnd != utf8.endIndex {
          matchesPreservation = matchesPreservation || preserved.contains(prefix)
        }
        if matchesRemoval && matchesPreservation { break }
      }
      guard componentEnd != utf8.endIndex else { break }
      componentStart = utf8.index(after: componentEnd)
      depth += 1
    }
    return (matchesRemoval, matchesPreservation)
  }
}

private func coalescedRescanPaths(_ paths: [String]) -> [(String, [String])]? {
  var uniquePaths = Set<String>()
  var validPaths: [(String, [String])] = []
  for path in paths {
    // Rule files open by name, so a volume that ignores case loads any spelling of them.
    let folded = path.lowercased()
    guard let components = rescanPathComponents(path),
      let last = components.last,
      last.lowercased() != ".gitignore",
      last != "Cargo.toml",
      folded != ".undoturnignore",
      folded != ".git",
      folded != ".git/info",
      folded != ".git/info/exclude"
    else { return nil }
    if uniquePaths.insert(path).inserted { validPaths.append((path, components)) }
  }
  var coalescedPaths: [(String, [String])] = []
  var selectedAncestors = Set<String>()
  for (path, components) in validPaths.sorted(by: { $0.0 < $1.0 }) {
    var prefix = ""
    var hasSelectedAncestor = false
    for component in components.dropLast() {
      prefix = prefix.isEmpty ? component : prefix + "/" + component
      if selectedAncestors.contains(prefix) {
        hasSelectedAncestor = true
        break
      }
    }
    if !hasSelectedAncestor {
      coalescedPaths.append((path, components))
      selectedAncestors.insert(path)
    }
  }
  return coalescedPaths
}

private func observeRescanPath(
  root: String,
  rootDescriptor: Int32,
  rootRules: IgnoreRules,
  path: String,
  components: [String]
) throws(SystemError) -> RescanObservation {
  var directoryDescriptor = rootDescriptor
  var ownsDirectoryDescriptor = false
  defer {
    if ownsDirectoryDescriptor { _ = close(directoryDescriptor) }
  }
  var rules = rootRules
  var ignoredAncestor = false
  var relativeParent = ""

  for component in components.dropLast() {
    let relativePath = appendPath(relativeParent, component)
    if isAlwaysSkippedDirectory(component)
      || rules.excludes(path: relativePath, isDirectory: true)
    {
      return .absent
    }
    if component == "target",
      let observation = try cargoTargetObservation(
        at: directoryDescriptor, relativeDirectory: relativeParent, root: root, rules: rules)
    {
      return observation
    }

    let isIgnored = ignoredAncestor || rules.ignores(path: relativePath, isDirectory: true)
    let childDescriptor = component.withCString {
      openat(
        directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard childDescriptor >= 0 else {
      let code = errno
      return try failedRescanDirectory(
        component, at: directoryDescriptor, root: root, path: relativePath, code: code)
    }
    guard
      case .matches = rescanNameCheck(
        component, at: directoryDescriptor)
    else {
      _ = close(childDescriptor)
      return .fullScanRequired
    }
    if ownsDirectoryDescriptor { _ = close(directoryDescriptor) }
    directoryDescriptor = childDescriptor
    ownsDirectoryDescriptor = true
    relativeParent = relativePath
    ignoredAncestor = isIgnored
    if !isIgnored {
      try rules.appendNestedFile(
        directoryDescriptor: childDescriptor,
        basePath: relativePath,
        directoryPath: rescanAbsolutePath(root, relativePath)
      )
    }
  }

  guard let leaf = components.last else { return .absent }
  return try observeRescanLeaf(
    leaf,
    root: root,
    directoryDescriptor: directoryDescriptor,
    path: path,
    relativeParent: relativeParent,
    ignoredAncestor: ignoredAncestor,
    rules: rules
  )
}

private func failedRescanDirectory(
  _ name: String, at directoryDescriptor: Int32, root: String, path: String, code: Int32
) throws(SystemError) -> RescanObservation {
  if isRescanPermissionError(code) {
    return rescanNameCheck(name, at: directoryDescriptor) == .matches
      ? .unreadable(path) : .fullScanRequired
  }
  if isRescanAbsentError(code) { return .absent }
  throw SystemError(
    operation: "open directory", path: rescanAbsolutePath(root, path), code: code)
}

private func observeRescanLeaf(
  _ leaf: String,
  root: String,
  directoryDescriptor: Int32,
  path: String,
  relativeParent: String,
  ignoredAncestor: Bool,
  rules: IgnoreRules
) throws(SystemError) -> RescanObservation {
  var metadata = stat()
  let status = leaf.withCString {
    fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
  }
  guard status == 0 else {
    let code = errno
    if isRescanPermissionError(code) { return .unreadable(path) }
    if isRescanAbsentError(code) { return .absent }
    throw SystemError(operation: "stat", path: rescanAbsolutePath(root, path), code: code)
  }
  guard case .matches = rescanNameCheck(leaf, at: directoryDescriptor) else {
    return .fullScanRequired
  }

  let kind = metadata.st_mode & mode_t(S_IFMT)
  if kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) {
    if rules.recordsFile(named: leaf, path: path, ignoredAncestor: ignoredAncestor) {
      return .file(StatKey(metadata))
    }
    return .absent
  }
  guard kind == mode_t(S_IFDIR), !isAlwaysSkippedDirectory(leaf),
    !rules.excludes(path: path, isDirectory: true)
  else { return .absent }
  if leaf == "target",
    let observation = try cargoTargetObservation(
      at: directoryDescriptor, relativeDirectory: relativeParent, root: root, rules: rules)
  {
    return observation
  }

  return try observeRescanSubtree(
    leaf, root: root, directoryDescriptor: directoryDescriptor, path: path,
    ignoredAncestor: ignoredAncestor, rules: rules, mode: UInt16(metadata.st_mode & 0o7777))
}

private func observeRescanSubtree(
  _ leaf: String, root: String, directoryDescriptor: Int32, path: String,
  ignoredAncestor: Bool, rules: IgnoreRules, mode: UInt16
) throws(SystemError) -> RescanObservation {
  let isIgnored = ignoredAncestor || rules.ignores(path: path, isDirectory: true)
  let folder: [String: StatKey] =
    isIgnored ? [:] : [path: StatKey.directory(mode: mode)]
  let childDescriptor = leaf.withCString {
    openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
  }
  guard childDescriptor >= 0 else {
    let code = errno
    if isRescanPermissionError(code) {
      return .subtree(ScanResult(files: folder, unreadableDirectories: [path]))
    }
    if isRescanAbsentError(code) { return .absent }
    throw SystemError(operation: "open directory", path: rescanAbsolutePath(root, path), code: code)
  }
  guard case .matches = rescanNameCheck(leaf, at: directoryDescriptor) else {
    _ = close(childDescriptor)
    return .fullScanRequired
  }
  defer { _ = close(childDescriptor) }

  var childRules = rules
  if !isIgnored {
    try childRules.appendNestedFile(
      directoryDescriptor: childDescriptor,
      basePath: path,
      directoryPath: rescanAbsolutePath(root, path)
    )
  }
  var walker = Walker(root: root)
  walker.files = folder
  try walker.walk(
    directoryDescriptor: childDescriptor,
    relativePath: path,
    ignoredAncestor: isIgnored,
    rules: childRules
  )
  return .subtree(
    ScanResult(files: walker.files, unreadableDirectories: walker.unreadableDirectories))
}

private enum RescanNameCheck {
  case matches
  case mismatch
  case unknown
}

private func rescanNameCheck(_ component: String, at directoryDescriptor: Int32)
  -> RescanNameCheck
{
  guard let name = FileSystem.storedName(component, in: directoryDescriptor) else {
    return .unknown
  }
  return component.utf8.elementsEqual(name) ? .matches : .mismatch
}

/// The observation for anything at or below `target` in `relativeDirectory` when a regular
/// `Cargo.toml` makes it a build folder, or when that is unknown. Nil for a plain folder.
private func cargoTargetObservation(
  at directoryDescriptor: Int32,
  relativeDirectory: String,
  root: String,
  rules: IgnoreRules
) throws(SystemError) -> RescanObservation? {
  if let exists = rules.cargoManifest(in: relativeDirectory) { return exists ? .absent : nil }
  var metadata = stat()
  let status = "Cargo.toml".withCString {
    fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
  }
  guard status == 0 else {
    let code = errno
    if isRescanAbsentError(code) { return nil }
    if isRescanPermissionError(code) { return .unreadable(relativeDirectory) }
    throw SystemError(
      operation: "stat",
      path: rescanAbsolutePath(root, appendPath(relativeDirectory, "Cargo.toml")),
      code: code)
  }
  switch rescanNameCheck("Cargo.toml", at: directoryDescriptor) {
  case .matches:
    return metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) ? .absent : nil
  case .mismatch:
    return nil
  case .unknown:
    return .fullScanRequired
  }
}

private func appendPath(_ parent: String, _ child: String) -> String {
  parent.isEmpty ? child : parent + "/" + child
}

private func rescanAbsolutePath(_ root: String, _ relative: String) -> String {
  if relative.isEmpty { return root }
  if root == "/" { return root + relative }
  return root.hasSuffix("/") ? root + relative : root + "/" + relative
}

private func isRescanPermissionError(_ code: Int32) -> Bool {
  code == EACCES || code == EPERM
}

func isRescanAbsentError(_ code: Int32) -> Bool {
  code == ENOENT || code == ENOTDIR || code == ELOOP
}

private enum EntryKind {
  case regular
  case link
  case directory
  case other
}

private struct BulkRecord {
  let name: String
  let kind: EntryKind
  let statKey: StatKey?
  let error: Int32
  let length: Int
}

private struct DirectoryListing {
  let subdirectories: [String]
  let hasCargoManifest: Bool

  func appendPendingDescends(
    to pending: inout [PendingDescend],
    parentDescriptor: Int32,
    relativePath: String,
    ignoredAncestor: Bool,
    rules: IgnoreRules
  ) {
    for name in subdirectories where !(name == "target" && hasCargoManifest) {
      pending.append(
        PendingDescend(
          parentDescriptor: parentDescriptor,
          name: name,
          relativePath: appendPath(relativePath, name),
          ignoredAncestor: ignoredAncestor,
          rules: rules
        ))
    }
  }
}

private struct PendingDescend {
  let parentDescriptor: Int32
  let name: String
  let relativePath: String
  let ignoredAncestor: Bool
  let rules: IgnoreRules
}

private struct ParallelWalkResult {
  let files: [String: StatKey]
  let unreadableDirectories: [String]
  let failureIndex: Int?
  let failure: SystemError?
}

private final class DirectoryDescriptorOwner {
  private var descriptors: Set<Int32>

  init(rootDescriptor: Int32) {
    descriptors = [rootDescriptor]
  }

  func retain(_ descriptor: Int32) {
    descriptors.insert(descriptor)
  }

  func close(_ descriptor: Int32) {
    guard descriptors.remove(descriptor) != nil else { return }
    _ = Darwin.close(descriptor)
  }

  deinit {
    for descriptor in descriptors { _ = Darwin.close(descriptor) }
  }
}

private final class ParallelScanContext {
  let root: String
  let beforeOpeningDirectory: ((String) -> Void)?
  let descends: [PendingDescend]
  let workerCount: Int
  let descriptorOwner: DirectoryDescriptorOwner
  private let mutex: UnsafeMutablePointer<pthread_mutex_t>
  private let results: UnsafeMutablePointer<ParallelWalkResult?>
  private var nextIndex: Int

  init(
    root: String,
    beforeOpeningDirectory: ((String) -> Void)?,
    descends: [PendingDescend],
    startIndex: Int,
    workerCount: Int,
    descriptorOwner: DirectoryDescriptorOwner
  ) throws(SystemError) {
    let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    mutex.initialize(to: pthread_mutex_t())
    let mutexStatus = pthread_mutex_init(mutex, nil)
    guard mutexStatus == 0 else {
      mutex.deinitialize(count: 1)
      mutex.deallocate()
      throw SystemError(operation: "pthread_mutex_init", path: root, code: mutexStatus)
    }
    let results = UnsafeMutablePointer<ParallelWalkResult?>.allocate(capacity: workerCount)
    results.initialize(repeating: nil, count: workerCount)

    self.root = root
    self.beforeOpeningDirectory = beforeOpeningDirectory
    self.descends = descends
    self.workerCount = workerCount
    self.descriptorOwner = descriptorOwner
    self.mutex = mutex
    self.results = results
    nextIndex = startIndex
  }

  func claimNext() throws(SystemError) -> (index: Int, descend: PendingDescend)? {
    let lockStatus = pthread_mutex_lock(mutex)
    guard lockStatus == 0 else {
      throw SystemError(operation: "pthread_mutex_lock", path: root, code: lockStatus)
    }

    let index = nextIndex
    if index < descends.count { nextIndex += 1 }
    let unlockStatus = pthread_mutex_unlock(mutex)
    guard unlockStatus == 0 else {
      throw SystemError(operation: "pthread_mutex_unlock", path: root, code: unlockStatus)
    }
    guard index < descends.count else { return nil }
    return (index, descends[index])
  }

  func store(_ result: ParallelWalkResult, at index: Int) {
    results[index] = result
  }

  func result(at index: Int) -> ParallelWalkResult? {
    results[index]
  }

  deinit {
    _ = pthread_mutex_destroy(mutex)
    mutex.deinitialize(count: 1)
    mutex.deallocate()
    results.deinitialize(count: workerCount)
    results.deallocate()
  }
}

private final class ParallelWorkerContext {
  let scan: ParallelScanContext
  let resultIndex: Int

  init(scan: ParallelScanContext, resultIndex: Int) {
    self.scan = scan
    self.resultIndex = resultIndex
  }

  func run() {
    var walker = Walker(root: scan.root, beforeOpeningDirectory: scan.beforeOpeningDirectory)
    var failure: SystemError?
    var failureIndex: Int?

    while true {
      let next: (index: Int, descend: PendingDescend)?
      do throws(SystemError) {
        next = try scan.claimNext()
      } catch let error {
        failure = error
        break
      }
      guard let next else { break }
      do throws(SystemError) {
        try walker.descend(next.descend)
      } catch let error {
        failureIndex = next.index
        failure = error
        break
      }
    }

    scan.store(
      ParallelWalkResult(
        files: walker.files,
        unreadableDirectories: walker.unreadableDirectories,
        failureIndex: failureIndex,
        failure: failure
      ),
      at: resultIndex
    )
  }
}

private let parallelScanWorker:
  @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = {
    argument in
    let worker = Unmanaged<ParallelWorkerContext>.fromOpaque(argument).takeRetainedValue()
    worker.run()
    return nil
  }

private func defaultScannerThreadCount() -> Int {
  let onlineCPUCount = sysconf(_SC_NPROCESSORS_ONLN)
  return onlineCPUCount < 2 ? 1 : min(4, Int(onlineCPUCount))
}

private struct Walker {
  let root: String
  let beforeOpeningDirectory: ((String) -> Void)?
  var files: [String: StatKey] = [:]
  var unreadableDirectories: [String] = []
  var buffer = [UInt8](repeating: 0, count: 32 * 1024)

  init(root: String, beforeOpeningDirectory: ((String) -> Void)? = nil) {
    self.root = root
    self.beforeOpeningDirectory = beforeOpeningDirectory
  }

  mutating func walk(
    directoryDescriptor: Int32,
    relativePath: String,
    ignoredAncestor: Bool,
    rules: IgnoreRules
  ) throws(SystemError) {
    let listing = try listDirectory(
      directoryDescriptor: directoryDescriptor,
      relativePath: relativePath,
      ignoredAncestor: ignoredAncestor,
      rules: rules
    )
    for name in listing.subdirectories where !(name == "target" && listing.hasCargoManifest) {
      try descend(
        PendingDescend(
          parentDescriptor: directoryDescriptor,
          name: name,
          relativePath: appendPath(relativePath, name),
          ignoredAncestor: ignoredAncestor,
          rules: rules
        ))
    }
  }

  fileprivate mutating func walkParallel(
    directoryDescriptor: Int32,
    relativePath: String,
    ignoredAncestor: Bool,
    rules: IgnoreRules,
    threadCount: Int,
    descriptorOwner: DirectoryDescriptorOwner
  ) throws(SystemError) {
    guard threadCount > 1 else {
      try walk(
        directoryDescriptor: directoryDescriptor,
        relativePath: relativePath,
        ignoredAncestor: ignoredAncestor,
        rules: rules
      )
      return
    }

    let rootListing = try listDirectory(
      directoryDescriptor: directoryDescriptor,
      relativePath: relativePath,
      ignoredAncestor: ignoredAncestor,
      rules: rules
    )
    var pending: [PendingDescend] = []
    rootListing.appendPendingDescends(
      to: &pending,
      parentDescriptor: directoryDescriptor,
      relativePath: relativePath,
      ignoredAncestor: ignoredAncestor,
      rules: rules
    )
    var nextPending = 0
    var parentReferences: [Int32: Int] = [:]
    let frontierSize = 4 * threadCount

    while pending.count - nextPending < frontierSize, nextPending < pending.count {
      let current = pending[nextPending]
      nextPending += 1

      if let childDescriptor = try openDirectory(current) {
        descriptorOwner.retain(childDescriptor)
        let childState = try childDirectoryState(current, descriptor: childDescriptor)
        let childListing = try listDirectory(
          directoryDescriptor: childDescriptor,
          relativePath: current.relativePath,
          ignoredAncestor: childState.ignoredAncestor,
          rules: childState.rules
        )
        let firstChildIndex = pending.count
        childListing.appendPendingDescends(
          to: &pending,
          parentDescriptor: childDescriptor,
          relativePath: current.relativePath,
          ignoredAncestor: childState.ignoredAncestor,
          rules: childState.rules
        )
        let childCount = pending.count - firstChildIndex
        if childCount == 0 {
          descriptorOwner.close(childDescriptor)
        } else {
          parentReferences[childDescriptor] = childCount
        }
      }

      if let remainingReferences = parentReferences[current.parentDescriptor] {
        if remainingReferences == 1 {
          parentReferences[current.parentDescriptor] = nil
          descriptorOwner.close(current.parentDescriptor)
        } else {
          parentReferences[current.parentDescriptor] = remainingReferences - 1
        }
      }
    }

    guard nextPending < pending.count else { return }

    try runParallelWorkers(
      pending: pending, nextPending: nextPending, threadCount: threadCount,
      descriptorOwner: descriptorOwner)
  }

  private mutating func runParallelWorkers(
    pending: [PendingDescend], nextPending: Int, threadCount: Int,
    descriptorOwner: DirectoryDescriptorOwner
  ) throws(SystemError) {
    let scanContext = try ParallelScanContext(
      root: root,
      beforeOpeningDirectory: beforeOpeningDirectory,
      descends: pending,
      startIndex: nextPending,
      workerCount: threadCount,
      descriptorOwner: descriptorOwner
    )
    var attributes = pthread_attr_t()
    let attributeStatus = pthread_attr_init(&attributes)
    guard attributeStatus == 0 else {
      throw SystemError(operation: "pthread_attr_init", path: root, code: attributeStatus)
    }
    defer { _ = pthread_attr_destroy(&attributes) }

    let stackStatus = pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024)
    guard stackStatus == 0 else {
      throw SystemError(operation: "pthread_attr_setstacksize", path: root, code: stackStatus)
    }

    // New threads start at the default class, not at the class of the thread that waits for them.
    let callerClass = qos_class_self()
    if callerClass != QOS_CLASS_UNSPECIFIED {
      let classStatus = pthread_attr_set_qos_class_np(&attributes, callerClass, 0)
      guard classStatus == 0 else {
        throw SystemError(operation: "pthread_attr_set_qos_class_np", path: root, code: classStatus)
      }
    }

    // The calling thread is worker 0 and finishes all work alone if no helper thread starts.
    var threads: [pthread_t] = []
    threads.reserveCapacity(threadCount - 1)
    for workerIndex in 1..<threadCount {
      let worker = ParallelWorkerContext(scan: scanContext, resultIndex: workerIndex)
      let argument = Unmanaged.passRetained(worker).toOpaque()
      var thread: pthread_t?
      guard pthread_create(&thread, &attributes, parallelScanWorker, argument) == 0 else {
        Unmanaged<ParallelWorkerContext>.fromOpaque(argument).release()
        break
      }
      guard let createdThread = thread else { break }
      threads.append(createdThread)
    }
    ParallelWorkerContext(scan: scanContext, resultIndex: 0).run()

    var joinFailure: SystemError?
    for thread in threads {
      let status = pthread_join(thread, nil)
      if status != 0 && joinFailure == nil {
        joinFailure = SystemError(operation: "pthread_join", path: root, code: status)
      }
    }
    if let joinFailure { throw joinFailure }
    try mergeResults(of: scanContext, workerCount: threadCount)
  }

  /// Adds every worker's results, then throws the failure with the lowest pending index.
  private mutating func mergeResults(of scanContext: ParallelScanContext, workerCount: Int)
    throws(SystemError)
  {
    var lowestFailure: (index: Int, error: SystemError)?
    for workerIndex in 0..<workerCount {
      guard let result = scanContext.result(at: workerIndex) else { continue }
      files.merge(result.files) { _, new in new }
      unreadableDirectories.append(contentsOf: result.unreadableDirectories)
      if let error = result.failure {
        let index = result.failureIndex ?? Int.max
        if let current = lowestFailure {
          if index < current.index { lowestFailure = (index, error) }
        } else {
          lowestFailure = (index, error)
        }
      }
    }
    if let lowestFailure { throw lowestFailure.error }
  }

  private mutating func listDirectory(
    directoryDescriptor: Int32,
    relativePath: String,
    ignoredAncestor: Bool,
    rules: IgnoreRules
  ) throws(SystemError) -> DirectoryListing {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr =
      UInt32(bitPattern: Int32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS))
      | UInt32(ATTR_CMN_ERROR)
      | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_OBJTYPE)
      | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_ACCESSMASK) | UInt32(ATTR_CMN_FILEID)
    attributes.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

    var subdirectories: [String] = []
    var folders: [(name: String, key: StatKey)] = []
    var hasCargoManifest = false
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        getattrlistbulk(directoryDescriptor, &attributes, bytes.baseAddress, bytes.count, 0)
      }
      if count == 0 { break }
      guard count > 0 else {
        let code = errno
        if code == EACCES || code == EPERM {
          let prefix = relativePath.isEmpty ? "" : relativePath + "/"
          files = files.filter {
            !($0.key.hasPrefix(prefix) && !$0.key.dropFirst(prefix.count).contains("/"))
          }
          unreadableDirectories.append(relativePath)
          return DirectoryListing(subdirectories: [], hasCargoManifest: false)
        }
        throw SystemError(
          operation: "getattrlistbulk", path: absolutePath(relativePath), code: code)
      }

      var offset = 0
      for _ in 0..<count {
        guard let record = buffer.withUnsafeBytes({ parseBulkRecord($0, offset: offset) }) else {
          throw SystemError(
            operation: "parse getattrlistbulk", path: absolutePath(relativePath), code: EIO)
        }
        offset += record.length
        let path = appendPath(relativePath, record.name)
        if record.error != 0 {
          if isRescanAbsentError(record.error) { continue }
          throw SystemError(
            operation: "getattrlistbulk", path: absolutePath(path), code: record.error)
        }
        recordBulkEntry(
          record, path: path, ignoredAncestor: ignoredAncestor, rules: rules,
          subdirectories: &subdirectories, folders: &folders, hasCargoManifest: &hasCargoManifest)
      }
    }
    hasCargoManifest = rules.cargoManifest(in: relativePath) ?? hasCargoManifest
    for folder in folders where !(hasCargoManifest && folder.name == "target") {
      files[appendPath(relativePath, folder.name)] = folder.key
    }
    return DirectoryListing(
      subdirectories: subdirectories, hasCargoManifest: hasCargoManifest)
  }

  private mutating func recordBulkEntry(
    _ record: BulkRecord, path: String, ignoredAncestor: Bool, rules: IgnoreRules,
    subdirectories: inout [String], folders: inout [(name: String, key: StatKey)],
    hasCargoManifest: inout Bool
  ) {
    switch record.kind {
    case .regular, .link:
      guard let key = record.statKey else { return }
      if record.kind == .regular, record.name == "Cargo.toml" { hasCargoManifest = true }
      if rules.recordsFile(named: record.name, path: path, ignoredAncestor: ignoredAncestor) {
        files[path] = key
      }
    case .directory:
      guard !isAlwaysSkippedDirectory(record.name),
        !rules.excludes(path: path, isDirectory: true)
      else { return }
      subdirectories.append(record.name)
      if let key = record.statKey, !ignoredAncestor,
        !rules.ignores(path: path, isDirectory: true)
      {
        folders.append((record.name, key))
      }
    case .other:
      return
    }
  }

  private mutating func openDirectory(_ pending: PendingDescend) throws(SystemError) -> Int32? {
    beforeOpeningDirectory?(pending.relativePath)
    let childDescriptor = pending.name.withCString {
      openat(
        pending.parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard childDescriptor >= 0 else {
      let code = errno
      if isRescanAbsentError(code) { return nil }
      if code == EACCES || code == EPERM {
        unreadableDirectories.append(pending.relativePath)
        return nil
      }
      throw SystemError(
        operation: "open directory", path: absolutePath(pending.relativePath), code: code)
    }
    return childDescriptor
  }

  private func childDirectoryState(
    _ pending: PendingDescend,
    descriptor: Int32
  ) throws(SystemError) -> (ignoredAncestor: Bool, rules: IgnoreRules) {
    let isIgnored =
      pending.ignoredAncestor
      || pending.rules.ignores(path: pending.relativePath, isDirectory: true)
    var childRules = pending.rules
    if !isIgnored {
      try childRules.appendNestedFile(
        directoryDescriptor: descriptor,
        basePath: pending.relativePath,
        directoryPath: absolutePath(pending.relativePath)
      )
    }
    return (isIgnored, childRules)
  }

  fileprivate mutating func descend(_ pending: PendingDescend) throws(SystemError) {
    guard let childDescriptor = try openDirectory(pending) else { return }
    defer { _ = close(childDescriptor) }

    let childState = try childDirectoryState(pending, descriptor: childDescriptor)
    try walk(
      directoryDescriptor: childDescriptor,
      relativePath: pending.relativePath,
      ignoredAncestor: childState.ignoredAncestor,
      rules: childState.rules
    )
  }

  private func absolutePath(_ relative: String) -> String {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return relative.isEmpty ? root : prefix + relative
  }
}

private func isAlwaysSkippedDirectory(_ name: String) -> Bool {
  name == ".git" || name == "node_modules" || name == ".build" || name == "DerivedData"
    || name == "Pods"
}

/// Parses one record. Attributes follow the 20-byte returned-attribute set in bit order;
/// `ATTR_CMN_ERROR` comes first and is present only when the kernel sets its returned bit.
private func parseBulkRecord(_ buffer: UnsafeRawBufferPointer, offset: Int) -> BulkRecord? {
  guard let lengthValue = load(UInt32.self, from: buffer, at: offset, end: buffer.count) else {
    return nil
  }
  let length = Int(lengthValue)
  guard length >= 4, offset <= buffer.count, length <= buffer.count - offset else { return nil }
  let end = offset + length

  guard let returnedCommon = load(UInt32.self, from: buffer, at: offset + 4, end: end),
    let returnedFile = load(UInt32.self, from: buffer, at: offset + 16, end: end)
  else { return nil }
  var cursor = offset + 24
  var entryError: Int32 = 0
  if returnedCommon & UInt32(ATTR_CMN_ERROR) != 0 {
    guard let errorValue = load(UInt32.self, from: buffer, at: cursor, end: end) else { return nil }
    entryError = Int32(truncatingIfNeeded: errorValue)
    cursor += 4
  }
  guard returnedCommon & UInt32(ATTR_CMN_NAME) != 0,
    let nameReference = load(attrreference_t.self, from: buffer, at: cursor, end: end)
  else { return nil }

  let nameStart = cursor + Int(nameReference.attr_dataoffset)
  let nameLength = Int(nameReference.attr_length)
  guard nameStart >= offset, nameStart < end, nameLength > 0, nameLength <= end - nameStart,
    let baseAddress = buffer.baseAddress
  else { return nil }
  cursor += MemoryLayout<attrreference_t>.size
  let nameBytes = UnsafeBufferPointer(
    start: baseAddress.advanced(by: nameStart).assumingMemoryBound(to: UInt8.self),
    count: nameLength
  )
  guard let terminator = nameBytes.firstIndex(of: 0) else { return nil }
  let name = String(decoding: nameBytes[..<terminator], as: UTF8.self)
  guard name.utf8.elementsEqual(nameBytes[..<terminator]) else { return nil }

  if entryError != 0 {
    return BulkRecord(name: name, kind: .other, statKey: nil, error: entryError, length: length)
  }
  return bulkRecordMetadata(
    buffer, name: name, length: length, returnedCommon: returnedCommon,
    returnedFile: returnedFile, attributesOffset: cursor, end: end)
}

private func bulkRecordMetadata(
  _ buffer: UnsafeRawBufferPointer, name: String, length: Int, returnedCommon: UInt32,
  returnedFile: UInt32, attributesOffset: Int, end: Int
) -> BulkRecord? {
  var cursor = attributesOffset
  let requiredCommon =
    UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_MODTIME)
    | UInt32(ATTR_CMN_ACCESSMASK) | UInt32(ATTR_CMN_FILEID)
  guard returnedCommon & requiredCommon == requiredCommon else { return nil }

  guard let device = load(dev_t.self, from: buffer, at: cursor, end: end),
    let objectType = load(fsobj_type_t.self, from: buffer, at: cursor + 4, end: end),
    let modified = load(timespec.self, from: buffer, at: cursor + 8, end: end),
    let accessMask = load(UInt32.self, from: buffer, at: cursor + 24, end: end),
    let fileID = load(UInt64.self, from: buffer, at: cursor + 28, end: end)
  else { return nil }
  cursor += 36

  if objectType == VDIR.rawValue {
    return BulkRecord(
      name: name, kind: .directory, statKey: StatKey.directory(mode: UInt16(accessMask & 0o7777)),
      error: 0, length: length)
  }
  guard objectType == VREG.rawValue || objectType == VLNK.rawValue else {
    return BulkRecord(name: name, kind: .other, statKey: nil, error: 0, length: length)
  }
  guard returnedFile & UInt32(ATTR_FILE_DATALENGTH) != 0,
    let size = load(off_t.self, from: buffer, at: cursor, end: end)
  else { return nil }
  let key = StatKey(
    device: Int64(device),
    inode: fileID,
    size: Int64(size),
    modified: Int64(modified.tv_sec) * 1_000_000_000 + Int64(modified.tv_nsec),
    mode: UInt16(accessMask & 0o7777)
  )
  return BulkRecord(
    name: name, kind: objectType == VREG.rawValue ? .regular : .link, statKey: key, error: 0,
    length: length)
}

private func load<Value: BitwiseCopyable>(
  _ type: Value.Type,
  from buffer: UnsafeRawBufferPointer,
  at offset: Int,
  end: Int
) -> Value? {
  let size = MemoryLayout<Value>.size
  guard offset >= 0, offset <= end, size <= end - offset,
    offset <= buffer.count, size <= buffer.count - offset,
    let baseAddress = buffer.baseAddress
  else { return nil }
  return baseAddress.advanced(by: offset).loadUnaligned(as: Value.self)
}
