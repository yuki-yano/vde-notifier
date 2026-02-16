import Foundation
import UserNotifications
import VdeNotifierAppCore

private struct StoredAction: Codable {
  let executable: String
  let arguments: [String]
  let createdAt: String
}

final class ActionStore {
  private let fileURL: URL
  private let queue = DispatchQueue(label: "com.yuki-yano.vde-notifier-app.action-store")
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private static let actionRetentionInterval: TimeInterval = 60 * 60 * 24 * 7
  private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  init(fileURL: URL) {
    self.fileURL = fileURL
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  func save(requestId: String, action: ActionPayload) throws {
    try queue.sync {
      var table = try loadTable()
      _ = pruneExpiredEntries(&table)
      table[requestId] = StoredAction(
        executable: action.executable,
        arguments: action.arguments,
        createdAt: iso8601Now()
      )
      try persist(table)
    }
  }

  func take(requestId: String) throws -> ActionPayload? {
    try queue.sync {
      var table = try loadTable()
      let didPrune = pruneExpiredEntries(&table)
      guard let stored = table.removeValue(forKey: requestId) else {
        if didPrune {
          try persist(table)
        }
        return nil
      }
      try persist(table)
      return ActionPayload(executable: stored.executable, arguments: stored.arguments)
    }
  }

  func remove(requestId: String) throws {
    try queue.sync {
      var table = try loadTable()
      let didPrune = pruneExpiredEntries(&table)
      let removed = table.removeValue(forKey: requestId) != nil
      if didPrune || removed {
        try persist(table)
      }
    }
  }

  private func loadTable() throws -> [String: StoredAction] {
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      return [:]
    }
    let data = try Data(contentsOf: fileURL)
    if data.isEmpty {
      return [:]
    }
    return try decoder.decode([String: StoredAction].self, from: data)
  }

  private func persist(_ table: [String: StoredAction]) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(table)
    try data.write(to: fileURL, options: .atomic)
  }

  private func iso8601Now() -> String {
    Self.timestampFormatter.string(from: Date())
  }

  private func pruneExpiredEntries(_ table: inout [String: StoredAction]) -> Bool {
    let threshold = Date().addingTimeInterval(-Self.actionRetentionInterval)
    let originalCount = table.count

    table = table.filter { _, storedAction in
      guard let createdAt = Self.timestampFormatter.date(from: storedAction.createdAt) else {
        return false
      }
      return createdAt >= threshold
    }

    return table.count != originalCount
  }
}

final class NotificationAgentRuntime: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private let socketPath: String
  private let actionStore: ActionStore
  private var serverFD: Int32 = -1
  private let serverQueue = DispatchQueue(label: "com.yuki-yano.vde-notifier-app.agent-server")

  private static let categoryIdentifier = "com.yuki-yano.vde-notifier-app.focus"
  private static let actionIdentifier = "focus-return"

  init(socketPath: String, actionStoreURL: URL) {
    self.socketPath = socketPath
    actionStore = ActionStore(fileURL: actionStoreURL)
    super.init()
  }

  func start() throws {
    center.delegate = self
    registerNotificationCategory()
    serverFD = try makeListeningUnixSocket(path: socketPath)
    serverQueue.async { [weak self] in
      self?.acceptLoop()
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
    while true {
      let clientFD = Darwin.accept(serverFD, nil, nil)
      if clientFD < 0 {
        if errno == EINTR {
          continue
        }
        continue
      }
      handleClient(clientFD: clientFD)
    }
  }

  private func handleClient(clientFD: Int32) {
    defer { Darwin.close(clientFD) }
    setNoSIGPIPE(on: clientFD)

    do {
      let inputData = try readAll(from: clientFD)
      if inputData.isEmpty {
        return
      }
      let request = try decodeNotifyRequest(inputData)
      let response = try handleNotifyRequest(request)
      let responseData = try encodeAgentResponse(response)
      try writeAll(responseData, to: clientFD)
    } catch {
      let failure = AgentResponse.failure(code: "bad_request", message: String(describing: error))
      do {
        let responseData = try encodeAgentResponse(failure)
        try writeAll(responseData, to: clientFD)
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
    guard let action = try? actionStore.take(requestId: requestId) else {
      return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: action.executable)
    process.arguments = action.arguments
    try? process.run()
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
