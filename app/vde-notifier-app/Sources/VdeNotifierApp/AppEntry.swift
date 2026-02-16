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
      let command = try parseCommandLine(Array(CommandLine.arguments.dropFirst()))
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
    let socketPath = AppPaths.socketURL().path
    try AgentBootstrap.ensureRunning(socketPath: socketPath)

    let request = NotifyRequest(
      requestId: UUID().uuidString.lowercased(),
      title: command.title,
      message: command.message,
      sound: command.sound,
      action: ActionPayload(
        executable: command.actionExecutable,
        arguments: command.actionArguments
      ),
      source: "vde-notifier"
    )

    let client = AgentClient(socketPath: socketPath)
    let response = try client.send(request)

    if response.ok {
      return
    }

    throw ClientError.notificationFailed(
      code: response.code ?? "unknown",
      message: response.message ?? "unknown error"
    )
  }

  private static func runAgent() throws {
    try prepareRuntimeDirectories()
    let runtime = NotificationAgentRuntime(
      socketPath: AppPaths.socketURL().path,
      actionStoreURL: AppPaths.actionsURL()
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
    let status = [
      "running": socketExistsAndReachable(path: AppPaths.socketURL().path),
      "socket": true
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
    sem.wait()

    let report: [String: Any] = [
      "running": socketExistsAndReachable(path: AppPaths.socketURL().path),
      "authorization": authorizationLabel(authorization.get()),
      "socket_path": AppPaths.socketURL().path,
      "actions_path": AppPaths.actionsURL().path
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
      """
    )
  }
}
