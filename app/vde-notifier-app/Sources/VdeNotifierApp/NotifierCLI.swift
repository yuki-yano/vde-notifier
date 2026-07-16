import Foundation
import VdeNotifierAppCore

enum NotifierCLI {
  static func run(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Int32 {
    let options = try parseNotifierCLIArguments(arguments, environment: environment)
    if options.help {
      print(notifierCLIUsage())
      return 0
    }
    if options.version {
      print(resolveApplicationVersion())
      return 0
    }
    switch options.mode {
    case .notify:
      return try runNotify(options: options, environment: environment)
    case .focus:
      return try runFocus(options: options)
    }
  }

  private static func runNotify(options: NotifierCLIOptions, environment: [String: String]) throws -> Int32 {
    let context = options.claude
      ? try loadClaudeContext(environment: environment)
      : options.codex ? try loadCodexContext(options: options, environment: environment) : nil

    if let reason = notifySkipReason(options: options, context: context) {
      logDiagnostic(options: options, detail: ["stage": "notify", "skipped": true, "reason": reason])
      try runForwardCommand(options: options, context: context, environment: environment)
      return 0
    }

    let tmuxBinary = try resolveExecutable("tmux", environment: environment)
    let tmuxResult = try ProcessRunner.requireSuccess(
      executable: tmuxBinary,
      arguments: tmuxContextArguments(targetPane: environment["TMUX_PANE"])
    )
    let tmux = try parseTmuxContext(output: tmuxResult.standardOutput, tmuxBinary: tmuxBinary)
    let explicitTerminal = options.terminal ?? nonEmptyString(environment["VDE_NOTIFIER_TERMINAL"])
    let terminal = resolveTerminalProfile(
      explicitKey: explicitTerminal,
      bundleOverride: options.terminalBundleIdentifier,
      environment: environment
    )
    let notification = notificationDetails(tmux: tmux, options: options, context: context)
    let payload = FocusPayload(tmux: tmux, terminal: terminal)
    let encodedPayload = try encodeFocusPayload(payload)
    guard let actionExecutable = resolveCurrentExecutablePath() else {
      throw ProcessRunnerError.launch(
        executable: ProcessInfo.processInfo.arguments[0],
        message: "Unable to resolve current executable path"
      )
    }
    var actionArguments = ["--mode", "focus", "--payload", encodedPayload]
    if options.verbose { actionArguments.append("--verbose") }
    if let logFile = options.logFile { actionArguments += ["--log-file", logFile] }

    let detail: [String: Any] = [
      "stage": options.dryRun ? "dry-run" : "notify",
      "tmux": jsonObject(tmux),
      "terminal": jsonObject(terminal),
      "notification": [
        "title": notification.title,
        "message": notification.message,
        "sound": notification.sound ?? NSNull(),
      ] as [String: Any],
      "focus": [
        "payload": encodedPayload,
        "command": focusCommandDescription(executable: actionExecutable, arguments: actionArguments),
      ],
    ]
    logDiagnostic(options: options, detail: detail, standardOutput: options.dryRun)

    if !options.dryRun {
      try sendAgentNotification(
        title: notification.title,
        message: truncateNotificationMessage(notification.message),
        sound: resolvedNotificationSound(notification.sound),
        actionExecutable: actionExecutable,
        actionArguments: actionArguments
      )
    }
    try runForwardCommand(options: options, context: context, environment: environment)
    return 0
  }

  private static func runFocus(options: NotifierCLIOptions) throws -> Int32 {
    let payload = try decodeFocusPayload(options.payload)
    logDiagnostic(options: options, detail: ["stage": "focus", "payload": jsonObject(payload)])
    try focusPane(payload.tmux)
    try activateTerminal(bundleIdentifier: payload.terminal.bundleId)
    return 0
  }

  static func focusPane(_ context: TmuxContext) throws {
    guard context.tmuxBin.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: context.tmuxBin) else {
      throw ProcessRunnerError.launch(executable: context.tmuxBin, message: "tmux path is not an executable absolute path")
    }
    let base = ["-S", context.socketPath]
    _ = try ProcessRunner.requireSuccess(executable: context.tmuxBin, arguments: base + ["has-session", "-t", context.sessionId])
    let windows = try ProcessRunner.requireSuccess(
      executable: context.tmuxBin,
      arguments: base + ["list-windows", "-t", context.sessionId, "-F", "#{window_id}"]
    )
    guard parseTmuxIdentifiers(windows.standardOutput).contains(context.windowId) else {
      throw NotifierCLIError.invalidPayload("tmux window is no longer available: \(context.windowId)")
    }
    let panes = try ProcessRunner.requireSuccess(
      executable: context.tmuxBin,
      arguments: base + ["list-panes", "-t", context.windowId, "-F", "#{pane_id}"]
    )
    guard parseTmuxIdentifiers(panes.standardOutput).contains(context.paneId) else {
      throw NotifierCLIError.invalidPayload("tmux pane is no longer available: \(context.paneId)")
    }
    guard !context.clientTTY.isEmpty else {
      throw NotifierCLIError.invalidPayload("tmux client TTY is unavailable")
    }
    let clients = try ProcessRunner.requireSuccess(
      executable: context.tmuxBin,
      arguments: base + ["list-clients", "-F", "#{client_tty}"]
    )
    guard parseTmuxIdentifiers(clients.standardOutput).contains(context.clientTTY) else {
      throw NotifierCLIError.invalidPayload("tmux client is no longer available: \(context.clientTTY)")
    }
    _ = try ProcessRunner.requireSuccess(
      executable: context.tmuxBin,
      arguments: base + ["switch-client", "-c", context.clientTTY, "-t", context.sessionId]
    )
    _ = try ProcessRunner.requireSuccess(executable: context.tmuxBin, arguments: base + ["select-window", "-t", context.windowId])
    _ = try ProcessRunner.requireSuccess(executable: context.tmuxBin, arguments: base + ["select-pane", "-t", context.paneId])
  }

  private static func activateTerminal(bundleIdentifier: String) throws {
    let quoted = appleScriptQuoted(bundleIdentifier)
    let primarySucceeded = (try? ProcessRunner.requireSuccess(
      executable: "/usr/bin/osascript",
      arguments: ["-e", "tell application id \(quoted) to activate"]
    )) != nil
    do {
      _ = try ProcessRunner.requireSuccess(
        executable: "/usr/bin/osascript",
        arguments: ["-e", terminalFrontmostScript(bundleIdentifier: bundleIdentifier)]
      )
    } catch {
      if !primarySucceeded { throw error }
    }
  }

  private static func runForwardCommand(
    options: NotifierCLIOptions,
    context: AgentContext?,
    environment: [String: String]
  ) throws {
    guard let command = options.forwardCommand else { return }
    var arguments = command.arguments
    if options.codex, let payload = context?.rawPayload, !arguments.contains(payload) { arguments.append(payload) }
    logDiagnostic(options: options, detail: ["stage": "forward", "executable": command.executable, "args": arguments])
    let executable = command.executable.hasPrefix("/")
      ? command.executable
      : try resolveExecutable(command.executable, environment: environment)
    try ProcessRunner.inherit(executable: executable, arguments: arguments)
  }
}

func sendAgentNotification(
  title: String,
  message: String,
  sound: String?,
  actionExecutable: String,
  actionArguments: [String]
) throws {
  let socketPath = AppPaths.socketURL().path
  try AgentBootstrap.ensureRunning(socketPath: socketPath)
  let request = NotifyRequest(
    requestId: UUID().uuidString.lowercased(),
    title: title,
    message: message,
    sound: sound,
    action: ActionPayload(executable: actionExecutable, arguments: actionArguments),
    source: "vde-notifier"
  )
  let response = try AgentClient(socketPath: socketPath).send(request)
  guard response.ok else {
    throw ClientError.notificationFailed(
      code: response.code ?? "unknown",
      message: response.message ?? "unknown error"
    )
  }
}

private func jsonObject<T: Encodable>(_ value: T) -> Any {
  guard let data = try? JSONEncoder().encode(value),
        let object = try? JSONSerialization.jsonObject(with: data)
  else { return NSNull() }
  return object
}

private func logDiagnostic(options: NotifierCLIOptions, detail: Any, standardOutput: Bool = false) {
  guard JSONSerialization.isValidJSONObject(detail),
        let data = try? JSONSerialization.data(withJSONObject: detail, options: [.prettyPrinted, .sortedKeys]),
        let text = String(data: data, encoding: .utf8)
  else { return }
  if options.verbose {
    if standardOutput { print(text) } else { fputs(text + "\n", stderr) }
  }
  guard let logFile = options.logFile else { return }
  do {
    let url = URL(fileURLWithPath: logFile)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let entry: [String: Any] = ["timestamp": formatter.string(from: Date()), "detail": detail]
    let entryData = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: entryData + Data([0x0A]))
  } catch {
    // Diagnostics must never change command behavior.
  }
}

func resolveApplicationVersion() -> String {
  if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty {
    return version
  }
  if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !version.isEmpty {
    return version
  }
  return "0.0.0"
}
