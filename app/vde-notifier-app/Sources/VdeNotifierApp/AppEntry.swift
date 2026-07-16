import AppKit
import Foundation
import UserNotifications
import VdeNotifierAppCore

final class AgentAppDelegate: NSObject, NSApplicationDelegate {
  private let runtime: NotificationAgentRuntime

  init(runtime: NotificationAgentRuntime) {
    self.runtime = runtime
  }

  func applicationDidFinishLaunching(_: Notification) {
    do {
      try runtime.start()
      runtime.primeNotificationAuthorization()
    } catch {
      fputs("vde-notifier-app: \(error)\n", stderr)
      NSApp.terminate(nil)
    }
  }
}

@MainActor
@main
struct VdeNotifierAppMain {
  private static var appDelegateHolder: AgentAppDelegate?

  static func main() {
    do {
      let processArguments = ProcessInfo.processInfo.arguments
      let arguments = Array(processArguments.dropFirst())
      if URL(fileURLWithPath: processArguments[0]).lastPathComponent == "vde-notifier" {
        do {
          exit(try NotifierCLI.run(arguments: arguments))
        } catch {
          fputs("vde-notifier: \(error)\n", stderr)
          if error is NotifierCLIError {
            fputs("\n\(notifierCLIUsage())\n", stderr)
          }
          exit(1)
        }
      }
      let command: ParsedCommand = if arguments.isEmpty && Bundle.main.bundleURL.pathExtension == "app" {
        .agentRun
      } else {
        try parseCommandLine(arguments)
      }
      switch command {
      case let .notify(notify):
        try runNotify(notify)
      case .agentRun:
        try runAgent()
      case .agentStart:
        try runAgentStart()
      case .agentStatus:
        runAgentStatus()
      case .doctor:
        runDoctor()
      case .help:
        printHelp()
      case .version:
        printVersion()
      }
    } catch let error as CommandParseError {
      fputs("vde-notifier-app: \(error.description)\n", stderr)
      exit(2)
    } catch {
      fputs("vde-notifier-app: \(error)\n", stderr)
      exit(1)
    }
  }

  private static func runNotify(_ command: NotifyCommand) throws {
    try sendAgentNotification(
      title: command.title,
      message: command.message,
      sound: command.sound,
      actionExecutable: command.actionExecutable,
      actionArguments: command.actionArguments
    )
  }

  private static func runAgent() throws {
    try prepareRuntimeDirectories()
    let runtime = NotificationAgentRuntime(
      socketPath: AppPaths.socketURL().path,
      actionStoreURL: AppPaths.actionsDirectoryURL(),
      logURL: AppPaths.agentLogURL()
    )

    if Bundle.main.bundleURL.pathExtension == "app" {
      let app = NSApplication.shared
      app.setActivationPolicy(.accessory)
      let delegate = AgentAppDelegate(runtime: runtime)
      Self.appDelegateHolder = delegate
      app.delegate = delegate
      app.run()
      return
    }

    try runtime.start()
    runtime.run()
  }

  private static func runAgentStart() throws {
    try AgentBootstrap.ensureRunning(socketPath: AppPaths.socketURL().path)
  }

  private static func runAgentStatus() {
    let socketPath = AppPaths.socketURL().path
    let status = [
      "running": AgentBootstrap.isRunning(socketPath: socketPath),
      "socket": FileManager.default.fileExists(atPath: socketPath)
    ] as [String: Any]
    printJSON(status)
  }

  private static func runDoctor() {
    let center = UNUserNotificationCenter.current()
    let sem = DispatchSemaphore(value: 0)
    let authorization = LockedValue<UNAuthorizationStatus>(.notDetermined)

    center.getNotificationSettings { settings in
      authorization.set(settings.authorizationStatus)
      sem.signal()
    }
    let authorizationCheckSucceeded = waitForSignal(sem, timeout: 2.0)

    let report: [String: Any] = [
      "running": AgentBootstrap.isRunning(socketPath: AppPaths.socketURL().path),
      "authorization": authorizationCheckSucceeded ? authorizationLabel(authorization.get()) : "unknown",
      "authorization_check": authorizationCheckSucceeded ? "ok" : "timeout",
      "actions_writable": diagnoseActionStoreWriteAccess(at: AppPaths.actionsDirectoryURL()),
      "socket_path": AppPaths.socketURL().path,
      "actions_path": AppPaths.actionsDirectoryURL().path
    ]
    printJSON(report)
  }

  private static func authorizationLabel(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
      return "notDetermined"
    case .denied:
      return "denied"
    case .authorized:
      return "authorized"
    default:
      return "unknown"
    }
  }

  private static func prepareRuntimeDirectories() throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: AppPaths.applicationSupportDirectory(), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: AppPaths.logsDirectory(), withIntermediateDirectories: true)
  }

  private static func printJSON(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8)
    else {
      print("{}")
      return
    }
    print(string)
  }

  private static func printHelp() {
    print(
      """
      vde-notifier-app

      Usage:
        vde-notifier-app notify --title <title> --message <message> --sound <sound|none> --action-exec <path> [--action-arg <arg> ...]
        vde-notifier-app agent run
        vde-notifier-app agent start
        vde-notifier-app agent status
        vde-notifier-app doctor
        vde-notifier-app --version
      """
    )
  }

  private static func printVersion() {
    print(resolveApplicationVersion())
  }
}
