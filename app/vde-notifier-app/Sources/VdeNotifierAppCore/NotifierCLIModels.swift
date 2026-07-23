import Foundation

public enum NotifierCLIMode: String, Codable, Equatable, Sendable {
  case notify
  case focus
}

public struct NotifierCLIOptions: Equatable, Sendable {
  public var mode: NotifierCLIMode = .notify
  public var title: String?
  public var message: String?
  public var terminal: String?
  public var terminalBundleIdentifier: String?
  public var sound: String?
  public var codex = false
  public var skipCodexSubagent = false
  public var skipCodexNonInteractive = false
  public var claude = false
  public var skipClaudeNonInteractive = false
  public var dryRun = false
  public var verbose = false
  public var logFile: String?
  public var payload: String?
  public var help = false
  public var version = false
  public var positionalArguments: [String] = []
  public var forwardCommand: ForwardCommand?

  public init() {}
}

public struct ForwardCommand: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]

  public init(executable: String, arguments: [String]) {
    self.executable = executable
    self.arguments = arguments
  }
}

public struct AgentContext: Equatable, Sendable {
  public var rawPayload: String?
  public var title: String?
  public var message: String?
  public var sound: String?
  public var threadIdentifier: String?
  public var isTitleGeneration = false
  public var isSubagent = false
  public var isNonInteractive = false

  public init(
    rawPayload: String? = nil,
    title: String? = nil,
    message: String? = nil,
    sound: String? = nil,
    threadIdentifier: String? = nil,
    isTitleGeneration: Bool = false,
    isSubagent: Bool = false,
    isNonInteractive: Bool = false
  ) {
    self.rawPayload = rawPayload
    self.title = title
    self.message = message
    self.sound = sound
    self.threadIdentifier = threadIdentifier
    self.isTitleGeneration = isTitleGeneration
    self.isSubagent = isSubagent
    self.isNonInteractive = isNonInteractive
  }
}

public struct TmuxContext: Codable, Equatable, Sendable {
  public let tmuxBin: String
  public let socketPath: String
  public let clientTTY: String
  public let sessionId: String
  public let sessionName: String
  public let windowId: String
  public let windowIndex: Int
  public let paneId: String
  public let paneIndex: Int
  public let paneCurrentCommand: String

  public init(
    tmuxBin: String,
    socketPath: String,
    clientTTY: String,
    sessionId: String,
    sessionName: String,
    windowId: String,
    windowIndex: Int,
    paneId: String,
    paneIndex: Int,
    paneCurrentCommand: String
  ) {
    self.tmuxBin = tmuxBin
    self.socketPath = socketPath
    self.clientTTY = clientTTY
    self.sessionId = sessionId
    self.sessionName = sessionName
    self.windowId = windowId
    self.windowIndex = windowIndex
    self.paneId = paneId
    self.paneIndex = paneIndex
    self.paneCurrentCommand = paneCurrentCommand
  }
}

public struct HerdrContext: Codable, Equatable, Sendable {
  public let socketPath: String
  public let paneId: String
  public let workspaceId: String
  public let tabId: String
  public let label: String?
  public let agent: String?
  public let title: String?
  public let currentDirectory: String?

  public init(
    socketPath: String,
    paneId: String,
    workspaceId: String,
    tabId: String,
    label: String? = nil,
    agent: String? = nil,
    title: String? = nil,
    currentDirectory: String? = nil
  ) {
    self.socketPath = socketPath
    self.paneId = paneId
    self.workspaceId = workspaceId
    self.tabId = tabId
    self.label = label
    self.agent = agent
    self.title = title
    self.currentDirectory = currentDirectory
  }
}

public enum TerminalProfileSource: String, Codable, Equatable, Sendable {
  case override
  case environment = "env"
  case `default`
}

public struct TerminalProfile: Codable, Equatable, Sendable {
  public let key: String
  public let name: String
  public let bundleId: String
  public let source: TerminalProfileSource

  public init(key: String, name: String, bundleId: String, source: TerminalProfileSource) {
    self.key = key
    self.name = name
    self.bundleId = bundleId
    self.source = source
  }
}

public struct FocusPayload: Codable, Equatable, Sendable {
  public let tmux: TmuxContext?
  public let herdr: HerdrContext?
  public let terminal: TerminalProfile

  public init(tmux: TmuxContext? = nil, herdr: HerdrContext? = nil, terminal: TerminalProfile) {
    self.tmux = tmux
    self.herdr = herdr
    self.terminal = terminal
  }
}

public struct NotificationContent: Equatable, Sendable {
  public let title: String
  public let message: String
  public let sound: String?

  public init(title: String, message: String, sound: String?) {
    self.title = title
    self.message = message
    self.sound = sound
  }
}

public enum NotifierCLIError: Error, Equatable, CustomStringConvertible {
  case unknownOption(String)
  case missingValue(String)
  case invalidValue(option: String, value: String)
  case conflictingOptions(String, String)
  case missingPayload
  case invalidPayload(String)

  public var description: String {
    switch self {
    case let .unknownOption(option):
      return "Unknown option: \(option)"
    case let .missingValue(option):
      return "Option \(option) requires a value."
    case let .invalidValue(option, value):
      return "Invalid value for \(option): \(value)"
    case let .conflictingOptions(lhs, rhs):
      return "Options \(lhs) and \(rhs) cannot be used together."
    case .missingPayload:
      return "Focus payload is required"
    case let .invalidPayload(message):
      return "Invalid focus payload: \(message)"
    }
  }
}
