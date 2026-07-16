import Darwin
import Foundation
import VdeNotifierAppCore

private let maximumCodexSessionMetadataBytes: UInt64 = 128 * 1024
private let maximumClaudeTranscriptBytes: UInt64 = 1024 * 1024
private let claudeParentProcessScanDepth = 16

func readStandardInput() -> String {
  guard isatty(STDIN_FILENO) == 0 else { return "" }
  return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func loadCodexContext(
  options: NotifierCLIOptions,
  environment: [String: String],
  standardInput: @autoclosure () -> String = readStandardInput()
) throws -> AgentContext? {
  let argumentPayload = options.positionalArguments.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    ?? options.forwardCommand?.arguments.reversed().first(where: isJSONObject)
  let source = argumentPayload
    ?? nonEmptyString(environment["CODEX_NOTIFICATION_PAYLOAD"])
    ?? nonEmptyString(standardInput())
  guard let source else { return nil }
  guard var context = try parseCodexPayload(source, environment: environment) else { return nil }
  if let threadIdentifier = context.threadIdentifier,
     let source = resolveCodexSessionSource(threadIdentifier: threadIdentifier, environment: environment)
  {
    if let value = source as? String {
      context.isSubagent = value.lowercased().hasPrefix("subagent")
      context.isNonInteractive = ["exec", "review"].contains(value.lowercased())
    } else if let value = source as? [String: Any] {
      context.isSubagent = value.keys.contains("subagent") || value.keys.contains("subAgent")
    }
  }
  return context
}

private func isJSONObject(_ source: String) -> Bool {
  guard let data = source.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data)
  else { return false }
  return value is [String: Any]
}

private func resolveCodexSessionSource(threadIdentifier: String, environment: [String: String]) -> Any? {
  guard let home = nonEmptyString(environment["HOME"]) else { return nil }
  let root = URL(fileURLWithPath: home).appendingPathComponent(".codex/sessions", isDirectory: true)
  guard let enumerator = FileManager.default.enumerator(
    at: root,
    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
    options: [.skipsHiddenFiles, .skipsPackageDescendants]
  ) else { return nil }

  for case let fileURL as URL in enumerator {
    guard fileURL.lastPathComponent.hasPrefix("rollout-"),
          fileURL.lastPathComponent.hasSuffix("\(threadIdentifier).jsonl"),
          let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          let line = readFirstLine(fileURL, maximumBytes: maximumCodexSessionMetadataBytes),
          let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = object["payload"] as? [String: Any]
    else { continue }
    return payload["source"]
  }
  return nil
}

private func readFirstLine(_ url: URL, maximumBytes: UInt64) -> String? {
  guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
  defer { try? handle.close() }
  guard let data = try? handle.read(upToCount: Int(maximumBytes)) else { return nil }
  let source = String(decoding: data, as: UTF8.self)
  return nonEmptyString(source.components(separatedBy: .newlines).first)
}

func loadClaudeContext(
  environment: [String: String],
  standardInput: @autoclosure () -> String = readStandardInput(),
  printModeDetected: @autoclosure () -> Bool = detectClaudePrintMode()
) throws -> AgentContext? {
  guard let source = nonEmptyString(standardInput()) else { return nil }
  let payload = try parseJSONObject(source, agent: "Claude")
  guard !payload.isEmpty else { return nil }
  let transcriptPath = payload["transcript_path"] ?? payload["transcriptPath"]
  let transcript = resolveClaudeTranscriptPath(transcriptPath, environment: environment).flatMap(readClaudeTranscript)
  let hook = nonEmptyString(payload["hook_event_name"])
  let shouldInspectProcessChain = hook == "Stop" || hook == "SubagentStop"
  return extractClaudePayloadDetails(
    payload,
    environment: environment,
    transcriptMessage: transcript,
    printModeDetected: shouldInspectProcessChain && printModeDetected()
  )
}

private func resolveClaudeTranscriptPath(_ rawPath: Any?, environment: [String: String]) -> URL? {
  guard let home = nonEmptyString(environment["HOME"]), let input = nonEmptyString(rawPath) else { return nil }
  let expanded = input.hasPrefix("~/") ? URL(fileURLWithPath: home).appendingPathComponent(String(input.dropFirst(2))).path : input
  let target = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
  let bases = [".claude/projects", ".config/claude/projects"].map {
    URL(fileURLWithPath: home).appendingPathComponent($0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
  }
  guard bases.contains(where: { target.path == $0.path || target.path.hasPrefix($0.path + "/") }),
        let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true,
        values.isSymbolicLink != true
  else { return nil }
  return target
}

private func readClaudeTranscript(_ url: URL) -> String? {
  guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
  defer { try? handle.close() }
  guard let size = try? handle.seekToEnd() else { return nil }
  let start = size > maximumClaudeTranscriptBytes ? size - maximumClaudeTranscriptBytes : 0
  do {
    try handle.seek(toOffset: start)
    let data = try handle.readToEnd() ?? Data()
    var lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    for line in lines.reversed() {
      guard let value = nonEmptyString(line),
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? [String: Any]
      else { continue }
      if let role = nonEmptyString(message["role"]), role != "assistant" { continue }
      if let text = extractClaudeMessageText(message) { return text }
    }
  } catch {
    return nil
  }
  return nil
}

private func extractClaudeMessageText(_ message: [String: Any]) -> String? {
  if let text = nonEmptyString(message["text"]) ?? nonEmptyString(message["content"]) { return text }
  if let content = message["content"] as? [Any] {
    for part in content {
      if let text = nonEmptyString(part) { return text }
      if let object = part as? [String: Any], let text = nonEmptyString(object["text"]) { return text }
    }
  }
  return nil
}

func detectClaudePrintMode(
  startPID: Int32 = getppid(),
  maximumDepth: Int = claudeParentProcessScanDepth,
  readProcess: (Int32) -> (parentPID: Int32, command: String)? = readProcessInfo
) -> Bool {
  guard startPID > 1 else { return false }
  var current = startPID
  for _ in 0..<maximumDepth where current > 1 {
    guard let info = readProcess(current) else { return false }
    if isClaudeCommand(info.command) {
      return commandContainsFlag(info.command, flag: "-p") || commandContainsFlag(info.command, flag: "--print")
    }
    guard info.parentPID > 0, info.parentPID != current else { return false }
    current = info.parentPID
  }
  return false
}

private func readProcessInfo(_ pid: Int32) -> (parentPID: Int32, command: String)? {
  guard let parent = try? ProcessRunner.requireSuccess(executable: "/bin/ps", arguments: ["-o", "ppid=", "-p", String(pid)]),
        let command = try? ProcessRunner.requireSuccess(executable: "/bin/ps", arguments: ["-o", "command=", "-p", String(pid)]),
        let parentPID = Int32(parent.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
  else { return nil }
  return (parentPID, command.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func isClaudeCommand(_ command: String) -> Bool {
  guard let token = firstCommandToken(command) else { return false }
  return URL(fileURLWithPath: token).lastPathComponent == "claude"
}

private func firstCommandToken(_ command: String) -> String? {
  let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let first = value.first else { return nil }
  if first == "\"" || first == "'" {
    let remainder = value.dropFirst()
    guard let end = remainder.firstIndex(of: first) else { return nil }
    return String(remainder[..<end])
  }
  return value.split(whereSeparator: \.isWhitespace).first.map(String.init)
}

private func commandContainsFlag(_ command: String, flag: String) -> Bool {
  command.split(whereSeparator: \.isWhitespace).contains(Substring(flag))
}
