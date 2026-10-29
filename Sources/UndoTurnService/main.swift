import Darwin
import UndoTurnCore

@main enum UndoTurnServiceMain {
  static func main() {
    guard let home = Workspace.defaultHome() else {
      writeStandardError("undoturn-service: no service home is available\n")
      exit(EXIT_FAILURE)
    }
    let server = ServiceServer(home: home)
    do throws(ServiceServerError) {
      if try server.start() {
        server.wait()
      } else {
        writeStandardError("undoturn-service: another instance is already running\n")
      }
    } catch let error {
      writeStandardError("undoturn-service: \(error.message)\n")
      exit(EXIT_FAILURE)
    }
  }
}

private func writeStandardError(_ message: String) {
  message.withCString { bytes in
    _ = Darwin.write(STDERR_FILENO, bytes, strlen(bytes))
  }
}
