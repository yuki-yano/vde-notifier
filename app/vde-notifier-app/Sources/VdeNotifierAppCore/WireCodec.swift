import Foundation

public enum WireCodecError: Error, CustomStringConvertible {
  case invalidUTF8
  case emptyPayload
  case invalidJSON(String)
  case invalidRequest(String)
  case unsupportedVersion(Int)

  public var description: String {
    switch self {
    case .invalidUTF8:
      return "Invalid UTF-8 payload"
    case .emptyPayload:
      return "Empty payload"
    case let .invalidJSON(message):
      return "Invalid JSON payload: \(message)"
    case let .invalidRequest(message):
      return "Invalid agent request: \(message)"
    case let .unsupportedVersion(version):
      return "Unsupported agent protocol version: \(version)"
    }
  }
}

private struct RequestHeader: Decodable {
  let version: Int
  let type: String
}

private let maximumTitleCharacters = 1024
private let maximumMessageCharacters = 64 * 1024
private let maximumActionArgumentCount = 512
private let maximumActionArgumentBytes = 512 * 1024

private let requestEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.withoutEscapingSlashes]
  return encoder
}()

private let requestDecoder = JSONDecoder()

public func encodeNotifyRequest(_ request: NotifyRequest) throws -> Data {
  var data = try requestEncoder.encode(request)
  data.append(0x0A)
  return data
}

public func decodeNotifyRequest(_ data: Data) throws -> NotifyRequest {
  let payloadData = try sanitizedPayload(data)
  do {
    let request = try requestDecoder.decode(NotifyRequest.self, from: payloadData)
    try validateNotifyRequest(request)
    return request
  } catch let error as WireCodecError {
    throw error
  } catch {
    throw WireCodecError.invalidJSON(error.localizedDescription)
  }
}

public func encodePingRequest(_ request: PingRequest = PingRequest()) throws -> Data {
  try requestEncoder.encode(request)
}

public func decodeAgentRequest(_ data: Data) throws -> AgentRequest {
  let payloadData = try sanitizedPayload(data)

  do {
    let header = try requestDecoder.decode(RequestHeader.self, from: payloadData)
    guard header.version == agentProtocolVersion else {
      throw WireCodecError.unsupportedVersion(header.version)
    }
    switch header.type {
    case "notify":
      let request = try requestDecoder.decode(NotifyRequest.self, from: payloadData)
      try validateNotifyRequest(request)
      return .notify(request)
    case "ping":
      let request = try requestDecoder.decode(PingRequest.self, from: payloadData)
      guard request.type == "ping" else {
        throw WireCodecError.invalidRequest("Ping request type must be ping")
      }
      return .ping(request)
    default:
      throw WireCodecError.invalidJSON("Unsupported request type: \(header.type)")
    }
  } catch let error as WireCodecError {
    throw error
  } catch {
    throw WireCodecError.invalidJSON(error.localizedDescription)
  }
}

private func validateNotifyRequest(_ request: NotifyRequest) throws {
  guard request.version == agentProtocolVersion else {
    throw WireCodecError.unsupportedVersion(request.version)
  }
  guard request.type == "notify" else {
    throw WireCodecError.invalidRequest("Notify request type must be notify")
  }
  guard UUID(uuidString: request.requestId) != nil else {
    throw WireCodecError.invalidRequest("Request ID must be a UUID")
  }
  guard !request.title.isEmpty, request.title.count <= maximumTitleCharacters else {
    throw WireCodecError.invalidRequest("Title length must be between 1 and \(maximumTitleCharacters) characters")
  }
  guard !request.message.isEmpty, request.message.count <= maximumMessageCharacters else {
    throw WireCodecError.invalidRequest("Message length must be between 1 and \(maximumMessageCharacters) characters")
  }
  guard request.action.executable.hasPrefix("/") else {
    throw WireCodecError.invalidRequest("Action executable must be an absolute path")
  }
  guard request.action.arguments.count <= maximumActionArgumentCount else {
    throw WireCodecError.invalidRequest("Too many action arguments")
  }
  let argumentBytes = request.action.arguments.reduce(0) { $0 + $1.utf8.count }
  guard argumentBytes <= maximumActionArgumentBytes else {
    throw WireCodecError.invalidRequest("Action arguments are too large")
  }
}

public func encodeAgentResponse(_ response: AgentResponse) throws -> Data {
  var data = try requestEncoder.encode(response)
  data.append(0x0A)
  return data
}

public func decodeAgentResponse(_ data: Data) throws -> AgentResponse {
  let payloadData = try sanitizedPayload(data)
  do {
    return try requestDecoder.decode(AgentResponse.self, from: payloadData)
  } catch {
    throw WireCodecError.invalidJSON(error.localizedDescription)
  }
}

private func sanitizedPayload(_ data: Data) throws -> Data {
  guard let text = String(data: data, encoding: .utf8) else {
    throw WireCodecError.invalidUTF8
  }

  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    throw WireCodecError.emptyPayload
  }

  guard let payload = trimmed.data(using: .utf8) else {
    throw WireCodecError.invalidUTF8
  }

  return payload
}
