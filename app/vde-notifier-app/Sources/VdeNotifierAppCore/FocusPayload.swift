import Foundation

public func encodeFocusPayload(_ payload: FocusPayload) throws -> String {
  try JSONEncoder().encode(payload).base64EncodedString()
}

public func decodeFocusPayload(_ encoded: String?) throws -> FocusPayload {
  guard let encoded, !encoded.isEmpty else { throw NotifierCLIError.missingPayload }
  guard let data = Data(base64Encoded: encoded) else {
    throw NotifierCLIError.invalidPayload("base64 decoding failed")
  }
  do {
    return try JSONDecoder().decode(FocusPayload.self, from: data)
  } catch {
    throw NotifierCLIError.invalidPayload(error.localizedDescription)
  }
}

public func shellQuoted(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public func focusCommandDescription(executable: String, arguments: [String]) -> String {
  ([executable] + arguments).map(shellQuoted).joined(separator: " ")
}
