import Foundation

public enum WireCodecError: Error, CustomStringConvertible {
  case invalidUTF8
  case emptyPayload
  case invalidJSON(String)

  public var description: String {
    switch self {
    case .invalidUTF8:
      return "Invalid UTF-8 payload"
    case .emptyPayload:
      return "Empty payload"
    case let .invalidJSON(message):
      return "Invalid JSON payload: \(message)"
    }
  }
}

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
    return try requestDecoder.decode(NotifyRequest.self, from: payloadData)
  } catch {
    throw WireCodecError.invalidJSON(error.localizedDescription)
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
