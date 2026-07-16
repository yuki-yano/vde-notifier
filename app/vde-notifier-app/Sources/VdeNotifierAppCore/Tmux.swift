import Foundation

public let tmuxFormat = [
  "#{socket_path}", "#{client_tty}", "#{session_id}", "#{session_name}", "#{window_id}", "#{window_index}",
  "#{pane_id}", "#{pane_index}", "#{pane_current_command}",
].joined(separator: "\n")

public func tmuxContextArguments(targetPane: String?) -> [String] {
  var arguments = ["display-message", "-p"]
  if let target = nonEmptyString(targetPane) { arguments += ["-t", target] }
  arguments.append(tmuxFormat)
  return arguments
}

public func parseTmuxContext(output: String, tmuxBinary: String) throws -> TmuxContext {
  var lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
  while lines.count > 9 && lines.last == "" { lines.removeLast() }
  guard lines.count == 9 else {
    throw NotifierCLIError.invalidPayload("Unexpected tmux response while collecting pane metadata")
  }
  guard let windowIndex = Int(lines[5]), lines[5].allSatisfy(\.isNumber) else {
    throw NotifierCLIError.invalidPayload("Failed to parse window index as number: \(lines[5])")
  }
  guard let paneIndex = Int(lines[7]), lines[7].allSatisfy(\.isNumber) else {
    throw NotifierCLIError.invalidPayload("Failed to parse pane index as number: \(lines[7])")
  }
  return TmuxContext(
    tmuxBin: tmuxBinary,
    socketPath: lines[0],
    clientTTY: lines[1],
    sessionId: lines[2],
    sessionName: lines[3],
    windowId: lines[4],
    windowIndex: windowIndex,
    paneId: lines[6],
    paneIndex: paneIndex,
    paneCurrentCommand: lines[8]
  )
}

public func parseTmuxIdentifiers(_ output: String) -> Set<String> {
  Set(output.components(separatedBy: .newlines).compactMap(nonEmptyString))
}

public func truncateNotificationMessage(_ message: String, maximumLength: Int = 100) -> String {
  let normalized = message.hasPrefix("-") ? " " + message : message
  return String(normalized.prefix(maximumLength))
}

public func resolvedNotificationSound(_ sound: String?) -> String {
  let value = (sound ?? "Glass").trimmingCharacters(in: .whitespacesAndNewlines)
  return value.isEmpty || value.lowercased() == "none" ? "none" : value
}
