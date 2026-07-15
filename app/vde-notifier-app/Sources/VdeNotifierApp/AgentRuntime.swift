import Foundation
@preconcurrency import UserNotifications
import VdeNotifierAppCore

private struct StoredAction: Codable {
  let executable: String
  let arguments: [String]
  let createdAt: String
}

enum ActionStoreError: Error, CustomStringConvertible {
  case duplicateRequestId(String)
  case invalidRequestId(String)

  var description: String {
    switch self {
    case let .duplicateRequestId(requestId):
      return "Action already exists for request ID: \(requestId)"
    case let .invalidRequestId(requestId):
      return "Invalid action request ID: \(requestId)"
    }
  }
}

final class ActionStore: @unchecked Sendable {
  private let directoryURL: URL
  private let queue = DispatchQueue(label: "com.yuki-yano.vde-notifier-app.action-store")
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private static let actionRetentionInterval: TimeInterval = 60 * 60 * 24 * 7
  private let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  init(directoryURL: URL) {
    self.directoryURL = directoryURL
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  func save(requestId: String, action: ActionPayload) throws {
    try queue.sync {
      let fileURL = try actionURL(requestId: requestId)
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      guard !FileManager.default.fileExists(atPath: fileURL.path) else {
        throw ActionStoreError.duplicateRequestId(requestId)
      }
      let stored = StoredAction(
        executable: action.executable,
        arguments: action.arguments,
        createdAt: iso8601Now()
      )
      let data = try encoder.encode(stored)
      try data.write(to: fileURL, options: .atomic)
    }
  }

  func take(requestId: String) throws -> ActionPayload? {
    try queue.sync {
      let fileURL = try actionURL(requestId: requestId)
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return nil
      }
      let stored = try decoder.decode(StoredAction.self, from: Data(contentsOf: fileURL))
      try FileManager.default.removeItem(at: fileURL)
      return ActionPayload(executable: stored.executable, arguments: stored.arguments)
    }
  }

  func remove(requestId: String) throws {
    try queue.sync {
      let fileURL = try actionURL(requestId: requestId)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        try FileManager.default.removeItem(at: fileURL)
      }
    }
  }

  func pruneExpired() throws {
    try queue.sync {
      guard FileManager.default.fileExists(atPath: directoryURL.path) else {
        return
      }
      let threshold = Date().addingTimeInterval(-Self.actionRetentionInterval)
      let files = try FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
      for fileURL in files where fileURL.pathExtension == "json" {
        let modificationDate = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        if let modificationDate, modificationDate < threshold {
          try FileManager.default.removeItem(at: fileURL)
        }
      }
    }
  }

  private func iso8601Now() -> String {
    timestampFormatter.string(from: Date())
  }

  private func actionURL(requestId: String) throws -> URL {
    guard let uuid = UUID(uuidString: requestId) else {
      throw ActionStoreError.invalidRequestId(requestId)
    }
    return directoryURL.appendingPathComponent("\(uuid.uuidString.lowercased()).json", isDirectory: false)
  }
}

final class NotificationAgentRuntime: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private let socketPath: String
  private let actionStore: ActionStore
  private let logURL: URL
  private let logQueue = DispatchQueue(label: "com.yuki-yano.vde-notifier-app.agent-log")
  private var serverFD: Int32 = -1
  private var lockFD: Int32 = -1
  private let serverQueue = DispatchQueue(label: "com.yuki-yano.vde-notifier-app.agent-server")
  private let clientQueue = DispatchQueue(
    label: "com.yuki-yano.vde-notifier-app.agent-clients",
    attributes: .concurrent
  )

  private static let categoryIdentifier = "com.yuki-yano.vde-notifier-app.focus"
  private static let actionIdentifier = "focus-return"

  init(socketPath: String, actionStoreURL: URL, logURL: URL) {
    self.socketPath = socketPath
    actionStore = ActionStore(directoryURL: actionStoreURL)
    self.logURL = logURL
    super.init()
  }

  func start() throws {
    center.delegate = self
    registerNotificationCategory()
    try actionStore.pruneExpired()
    lockFD = try acquireAgentLock(path: "\(socketPath).lock")
    do {
      if FileManager.default.fileExists(atPath: socketPath) {
        if AgentBootstrap.isRunning(socketPath: socketPath) {
          throw UnixSocketError.lockUnavailable("\(socketPath).lock")
        }
        try removeOwnedStaleSocket(path: socketPath)
      }
      serverFD = try makeListeningUnixSocket(path: socketPath)
    } catch {
      Darwin.close(lockFD)
      lockFD = -1
      throw error
    }
    serverQueue.async { [weak self] in
      self?.acceptLoop()
    }
  }

  func stop() {
    if serverFD >= 0 {
      Darwin.close(serverFD)
      serverFD = -1
    }
    unlink(socketPath)
    if lockFD >= 0 {
      Darwin.close(lockFD)
      lockFD = -1
    }
  }

  @MainActor
  func primeNotificationAuthorization() {
    center.getNotificationSettings { [weak self] settings in
      if settings.authorizationStatus == .notDetermined {
        self?.center.requestAuthorization(options: [.alert, .sound]) { _, _ in
          // No-op. The prompt side effect is enough here.
        }
      }
    }
  }

  func run() -> Never {
    RunLoop.main.run()
    fatalError("Unreachable")
  }

  private func acceptLoop() {
    acceptClients(on: serverFD, clientQueue: clientQueue) { [weak self] clientFD in
      self?.handleClient(clientFD: clientFD)
    }
  }

  private func handleClient(clientFD: Int32) {
    defer { Darwin.close(clientFD) }
    setNoSIGPIPE(on: clientFD)

    do {
      try setSocketTimeout(on: clientFD, seconds: 2.0)
      let inputData = try readFrame(from: clientFD)
      if inputData.isEmpty {
        return
      }
      let request = try decodeAgentRequest(inputData)
      let response: AgentResponse
      switch request {
      case let .notify(notifyRequest):
        response = try handleNotifyRequest(notifyRequest)
      case .ping:
        response = .pong()
      }
      let responseData = try encodeAgentResponse(response)
      try writeFrame(responseData, to: clientFD)
    } catch {
      let code = error is WireCodecError ? "invalid_protocol" : "bad_request"
      let failure = AgentResponse.failure(code: code, message: String(describing: error))
      do {
        let responseData = try encodeAgentResponse(failure)
        try writeFrame(responseData, to: clientFD)
      } catch {
        // No-op: client has likely already disconnected.
      }
    }
  }

  private func handleNotifyRequest(_ request: NotifyRequest) throws -> AgentResponse {
    guard isAuthorizedForNotifications() else {
      return AgentResponse.failure(code: "permission_denied", message: "Notification permission is denied")
    }

    if !request.action.executable.hasPrefix("/") {
      return AgentResponse.failure(code: "invalid_action", message: "Action executable must be an absolute path")
    }

    let requestId = request.requestId
    try actionStore.save(requestId: requestId, action: request.action)

    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.message
    content.userInfo = ["request_id": requestId]
    content.categoryIdentifier = Self.categoryIdentifier

    playSound(request.sound)

    let sem = DispatchSemaphore(value: 0)
    let enqueueError = LockedValue<Error?>(nil)

    let notification = UNNotificationRequest(identifier: requestId, content: content, trigger: nil)
    center.add(notification) { error in
      enqueueError.set(error)
      sem.signal()
    }
    sem.wait()

    if let enqueueError = enqueueError.get() {
      try? actionStore.remove(requestId: requestId)
      return AgentResponse.failure(code: "enqueue_failed", message: enqueueError.localizedDescription)
    }

    return AgentResponse.success(requestId: requestId)
  }

  private func isAuthorizedForNotifications() -> Bool {
    let status = notificationAuthorizationStatus()
    if status == .authorized {
      return true
    }
    if status != .notDetermined {
      return false
    }

    let sem = DispatchSemaphore(value: 0)
    let granted = LockedValue(false)
    DispatchQueue.main.async { [center] in
      center.requestAuthorization(options: [.alert, .sound]) { isGranted, _ in
        granted.set(isGranted)
        sem.signal()
      }
    }
    sem.wait()
    return granted.get()
  }

  func notificationAuthorizationStatus() -> UNAuthorizationStatus {
    let sem = DispatchSemaphore(value: 0)
    let status = LockedValue<UNAuthorizationStatus>(.notDetermined)
    center.getNotificationSettings { settings in
      status.set(settings.authorizationStatus)
      sem.signal()
    }
    sem.wait()
    return status.get()
  }

  private func registerNotificationCategory() {
    let focusAction = UNNotificationAction(
      identifier: Self.actionIdentifier,
      title: "Return to pane",
      options: []
    )
    let category = UNNotificationCategory(
      identifier: Self.categoryIdentifier,
      actions: [focusAction],
      intentIdentifiers: [],
      options: [.customDismissAction]
    )
    center.setNotificationCategories([category])
  }

  private func playSound(_ sound: String?) {
    let candidate = (sound ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if candidate.isEmpty || candidate.lowercased() == "none" {
      return
    }

    let resource: String
    if candidate.contains("/") || candidate.contains(".") {
      resource = candidate
    } else {
      resource = "/System/Library/Sounds/\(candidate).aiff"
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    process.arguments = [resource]
    try? process.run()
  }

  private func runAction(requestId: String) {
    do {
      guard let action = try actionStore.take(requestId: requestId) else {
        return
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: action.executable)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
            FileManager.default.isExecutableFile(atPath: action.executable)
      else {
        throw CocoaError(.fileNoSuchFile)
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: action.executable)
      process.arguments = action.arguments
      try process.run()
    } catch {
      appendAgentLog(event: "action_failed", requestId: requestId, error: error)
    }
  }

  private func appendAgentLog(event: String, requestId: String, error: Error) {
    let entry: [String: String] = [
      "timestamp": ISO8601DateFormatter().string(from: Date()),
      "event": event,
      "request_id": requestId,
      "error": String(describing: error),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
      return
    }
    logQueue.sync {
      do {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
          _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data([0x0A]))
        try handle.close()
      } catch {
        // Logging must not terminate the notification agent.
      }
    }
  }

  func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent _: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer { completionHandler() }

    let requestId = response.notification.request.identifier
    if response.actionIdentifier == UNNotificationDismissActionIdentifier {
      try? actionStore.remove(requestId: requestId)
      return
    }

    if response.actionIdentifier != Self.actionIdentifier &&
      response.actionIdentifier != UNNotificationDefaultActionIdentifier
    {
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.runAction(requestId: requestId)
    }
  }
}

extension NotificationAgentRuntime: @unchecked Sendable {}
