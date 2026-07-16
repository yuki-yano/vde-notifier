import CoreFoundation
import Foundation

public enum AgentPayloadError: Error, Equatable, CustomStringConvertible {
  case invalidJSON(agent: String, message: String)

  public var description: String {
    switch self {
    case let .invalidJSON(agent, message):
      return "Failed to parse \(agent) payload JSON: \(message)"
    }
  }
}

public func defaultAgentTitle(agent: String, currentDirectory: String = FileManager.default.currentDirectoryPath) -> String {
  let repository = URL(fileURLWithPath: currentDirectory).lastPathComponent
  let displayName = repository.isEmpty || repository == "/" ? "Repository" : repository
  return agent == "codex" ? "Codex: \(displayName)" : "Claude: \(displayName)"
}

public func parseJSONObject(_ source: String, agent: String) throws -> [String: Any] {
  do {
    let value = try JSONSerialization.jsonObject(with: Data(source.utf8))
    guard let object = value as? [String: Any] else { return [:] }
    return object
  } catch {
    throw AgentPayloadError.invalidJSON(agent: agent, message: error.localizedDescription)
  }
}

public func extractAgentMessage(_ payload: [String: Any]) -> String? {
  if let value = nonEmptyString(payload["last-assistant-message"]) { return value }
  if let value = nonEmptyString(payload["last_agent_message"]) { return value }
  if let value = nonEmptyString(payload["message"]) { return value }

  if let messages = payload["messages"] as? [Any] {
    for case let entry as [String: Any] in messages.reversed() where nonEmptyString(entry["role"]) == "assistant" {
      if let value = nonEmptyString(entry["content"]) { return value }
      if let parts = entry["content"] as? [Any] {
        for case let part as [String: Any] in parts {
          if let value = nonEmptyString(part["text"]) { return value }
        }
      }
    }
  }

  if let transcript = payload["transcript"] as? [String: Any],
     let message = transcript["message"] as? [String: Any],
     let content = message["content"] as? [Any],
     let last = content.last as? [String: Any]
  {
    return nonEmptyString(last["text"])
  }
  return nil
}

public func resolveAgentSound(_ payload: [String: Any], environment: [String: String]) -> String? {
  let raw = payload.keys.contains("sound") ? payload["sound"] : environment["CODEX_NOTIFICATION_SOUND"]
  guard let raw, !(raw is NSNull) else { return nil }
  if let value = raw as? NSNumber {
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "Glass" : "None" }
    return value.doubleValue == 0 ? "None" : nil
  }
  guard let value = nonEmptyString(raw) else { return nil }
  switch value.lowercased() {
  case "none", "false": return "None"
  case "true", "default", "glass": return "Glass"
  default:
    if value.contains("/") {
      let name = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
      return name.isEmpty ? "Glass" : name
    }
    return value
  }
}

public func isCodexTitleGenerationPayload(_ payload: [String: Any]) -> Bool {
  guard nonEmptyString(payload["type"]) == "agent-turn-complete",
        let message = nonEmptyString(payload["last-assistant-message"]),
        let data = message.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return false }
  return object.count == 1 && nonEmptyString(object["title"]) != nil
}

public func extractCodexThreadIdentifier(_ payload: [String: Any]) -> String? {
  for key in ["thread-id", "thread_id", "threadId"] {
    guard let value = nonEmptyString(payload[key]) else { continue }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    if codexThreadIdentifierRegex?.firstMatch(in: value, range: range) != nil { return value }
  }
  return nil
}

private let codexThreadIdentifierRegex = try? NSRegularExpression(
  pattern: "^[0-9a-f-]{16,128}$",
  options: [.caseInsensitive]
)

public func parseCodexPayload(
  _ source: String,
  currentDirectory: String = FileManager.default.currentDirectoryPath,
  environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> AgentContext? {
  let payload = try parseJSONObject(source, agent: "Codex")
  guard !payload.isEmpty else { return nil }
  return AgentContext(
    rawPayload: source,
    title: defaultAgentTitle(agent: "codex", currentDirectory: currentDirectory),
    message: extractAgentMessage(payload),
    sound: resolveAgentSound(payload, environment: environment),
    threadIdentifier: extractCodexThreadIdentifier(payload),
    isTitleGeneration: isCodexTitleGenerationPayload(payload)
  )
}

public func extractClaudePayloadDetails(
  _ payload: [String: Any],
  currentDirectory: String = FileManager.default.currentDirectoryPath,
  environment: [String: String] = ProcessInfo.processInfo.environment,
  transcriptMessage: String? = nil,
  printModeDetected: Bool = false
) -> AgentContext {
  let title = nonEmptyString(payload["notification_title"])
    ?? nonEmptyString(payload["notification-title"])
    ?? nonEmptyString(payload["title"])
    ?? defaultAgentTitle(agent: "claude", currentDirectory: currentDirectory)
  let message = nonEmptyString(payload["notification_message"])
    ?? nonEmptyString(payload["notification-message"])
    ?? nonEmptyString(payload["result"])
    ?? extractAgentMessage(payload)
    ?? transcriptMessage
  let type = nonEmptyString(payload["type"])
  let hook = nonEmptyString(payload["hook_event_name"])
  let isResult = type == "result" && (
    nonEmptyString(payload["subtype"]) != nil || payload.keys.contains("result") || payload["total_cost_usd"] is NSNumber
  )
  let isPrintHook = (hook == "Stop" || hook == "SubagentStop") && printModeDetected
  return AgentContext(
    title: title,
    message: message,
    sound: resolveAgentSound(payload, environment: environment),
    isNonInteractive: isResult || isPrintHook
  )
}

public func notificationDetails(
  tmux: TmuxContext,
  options: NotifierCLIOptions,
  context: AgentContext?,
  currentDirectory: String = FileManager.default.currentDirectoryPath
) -> NotificationContent {
  let fallbackTitle = "[\(tmux.sessionName)] \(tmux.windowIndex).\(tmux.paneIndex) (\(tmux.paneId))"
  let fallbackMessage = "cmd: \(tmux.paneCurrentCommand) | tty: \(tmux.clientTTY)"
  let agentTitle = options.codex
    ? defaultAgentTitle(agent: "codex", currentDirectory: currentDirectory)
    : options.claude ? defaultAgentTitle(agent: "claude", currentDirectory: currentDirectory) : nil
  let title = nonEmptyString(options.title) ?? nonEmptyString(context?.title) ?? agentTitle ?? fallbackTitle
  let message = nonEmptyString(options.message) ?? nonEmptyString(context?.message) ?? fallbackMessage
  return NotificationContent(title: title, message: message, sound: options.sound ?? context?.sound)
}

public func notifySkipReason(options: NotifierCLIOptions, context: AgentContext?) -> String? {
  if options.codex && context?.isTitleGeneration == true { return "codex-title-generation" }
  if options.codex && options.skipCodexSubagent && context?.isSubagent == true { return "codex-subagent" }
  if options.codex && options.skipCodexNonInteractive && context?.isNonInteractive == true { return "codex-non-interactive" }
  if options.claude && options.skipClaudeNonInteractive && context?.isNonInteractive == true { return "claude-non-interactive" }
  return nil
}
