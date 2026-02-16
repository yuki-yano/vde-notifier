import Foundation

public struct ActionPayload: Codable, Equatable {
  public let executable: String
  public let arguments: [String]

  public init(executable: String, arguments: [String]) {
    self.executable = executable
    self.arguments = arguments
  }
}

public struct NotifyRequest: Codable, Equatable {
  public let version: Int
  public let type: String
  public let requestId: String
  public let title: String
  public let message: String
  public let sound: String?
  public let action: ActionPayload
  public let source: String?

  public init(
    version: Int = 1,
    type: String = "notify",
    requestId: String,
    title: String,
    message: String,
    sound: String?,
    action: ActionPayload,
    source: String? = "vde-notifier"
  ) {
    self.version = version
    self.type = type
    self.requestId = requestId
    self.title = title
    self.message = message
    self.sound = sound
    self.action = action
    self.source = source
  }

  enum CodingKeys: String, CodingKey {
    case version
    case type
    case requestId = "request_id"
    case title
    case message
    case sound
    case action
    case source
  }
}

public struct AgentResponse: Codable, Equatable {
  public let ok: Bool
  public let requestId: String?
  public let code: String?
  public let message: String?
  public let queuedAt: String?

  public init(
    ok: Bool,
    requestId: String? = nil,
    code: String? = nil,
    message: String? = nil,
    queuedAt: String? = nil
  ) {
    self.ok = ok
    self.requestId = requestId
    self.code = code
    self.message = message
    self.queuedAt = queuedAt
  }

  public static func success(requestId: String, queuedAt: Date = Date()) -> AgentResponse {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return AgentResponse(ok: true, requestId: requestId, queuedAt: formatter.string(from: queuedAt))
  }

  public static func failure(code: String, message: String) -> AgentResponse {
    AgentResponse(ok: false, code: code, message: message)
  }

  enum CodingKeys: String, CodingKey {
    case ok
    case requestId = "request_id"
    case code
    case message
    case queuedAt = "queued_at"
  }
}
