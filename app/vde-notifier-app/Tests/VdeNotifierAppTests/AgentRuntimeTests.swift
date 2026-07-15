import Darwin
import Foundation
@testable import VdeNotifierApp
@testable import VdeNotifierAppCore
import XCTest

final class ActionStoreTests: XCTestCase {
  func testSaveAndTakeAction() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ActionStore(directoryURL: directory)
    let requestId = UUID().uuidString.lowercased()
    let action = ActionPayload(executable: "/usr/bin/say", arguments: ["done"])

    try store.save(requestId: requestId, action: action)

    XCTAssertEqual(try store.take(requestId: requestId), action)
    XCTAssertNil(try store.take(requestId: requestId))
  }

  func testSaveRejectsDuplicateRequestId() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ActionStore(directoryURL: directory)
    let requestId = UUID().uuidString.lowercased()
    let action = ActionPayload(executable: "/usr/bin/say", arguments: ["done"])
    try store.save(requestId: requestId, action: action)

    XCTAssertThrowsError(try store.save(requestId: requestId, action: action)) { error in
      guard case ActionStoreError.duplicateRequestId = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testCorruptActionDoesNotAffectAnotherRequest() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ActionStore(directoryURL: directory)
    let validId = UUID().uuidString.lowercased()
    let corruptId = UUID().uuidString.lowercased()
    let action = ActionPayload(executable: "/usr/bin/say", arguments: ["valid"])
    try store.save(requestId: validId, action: action)
    try Data("not-json".utf8).write(to: actionURL(directory: directory, requestId: corruptId))

    XCTAssertThrowsError(try store.take(requestId: corruptId))
    XCTAssertEqual(try store.take(requestId: validId), action)
  }

  func testConcurrentSavesKeepEveryAction() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ActionStore(directoryURL: directory)
    let requestIds = (0 ..< 20).map { _ in UUID().uuidString.lowercased() }
    let failures = LockedValue<[String]>([])

    DispatchQueue.concurrentPerform(iterations: requestIds.count) { index in
      do {
        try store.save(
          requestId: requestIds[index],
          action: ActionPayload(executable: "/usr/bin/say", arguments: [String(index)])
        )
      } catch {
        failures.withValue { $0.append(String(describing: error)) }
      }
    }

    XCTAssertEqual(failures.get(), [])
    for (index, requestId) in requestIds.enumerated() {
      XCTAssertEqual(
        try store.take(requestId: requestId),
        ActionPayload(executable: "/usr/bin/say", arguments: [String(index)])
      )
    }
  }

  func testPruneExpiredRemovesOnlyOldActionFiles() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ActionStore(directoryURL: directory)
    let expiredId = UUID().uuidString.lowercased()
    let recentId = UUID().uuidString.lowercased()
    let action = ActionPayload(executable: "/usr/bin/say", arguments: ["done"])
    try store.save(requestId: expiredId, action: action)
    try store.save(requestId: recentId, action: action)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-(60 * 60 * 24 * 8))],
      ofItemAtPath: actionURL(directory: directory, requestId: expiredId).path
    )

    try store.pruneExpired()

    XCTAssertNil(try store.take(requestId: expiredId))
    XCTAssertEqual(try store.take(requestId: recentId), action)
  }

  func testDoctorWriteAccessChecksTheDirectory() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    XCTAssertTrue(diagnoseActionStoreWriteAccess(at: directory))

    let invalidDirectory = directory.appendingPathComponent("not-a-directory")
    try Data("file".utf8).write(to: invalidDirectory)
    XCTAssertFalse(diagnoseActionStoreWriteAccess(at: invalidDirectory))
  }

  func testActionLaunchFailureIsWrittenToTheAgentLog() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ActionStore(directoryURL: directory.appendingPathComponent("actions", isDirectory: true))
    let logURL = directory.appendingPathComponent("agent.log", isDirectory: false)
    let requestId = UUID().uuidString.lowercased()
    try store.save(
      requestId: requestId,
      action: ActionPayload(executable: "/path/that/does/not/exist", arguments: [])
    )

    runStoredAction(actionStore: store, requestId: requestId, logger: AgentLogger(logURL: logURL))

    let data = try Data(contentsOf: logURL)
    let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    XCTAssertEqual(entry["event"], "action_failed")
    XCTAssertEqual(entry["request_id"], requestId)
    XCTAssertFalse(try XCTUnwrap(entry["error"]).isEmpty)
  }

  private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("vde-notifier-app-action-store-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func actionURL(directory: URL, requestId: String) -> URL {
    directory.appendingPathComponent("\(requestId).json", isDirectory: false)
  }
}

final class UnixSocketTests: XCTestCase {
  func testSemaphoreDeadlineReportsSuccessAndTimeout() {
    let signaled = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
      signaled.signal()
    }
    XCTAssertTrue(waitForSignal(signaled, timeout: 0.5))

    let stalled = DispatchSemaphore(value: 0)
    let startedAt = Date()
    XCTAssertFalse(waitForSignal(stalled, timeout: 0.02))
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
  }

  func testListeningSocketIsReachable() throws {
    let socketPath = makeSocketPath()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      unlink(socketPath)
    }

    let serverCompleted = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      let clientFD = Darwin.accept(serverFD, nil, nil)
      defer {
        if clientFD >= 0 {
          Darwin.close(clientFD)
        }
        serverCompleted.signal()
      }
      guard clientFD >= 0 else {
        return
      }
      do {
        let request = try decodeAgentRequest(readFrame(from: clientFD))
        guard case .ping = request else {
          return
        }
        try writeFrame(try encodeAgentResponse(.pong()), to: clientFD)
      } catch {}
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    XCTAssertTrue(AgentBootstrap.isRunning(socketPath: socketPath))
    XCTAssertEqual(serverCompleted.wait(timeout: .now() + 2), .success)
  }

  func testAgentClientRoundTrip() throws {
    let socketPath = makeSocketPath()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      unlink(socketPath)
    }

    let semaphore = DispatchSemaphore(value: 0)
    let serverError = LockedValue<Error?>(nil)
    let receivedRequestId = LockedValue<String?>(nil)

    DispatchQueue.global(qos: .userInitiated).async {
      let clientFD = Darwin.accept(serverFD, nil, nil)
      guard clientFD >= 0 else {
        serverError.set(UnixSocketError.syscallFailed(name: "accept", errno: errno))
        semaphore.signal()
        return
      }
      defer { Darwin.close(clientFD) }

      do {
        let requestData = try readFrame(from: clientFD)
        let request = try decodeNotifyRequest(requestData)
        receivedRequestId.set(request.requestId)
        let response = AgentResponse.success(requestId: request.requestId)
        let responseData = try encodeAgentResponse(response)
        try writeFrame(responseData, to: clientFD)
      } catch {
        serverError.set(error)
      }
      semaphore.signal()
    }

    let request = NotifyRequest(
      requestId: UUID().uuidString.lowercased(),
      title: "Title",
      message: "Message",
      sound: "Ping",
      action: ActionPayload(executable: "/usr/bin/say", arguments: ["clicked"])
    )

    let response = try AgentClient(socketPath: socketPath).send(request)

    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.requestId, request.requestId)
    XCTAssertEqual(semaphore.wait(timeout: .now() + 2), .success)
    XCTAssertNil(serverError.get())
    XCTAssertEqual(receivedRequestId.get(), request.requestId)
  }

  func testReadFrameRejectsOversizedPayload() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    defer {
      Darwin.close(descriptors[0])
      Darwin.close(descriptors[1])
    }

    let length = UInt32(maximumFramePayloadBytes + 1)
    let header = Data([
      UInt8((length >> 24) & 0xFF),
      UInt8((length >> 16) & 0xFF),
      UInt8((length >> 8) & 0xFF),
      UInt8(length & 0xFF),
    ])
    try writeAll(header, to: descriptors[0])

    XCTAssertThrowsError(try readFrame(from: descriptors[1])) { error in
      guard case UnixSocketError.payloadTooLarge = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testWriteAllFailsWhenWriteReturnsZero() throws {
    XCTAssertThrowsError(
      try writeAll(Data([0x01]), to: -1) { _, _, _ in 0 }
    ) { error in
      guard case UnixSocketError.connectionClosed = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testStalledClientDoesNotBlockPing() throws {
    let socketPath = makeSocketPath()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      unlink(socketPath)
    }
    let clientQueue = DispatchQueue(label: "test.socket.clients", attributes: .concurrent)
    DispatchQueue.global(qos: .userInitiated).async {
      acceptClients(on: serverFD, clientQueue: clientQueue) { clientFD in
        defer { Darwin.close(clientFD) }
        do {
          try setSocketTimeout(on: clientFD, seconds: 0.5)
          let request = try decodeAgentRequest(readFrame(from: clientFD))
          guard case .ping = request else {
            return
          }
          try writeFrame(try encodeAgentResponse(.pong()), to: clientFD)
        } catch {}
      }
    }

    let stalledFD = try connectUnixSocket(path: socketPath)
    defer { Darwin.close(stalledFD) }
    try writeAll(Data([0x00, 0x00]), to: stalledFD)

    XCTAssertTrue(AgentClient(socketPath: socketPath, timeout: 0.5).ping())
  }

  func testPingTimesOutWhenServerDoesNotRespond() throws {
    let socketPath = makeSocketPath()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      unlink(socketPath)
    }

    let accepted = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      let clientFD = Darwin.accept(serverFD, nil, nil)
      accepted.signal()
      if clientFD >= 0 {
        Thread.sleep(forTimeInterval: 0.2)
        Darwin.close(clientFD)
      }
    }

    XCTAssertFalse(AgentClient(socketPath: socketPath, timeout: 0.05).ping())
    XCTAssertEqual(accepted.wait(timeout: .now() + 1), .success)
  }

  func testAgentLockRejectsSecondOwner() throws {
    let socketPath = makeSocketPath()
    let lockPath = "\(socketPath).lock"
    let child = try startLockHolder(lockPath: lockPath)
    defer {
      if child.isRunning {
        child.terminate()
      }
      child.waitUntilExit()
      unlink(lockPath)
    }

    XCTAssertThrowsError(try acquireAgentLock(path: lockPath)) { error in
      guard case UnixSocketError.lockUnavailable = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testSecondRuntimeDoesNotPruneActionsBeforeAcquiringLock() throws {
    let socketPath = makeSocketPath()
    let baseDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    let actionsDirectory = baseDirectory.appendingPathComponent("actions", isDirectory: true)
    let logURL = baseDirectory.appendingPathComponent("agent.log", isDirectory: false)
    let store = ActionStore(directoryURL: actionsDirectory)
    let requestId = UUID().uuidString.lowercased()
    let action = ActionPayload(executable: "/usr/bin/say", arguments: ["keep"])
    try store.save(requestId: requestId, action: action)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-(60 * 60 * 24 * 8))],
      ofItemAtPath: actionURL(directory: actionsDirectory, requestId: requestId).path
    )

    let lockPath = "\(socketPath).lock"
    let child = try startLockHolder(lockPath: lockPath)
    defer {
      if child.isRunning {
        child.terminate()
      }
      child.waitUntilExit()
      try? FileManager.default.removeItem(at: baseDirectory)
    }

    let runtime = NotificationAgentRuntime(socketPath: socketPath, actionStoreURL: actionsDirectory, logURL: logURL)
    XCTAssertThrowsError(try runtime.start()) { error in
      guard case UnixSocketError.lockUnavailable = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try store.take(requestId: requestId), action)
  }

  func testRuntimePrunesExpiredActionsOnMaintenanceTimer() throws {
    let socketPath = makeSocketPath()
    let baseDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    let actionsDirectory = baseDirectory.appendingPathComponent("actions", isDirectory: true)
    let store = ActionStore(directoryURL: actionsDirectory)
    let timer = makeActionCleanupTimer(actionStore: store, interval: 0.05) { _ in }
    defer {
      timer.cancel()
      try? FileManager.default.removeItem(at: baseDirectory)
    }

    let requestId = UUID().uuidString.lowercased()
    try store.save(requestId: requestId, action: ActionPayload(executable: "/usr/bin/say", arguments: ["expire"]))
    let fileURL = actionURL(directory: actionsDirectory, requestId: requestId)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-(60 * 60 * 24 * 8))],
      ofItemAtPath: fileURL.path
    )

    let deadline = Date().addingTimeInterval(2)
    while FileManager.default.fileExists(atPath: fileURL.path), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testStaleSocketRemovalRejectsRegularFile() throws {
    let socketPath = makeSocketPath()
    try Data("keep".utf8).write(to: URL(fileURLWithPath: socketPath))
    defer { unlink(socketPath) }

    XCTAssertThrowsError(try removeOwnedStaleSocket(path: socketPath)) { error in
      guard case UnixSocketError.unsafeStaleSocket = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try String(contentsOfFile: socketPath, encoding: .utf8), "keep")
  }

  private func makeSocketPath() -> String {
    let suffix = String(UUID().uuidString.prefix(8))
    let baseDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("vna-\(suffix)", isDirectory: true)
    try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    return baseDirectory.appendingPathComponent("agent.sock", isDirectory: false).path
  }

  private func actionURL(directory: URL, requestId: String) -> URL {
    directory.appendingPathComponent("\(requestId).json", isDirectory: false)
  }

  private func startLockHolder(lockPath: String) throws -> Process {
    let readyPipe = Pipe()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    child.arguments = [
      "-c",
      """
      import fcntl, os, sys, time
      fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
      fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      sys.stdout.buffer.write(b"1")
      sys.stdout.buffer.flush()
      time.sleep(5)
      """,
      lockPath,
    ]
    child.standardOutput = readyPipe
    child.standardError = FileHandle.nullDevice
    try child.run()
    guard readyPipe.fileHandleForReading.readData(ofLength: 1) == Data("1".utf8) else {
      child.terminate()
      child.waitUntilExit()
      throw CocoaError(.fileReadUnknown)
    }
    return child
  }
}
