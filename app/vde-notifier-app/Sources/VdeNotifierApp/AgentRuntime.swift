import Foundation
import UserNotifications
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

enum NotificationAgentError: Error, CustomStringConvertible {
  case operationTimedOut(String)

  var description: String {
    switch self {
    case let .operationTimedOut(operation):
      return "Notification operation timed out: \(operation)"
    }
  }
}

func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
  let boundedTimeout = min(max(timeout, 0.001), 60 * 60)
  let nanoseconds = Int((boundedTimeout * 1_000_000_000).rounded(.up))
  return semaphore.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success
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
      let temporaryURL = directoryURL.appendingPathComponent(".\(requestId).\(UUID().uuidString).tmp")
      guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
      var didMoveActionFile = false
      do {
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        didMoveActionFile = true
        try synchronizeDirectory()
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        if didMoveActionFile {
          try? FileManager.default.removeItem(at: fileURL)
        }
        throw error
      }
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
        try? FileManager.default.removeItem(at: fileURL)
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

  private func synchronizeDirectory() throws {
    let fd = Darwin.open(directoryURL.path, O_RDONLY)
    guard fd >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(fd) }
    guard Darwin.fsync(fd) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

func diagnoseActionStoreWriteAccess(at directoryURL: URL) -> Bool {
  let probeURL = directoryURL.appendingPathComponent(".doctor-\(UUID().uuidString).tmp", isDirectory: false)
  do {
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try Data("write-check".utf8).write(to: probeURL, options: .withoutOverwriting)
    try FileManager.default.removeItem(at: probeURL)
    return true
  } catch {
    try? FileManager.default.removeItem(at: probeURL)
    return false
  }
}

func makeActionCleanupTimer(
  actionStore: ActionStore,
  interval: TimeInterval,
  onError: @escaping @Sendable (Error) -> Void
) -> DispatchSourceTimer {
  let queue = DispatchQueue(label: "com.yuki-yano.vde-notifier-app.agent-maintenance")
  let timer = DispatchSource.makeTimerSource(queue: queue)
  let boundedInterval = max(interval, 0.001)
  timer.schedule(deadline: .now() + boundedInterval, repeating: boundedInterval)
  timer.setEventHandler {
    do {
      try actionStore.pruneExpired()
    } catch {
      onError(error)
    }
  }
  timer.resume()
  return timer
}

final class AgentLogger: @unchecked Sendable {
  private let logURL: URL
  private let queue = DispatchQueue(label: "com.yuki-yano.vde-notifier-app.agent-log")

  init(logURL: URL) {
    self.logURL = logURL
  }

  func append(event: String, requestId: String? = nil, error: Error) {
    var entry: [String: String] = [
      "timestamp": ISO8601DateFormatter().string(from: Date()),
      "event": event,
      "error": String(describing: error),
    ]
    if let requestId {
      entry["request_id"] = requestId
    }
    guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
      return
    }
    queue.sync {
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
        // Diagnostics must not terminate the notification agent.
      }
    }
  }
}

func runStoredAction(actionStore: ActionStore, requestId: String, logger: AgentLogger) {
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
    logger.append(event: "action_failed", requestId: requestId, error: error)
  }
}

final class NotificationAgentRuntime: NSObject, UNUserNotificationCenterDelegate {
  private lazy var center = UNUserNotificationCenter.current()
  private let socketPath: String
  private let actionStore: ActionStore
  private let logger: AgentLogger
  private let actionCleanupInterval: TimeInterval
  private let notificationOperationTimeout: TimeInterval
  private var cleanupTimer: DispatchSourceTimer?
  private var serverFD: Int32 = -1
  private var lockFD: Int32 = -1
  private let serverQueue = DispatchQueue(label: "com.yuki-yano.vde-notifier-app.agent-server")
  private let clientQueue = DispatchQueue(
    label: "com.yuki-yano.vde-notifier-app.agent-clients",
    attributes: .concurrent
  )

  private static let categoryIdentifier = "com.yuki-yano.vde-notifier-app.focus"
  private static let actionIdentifier = "focus-return"

  init(
    socketPath: String,
    actionStoreURL: URL,
    logURL: URL,
    actionCleanupInterval: TimeInterval = 60 * 60,
    notificationOperationTimeout: TimeInterval = 2.0
  ) {
    self.socketPath = socketPath
    actionStore = ActionStore(directoryURL: actionStoreURL)
    logger = AgentLogger(logURL: logURL)
    self.actionCleanupInterval = actionCleanupInterval
    self.notificationOperationTimeout = notificationOperationTimeout
    super.init()
  }

  func start() throws {
    lockFD = try acquireAgentLock(path: "\(socketPath).lock")
    do {
      center.delegate = self
      registerNotificationCategory()
      try actionStore.pruneExpired()
      if FileManager.default.fileExists(atPath: socketPath) {
        if AgentBootstrap.isRunning(socketPath: socketPath) {
          throw UnixSocketError.lockUnavailable("\(socketPath).lock")
        }
        try removeOwnedStaleSocket(path: socketPath)
      }
      serverFD = try makeListeningUnixSocket(path: socketPath)
      cleanupTimer = makeActionCleanupTimer(actionStore: actionStore, interval: actionCleanupInterval) {
        [logger] error in
        logger.append(event: "action_cleanup_failed", error: error)
      }
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
    cleanupTimer?.cancel()
    cleanupTimer = nil
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
    do {
      guard try isAuthorizedForNotifications() else {
        return AgentResponse.failure(code: "permission_denied", message: "Notification permission is denied")
      }
    } catch {
      return AgentResponse.failure(code: "notification_timeout", message: String(describing: error))
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
    guard waitForSignal(sem, timeout: notificationOperationTimeout) else {
      try? actionStore.remove(requestId: requestId)
      return AgentResponse.failure(
        code: "enqueue_timeout",
        message: String(describing: NotificationAgentError.operationTimedOut("enqueue notification"))
      )
    }

    if let enqueueError = enqueueError.get() {
      try? actionStore.remove(requestId: requestId)
      return AgentResponse.failure(code: "enqueue_failed", message: enqueueError.localizedDescription)
    }

    return AgentResponse.success(requestId: requestId)
  }

  private func isAuthorizedForNotifications() throws -> Bool {
    let status = try notificationAuthorizationStatus()
    if status == .authorized {
      return true
    }
    if status != .notDetermined {
      return false
    }

    let sem = DispatchSemaphore(value: 0)
    let granted = LockedValue(false)
    DispatchQueue.main.async {
      let center = UNUserNotificationCenter.current()
      center.requestAuthorization(options: [.alert, .sound]) { isGranted, _ in
        granted.set(isGranted)
        sem.signal()
      }
    }
    guard waitForSignal(sem, timeout: notificationOperationTimeout) else {
      throw NotificationAgentError.operationTimedOut("request authorization")
    }
    return granted.get()
  }

  func notificationAuthorizationStatus() throws -> UNAuthorizationStatus {
    let sem = DispatchSemaphore(value: 0)
    let status = LockedValue<UNAuthorizationStatus>(.notDetermined)
    center.getNotificationSettings { settings in
      status.set(settings.authorizationStatus)
      sem.signal()
    }
    guard waitForSignal(sem, timeout: notificationOperationTimeout) else {
      throw NotificationAgentError.operationTimedOut("load notification settings")
    }
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
    runStoredAction(actionStore: actionStore, requestId: requestId, logger: logger)
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
