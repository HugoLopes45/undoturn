import Testing
import UndoTurnCore

@Suite struct CommandProtectionTests {
  private let cwd = "/work/project"
  private let home = "/Users/tester"

  @Test(arguments: [
    "rm -rf /", "rmdir /", "rm -rf //./", "rm -rf /tmp/..", "rm -rf ~",
    "rm -rf \"$HOME\"", "rm -rf ${HOME}/", "rm -rf /*", "rm -rf \"$HOME\"/*",
    "rm -rf \"$HOME\"/..", "rm -rf /Users",
    "TARGET=/; rm -rf \"$TARGET\"", "export TARGET=/; rm -rf ${TARGET}",
    "TARGET='/Users/tester'; command rm -rf \"$TARGET\"",
    "sudo -u root /bin/rm --recursive --force -- /",
    "sudo --user=root rm -rf /", "sudo -uroot rm -rf /",
    "env --unset=PATH rm -rf \"$HOME\"", "nice -5 rm -rf /",
    "env --chdir=/ rm -rf .", "sudo -D / rm -rf .",
    "/usr/bin/env TARGET=/ sh -c 'rm -rf \"$TARGET\"'",
    "TARGET=/; env TARGET=build NEXT=$TARGET sh -c 'rm -rf \"$NEXT\"'",
    "command -- nohup nice -n 10 rm -rf /", "bash -lc 'rm -rf /'",
    "printf ignored | xargs rm -rf /", "cd /; rm -rf .",
    "TARGET='/ build'; rm -rf $TARGET", "TARGET='/*'; rm -rf $TARGET",
    "TARGET=~; rm -rf \"$TARGET\"", "TARGET=; rm -rf \"$TARGET/\"",
    "rm -rf >&2 /",
  ])
  func refusesKnownRootAndHomeTargets(command: String) {
    let result = CommandProtection.inspect(command: command, cwd: cwd, home: home)
    guard case .refuse = result.decision else {
      Issue.record("Expected refusal: \(command)")
      return
    }
    #expect(!result.requiresCheckpoint)
  }

  @Test(arguments: [
    "rm -rf .git", "rm -f .git/index", "rmdir ../project/.git",
    "command git reset --hard HEAD", "git -C subdirectory clean -fd",
    "git checkout -- .", "git restore --worktree .", "git branch -D old",
  ])
  func requestsNativePermissionForKnownGitDestruction(command: String) {
    let result = CommandProtection.inspect(command: command, cwd: cwd, home: home)
    guard case .requestPermission = result.decision else {
      Issue.record("Expected native permission request: \(command)")
      return
    }
    #expect(result.requiresCheckpoint)
  }

  @Test(arguments: [
    "rm -rf build", "rmdir 'empty directory'", "rm -f -- '-literal'",
    "TARGET=build; rm -rf \"$TARGET\"", "rm -f '$HOME'", "rm -f \"\\$HOME\"",
    "rm -rf build/*.o", "sudo -n env command rm -rf build",
    "TARGET='/*'; rm -f \"$TARGET\"", "TARGET='~'; rm -rf \"$TARGET\"",
    "TARGET=build; env TARGET=/ NEXT=$TARGET sh -c 'rm -rf \"$NEXT\"'",
  ])
  func checkpointsInProjectDeletionWithoutOverridingApprovals(command: String) {
    let result = CommandProtection.inspect(command: command, cwd: cwd, home: home)
    #expect(result.decision == .proceed)
    #expect(result.requiresCheckpoint)
  }

  @Test(arguments: [
    "rm -rf \"$UNKNOWN\"", "rm -rf \"$(choose_target)\"", "rm -rf ${TARGET:-/}",
    "TARGET=$(choose_target); rm -rf \"$TARGET\"", "sh -c \"$SCRIPT\"",
    "printf '%s' build | xargs rm", "cd \"$UNKNOWN\"; rm -rf relative",
    "rm -rf \"$TARGET/\"",
  ])
  func unresolvedPathsRequireAProjectCheckpoint(command: String) {
    let result = CommandProtection.inspect(command: command, cwd: cwd, home: home)
    #expect(result.decision == .proceed)
    #expect(result.requiresCheckpoint)
  }

  @Test(arguments: [
    "python cleanup.py", "./cleanup.sh", "./cat note.txt",
    "printf changed > note.txt", "find . -delete", "sed -i '' 's/a/b/' note.txt",
    "rg --pre ./transform note.txt", "sort -o note.txt input.txt", "uniq input.txt output.txt",
    "cat <<'EOF'\nrm -rf /\nEOF\n",
    "git status", "git diff", "git clean -nd", "git checkout topic", "git add .",
    "git custom-alias",
  ])
  func opaqueOrWritingCommandsRequireAProjectCheckpoint(command: String) {
    let result = CommandProtection.inspect(command: command, cwd: cwd, home: home)
    #expect(result.decision == .proceed)
    #expect(result.requiresCheckpoint)
  }

  @Test(arguments: [
    "printf '%s' 'rm -rf /'", "echo \"literal .git\"", "cat file.txt",
    "find . -name '*.swift'", "sed -n '1,2p' note.txt", "rg --files",
    "sort note.txt", "uniq note.txt",
  ])
  func leavesNormalCommandsAndQuotedDataAlone(command: String) {
    let result = CommandProtection.inspect(command: command, cwd: cwd, home: home)
    #expect(result.decision == .proceed)
    #expect(!result.requiresCheckpoint)
  }
}
