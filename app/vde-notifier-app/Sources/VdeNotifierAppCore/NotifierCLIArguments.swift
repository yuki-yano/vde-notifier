import Foundation

private let valueOptions: Set<String> = [
  "--mode", "--title", "--message", "--terminal", "--term-bundle-id", "--sound", "--payload", "--log-file",
]

private let booleanOptions: Set<String> = [
  "--codex", "--skip-codex-subagent", "--skip-codex-non-interactive", "--claude",
  "--skip-claude-non-interactive", "--dry-run", "--verbose",
]

public func parseNotifierCLIArguments(
  _ arguments: [String],
  environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> NotifierCLIOptions {
  var options = NotifierCLIOptions()
  var index = 0

  while index < arguments.count {
    let argument = arguments[index]
    if argument == "--" {
      if index + 1 < arguments.count {
        let executable = arguments[index + 1]
        guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw NotifierCLIError.invalidValue(option: "--", value: executable)
        }
        options.forwardCommand = ForwardCommand(
          executable: executable,
          arguments: Array(arguments.dropFirst(index + 2))
        )
      }
      break
    }

    if argument == "-h" || argument == "--help" {
      options.help = true
      index += 1
      continue
    }
    if argument == "-v" || argument == "--version" {
      options.version = true
      index += 1
      continue
    }

    if argument.hasPrefix("--") {
      let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let option = String(parts[0])
      let inlineValue = parts.count == 2 ? String(parts[1]) : nil

      if option.hasPrefix("--no-") {
        let positive = "--" + option.dropFirst("--no-".count)
        guard booleanOptions.contains(String(positive)), inlineValue == nil else {
          throw NotifierCLIError.unknownOption(argument)
        }
        setBooleanOption(String(positive), enabled: false, options: &options)
        index += 1
        continue
      }

      if booleanOptions.contains(option) {
        guard inlineValue == nil else {
          throw NotifierCLIError.invalidValue(option: option, value: inlineValue ?? "")
        }
        setBooleanOption(option, enabled: true, options: &options)
        index += 1
        continue
      }

      guard valueOptions.contains(option) else {
        throw NotifierCLIError.unknownOption(option)
      }

      let value: String
      if let inlineValue {
        value = inlineValue
      } else {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
          throw NotifierCLIError.missingValue(option)
        }
        let candidate = arguments[valueIndex]
        if candidate == "--" || valueOptions.contains(candidate) || booleanOptions.contains(candidate) || candidate == "--help" || candidate == "--version" {
          throw NotifierCLIError.missingValue(option)
        }
        value = candidate
        index = valueIndex
      }
      try setValueOption(option, value: value, options: &options)
      index += 1
      continue
    }

    if argument.hasPrefix("-") {
      throw NotifierCLIError.unknownOption(argument)
    }

    options.positionalArguments.append(argument)
    index += 1
  }

  if options.codex && options.claude {
    throw NotifierCLIError.conflictingOptions("--codex", "--claude")
  }
  if options.logFile == nil {
    options.logFile = nonEmptyString(environment["VDE_NOTIFIER_LOG_FILE"])
  }
  return options
}

private func setBooleanOption(_ option: String, enabled: Bool, options: inout NotifierCLIOptions) {
  switch option {
  case "--codex": options.codex = enabled
  case "--skip-codex-subagent": options.skipCodexSubagent = enabled
  case "--skip-codex-non-interactive": options.skipCodexNonInteractive = enabled
  case "--claude": options.claude = enabled
  case "--skip-claude-non-interactive": options.skipClaudeNonInteractive = enabled
  case "--dry-run": options.dryRun = enabled
  case "--verbose": options.verbose = enabled
  default: break
  }
}

private func setValueOption(_ option: String, value: String, options: inout NotifierCLIOptions) throws {
  switch option {
  case "--mode":
    guard let mode = NotifierCLIMode(rawValue: value) else {
      throw NotifierCLIError.invalidValue(option: option, value: value)
    }
    options.mode = mode
  case "--title": options.title = value
  case "--message": options.message = value
  case "--terminal": options.terminal = value
  case "--term-bundle-id": options.terminalBundleIdentifier = value
  case "--sound": options.sound = nonEmptyString(value)
  case "--payload": options.payload = value
  case "--log-file": options.logFile = nonEmptyString(value)
  default: throw NotifierCLIError.unknownOption(option)
  }
}

public func notifierCLIUsage(programName: String = "vde-notifier") -> String {
  """
  Usage: \(programName) [options]

  Options:
    --mode <notify|focus>                  Mode to run (default: notify)
    --title <string>                       Notification title
    --message <string>                     Notification message
    --terminal <profile>                   Terminal profile (e.g. wezterm, alacritty)
    --term-bundle-id <bundle-id>           Explicit terminal bundle identifier
    --sound <name|None>                    Notification sound
    --codex                                Parse Codex payload
    --skip-codex-subagent                  Skip notification for Codex subagent turns
    --skip-codex-non-interactive           Skip notifications for Codex non-interactive turns
    --claude                               Parse Claude payload
    --skip-claude-non-interactive          Skip notifications for Claude non-interactive payloads
    --dry-run                              Print payload without sending notification
    --verbose                              Print diagnostic JSON logs
    --log-file <path>                      Append diagnostic logs to file
    --payload <base64>                     Focus payload for --mode focus
    -- <command> [args...]                 Run command after notification with forwarded args
    --help, -h                             Show help
    --version, -v                          Show version
  """
}

public func nonEmptyString(_ value: Any?) -> String? {
  guard let value = value as? String else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}
