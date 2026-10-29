import Darwin

/// What changed since the last answer, from the optional service.
public enum ChangeHint: Equatable, Sendable {
  case full
  case paths([String])
}

/// One service answer and the token that must be presented to request its successor.
public struct ServiceAnswer: Equatable, Sendable {
  public let token: String
  public let hint: ChangeHint

  public init(token: String, hint: ChangeHint) {
    self.token = token
    self.hint = hint
  }
}
