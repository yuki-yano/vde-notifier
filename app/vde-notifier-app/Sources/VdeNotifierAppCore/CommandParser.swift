import Foundation

public struct NotifyCommand: Equatable {
  public let title: String
  public let message: String
  public let sound: String?
  public let actionExecutable: String
  public let actionArguments: [String]

  public init(
    title: String,
    message: String,
    sound: String?,
    actionExecutable: String,
    actionArguments: [String]
  ) {
    self.title = title
    self.message = message
    self.sound = sound
    self.actionExecutable = actionExecutable
    self.actionArguments = actionArguments
  }
}

public enum ParsedCommand: Equatable {
  case notify(NotifyCommand)
  case agentRun
  case agentStart
  case agentStatus
  case doctor
  case help
}

public enum CommandParseError: Error, Equatable, CustomStringConvertible {
  case unknownCommand(String)
  case unknownFlag(String)
  case missingValue(flag: String)
  case missingRequired(flag: String)
  case unexpectedArgument(String)

  public var description: String {
    switch self {
    case let .unknownCommand(value):
      return "Unknown command: \(value)"
    case let .unknownFlag(value):
      return "Unknown option: \(value)"
    case let .missingValue(flag):
      return "Missing value for option: \(flag)"
    case let .missingRequired(flag):
      return "Missing required option: \(flag)"
    case let .unexpectedArgument(value):
      return "Unexpected argument: \(value)"
    }
  }
}

public func parseCommandLine(_ arguments: [String]) throws -> ParsedCommand {
  guard let head = arguments.first else {
    return .agentRun
  }

  switch head {
  case "notify":
    return .notify(try parseNotifyCommand(Array(arguments.dropFirst())))
  case "agent":
    return try parseAgentCommand(Array(arguments.dropFirst()))
  case "doctor":
    guard arguments.count == 1 else {
      throw CommandParseError.unexpectedArgument(arguments.dropFirst().joined(separator: " "))
    }
    return .doctor
  case "--help", "-h", "help":
    return .help
  default:
    throw CommandParseError.unknownCommand(head)
  }
}

private func parseAgentCommand(_ arguments: [String]) throws -> ParsedCommand {
  guard let subcommand = arguments.first else {
    return .agentRun
  }

  if arguments.count > 1 {
    throw CommandParseError.unexpectedArgument(arguments.dropFirst().joined(separator: " "))
  }

  switch subcommand {
  case "run":
    return .agentRun
  case "start":
    return .agentStart
  case "status":
    return .agentStatus
  default:
    throw CommandParseError.unknownCommand("agent \(subcommand)")
  }
}

private func parseNotifyCommand(_ arguments: [String]) throws -> NotifyCommand {
  var title: String?
  var message: String?
  var sound: String?
  var actionExecutable: String?
  var actionArguments: [String] = []

  var index = 0
  while index < arguments.count {
    let option = arguments[index]

    switch option {
    case "--title":
      title = try consumeValue(arguments: arguments, index: &index, option: option)
    case "--message":
      message = try consumeValue(arguments: arguments, index: &index, option: option)
    case "--sound":
      sound = try consumeValue(arguments: arguments, index: &index, option: option)
    case "--action-exec":
      actionExecutable = try consumeValue(arguments: arguments, index: &index, option: option)
    case "--action-arg":
      let argument = try consumeAnyValue(arguments: arguments, index: &index, option: option)
      actionArguments.append(argument)
    case "--help", "-h":
      throw CommandParseError.unexpectedArgument(option)
    default:
      throw CommandParseError.unknownFlag(option)
    }

    index += 1
  }

  guard let resolvedTitle = title, !resolvedTitle.isEmpty else {
    throw CommandParseError.missingRequired(flag: "--title")
  }

  guard let resolvedMessage = message, !resolvedMessage.isEmpty else {
    throw CommandParseError.missingRequired(flag: "--message")
  }

  guard let resolvedActionExecutable = actionExecutable, !resolvedActionExecutable.isEmpty else {
    throw CommandParseError.missingRequired(flag: "--action-exec")
  }

  return NotifyCommand(
    title: resolvedTitle,
    message: resolvedMessage,
    sound: sound,
    actionExecutable: resolvedActionExecutable,
    actionArguments: actionArguments
  )
}

private func consumeValue(arguments: [String], index: inout Int, option: String) throws -> String {
  let next = index + 1
  guard next < arguments.count else {
    throw CommandParseError.missingValue(flag: option)
  }
  let value = arguments[next]
  if value.hasPrefix("--") {
    throw CommandParseError.missingValue(flag: option)
  }
  index = next
  return value
}

private func consumeAnyValue(arguments: [String], index: inout Int, option: String) throws -> String {
  let next = index + 1
  guard next < arguments.count else {
    throw CommandParseError.missingValue(flag: option)
  }
  let value = arguments[next]
  index = next
  return value
}
