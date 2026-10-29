import Darwin
import Testing
import UndoTurnCore

@Suite struct WorkspaceTests {
  @Test func identifierIsTheFirst32HexCharactersOfTheRootSHA256() {
    // printf '/private/tmp/project' | shasum -a 256
    #expect(
      Workspace.identifier(forRoot: "/private/tmp/project") == "1481461ff257ca147524d483f9491410")
  }

  @Test func openCreatesThePrivateLayoutAndRecordsTheRoot() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let root = temporary.path + "/project"
    try makeDirectories(root)

    let workspace = try Workspace.open(root: root, home: home)

    #expect(workspace.root == root)
    #expect(workspace.directory == home + "/workspaces/" + Workspace.identifier(forRoot: root))
    #expect(permissions(home) == 0o700)
    #expect(permissions(home + "/workspaces") == 0o700)
    #expect(permissions(workspace.directory) == 0o700)
    #expect(permissions(workspace.directory + "/objects") == 0o700)
    #expect(permissions(workspace.directory + "/root") == 0o600)
    #expect(try Workspace.registered(home: home).map(\.root) == [root])
  }

  @Test func resolvePrefersARegisteredWorkspaceThenTheNearestGitAncestorThenTheFolder() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let user = temporary.path + "/user"
    let repository = user + "/repository"
    try makeDirectories(repository + "/.git")
    try makeDirectories(repository + "/packages/application-like")
    try makeDirectories(repository + "/packages/app/src")
    try makeDirectories(user + "/loose/inner")

    #expect(
      try Workspace.resolve(cwd: repository + "/packages/app/src", home: home, userHome: user).root
        == repository)
    #expect(
      try Workspace.resolve(cwd: user + "/loose/inner", home: home, userHome: user).root == user
        + "/loose/inner")

    _ = try Workspace.open(root: repository + "/packages/app", home: home)
    #expect(
      try Workspace.resolve(cwd: repository + "/packages/app/src", home: home, userHome: user).root
        == repository + "/packages/app")
    #expect(
      try Workspace.resolve(
        cwd: repository + "/packages/application-like", home: home, userHome: user
      ).root
        == repository)
  }

  @Test func resolveRefusesTheFilesystemRootAndTheUserHomeButNotFoldersBelowAHomeRepository() throws
  {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let user = temporary.path + "/user"
    try makeDirectories(user + "/.git")
    try makeDirectories(user + "/code/notes")

    #expect(throws: WorkspaceError.refusedRoot("/")) {
      try Workspace.resolve(cwd: "/", home: home, userHome: user)
    }
    #expect(throws: WorkspaceError.refusedRoot(user)) {
      try Workspace.resolve(cwd: user, home: home, userHome: user)
    }
    #expect(
      try Workspace.resolve(cwd: user + "/code/notes", home: home, userHome: user).root == user
        + "/code/notes")
  }
  @Test func refusesBroadRootsAndHomeDirectChildFallbacksButAcceptsGitRoot() throws {
    let temporary = try TemporaryDirectory()
    let broad = temporary.path + "/Users"
    let user = broad + "/fake"
    let home = user + "/Library/Application Support/UndoTurn"
    try makeDirectories(user + "/Library")
    try makeDirectories(user + "/Desktop/project")
    try makeDirectories(user + "/Desktop/.git")
    try makeDirectories(user + "/Documents")
    try makeDirectories(home + "/inner")

    #expect(throws: WorkspaceError.refusedRoot(broad)) {
      try Workspace.resolve(cwd: broad, home: home, userHome: user)
    }
    #expect(throws: WorkspaceError.refusedRoot(user + "/Library")) {
      try Workspace.resolve(cwd: user + "/Library", home: home, userHome: user)
    }
    #expect(throws: WorkspaceError.refusedRoot(user + "/Documents")) {
      try Workspace.resolve(cwd: user + "/Documents", home: home, userHome: user)
    }
    #expect(throws: WorkspaceError.refusedRoot(home + "/inner")) {
      try Workspace.resolve(cwd: home + "/inner", home: home, userHome: user)
    }
    #expect(
      try Workspace.resolve(cwd: user + "/Desktop/project", home: home, userHome: user).root
        == user + "/Desktop")
  }

  @Test func skipsRegisteredRootsContainingUndoTurnHome() throws {
    let temporary = try TemporaryDirectory()
    let user = temporary.path + "/user"
    let home = user + "/Library/Application Support/UndoTurn"
    try makeDirectories(user + "/Library/project")
    _ = try Workspace.open(root: user + "/Library", home: home)
    let result = try Workspace.resolve(
      cwd: user + "/Library/project", home: home, userHome: user)
    #expect(result.root == user + "/Library/project")
  }
}

private func makeDirectories(_ path: String) throws(SystemError) {
  var prefix = ""
  for component in path.split(separator: "/") {
    prefix += "/" + component
    guard mkdir(prefix, 0o755) == 0 || errno == EEXIST else {
      throw SystemError(operation: "mkdir", path: prefix, code: errno)
    }
  }
}

private func permissions(_ path: String) -> mode_t {
  var info = stat()
  guard lstat(path, &info) == 0 else { return 0 }
  return info.st_mode & 0o777
}
