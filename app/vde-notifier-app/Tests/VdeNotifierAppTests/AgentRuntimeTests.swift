import Darwin
import Foundation
@testable import VdeNotifierApp
@testable import VdeNotifierAppCore
import XCTest

final class ActionStoreTests: XCTestCase {
  func testSaveAndTakeAction() throws {
    let tempDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let storeURL = tempDirectory.appendingPathComponent("actions.json", isDirectory: false)
    let store = ActionStore(fileURL: storeURL)
    let action = ActionPayload(executable: "/usr/bin/say", arguments: ["done"])

    try store.save(requestId: "req-1", action: action)
    let loaded = try store.take(requestId: "req-1")
    let missing = try store.take(requestId: "req-1")

    XCTAssertEqual(loaded, action)
    XCTAssertNil(missing)
  }

  func testSavePrunesExpiredEntries() throws {
    let tempDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let storeURL = tempDirectory.appendingPathComponent("actions.json", isDirectory: false)
    try writeActionsFixture(to: storeURL)
    let store = ActionStore(fileURL: storeURL)

    try store.save(requestId: "new", action: ActionPayload(executable: "/usr/bin/say", arguments: ["new"]))

    let table = try readActionsJSON(from: storeURL)
    XCTAssertNil(table["expired"])
    XCTAssertNotNil(table["recent"])
    XCTAssertNotNil(table["new"])
  }

  func testTakePersistsPrunedTableWhenRequestIsMissing() throws {
    let tempDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let storeURL = tempDirectory.appendingPathComponent("actions.json", isDirectory: false)
    try writeActionsFixture(to: storeURL)
    let store = ActionStore(fileURL: storeURL)

    let missing = try store.take(requestId: "missing")
    XCTAssertNil(missing)

    let table = try readActionsJSON(from: storeURL)
    XCTAssertNil(table["expired"])
    XCTAssertNotNil(table["recent"])
  }

  private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("vde-notifier-app-action-store-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeActionsFixture(to path: URL) throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let expired = formatter.string(from: Date().addingTimeInterval(-(60 * 60 * 24 * 8)))
    let recent = formatter.string(from: Date())
    let payload: [String: [String: Any]] = [
      "expired": [
        "executable": "/usr/bin/say",
        "arguments": ["old"],
        "createdAt": expired
      ],
      "recent": [
        "executable": "/usr/bin/say",
        "arguments": ["new"],
        "createdAt": recent
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try data.write(to: path)
  }

  private func readActionsJSON(from path: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: path)
    let value = try JSONSerialization.jsonObject(with: data)
    guard let table = value as? [String: Any] else {
      XCTFail("actions.json must be a dictionary")
      return [:]
    }
    return table
  }
}

final class UnixSocketTests: XCTestCase {
  func testListeningSocketIsReachable() throws {
    let socketPath = makeSocketPath()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      unlink(socketPath)
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    XCTAssertTrue(socketExistsAndReachable(path: socketPath))
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
        let requestData = try readAll(from: clientFD)
        let request = try decodeNotifyRequest(requestData)
        receivedRequestId.set(request.requestId)
        let response = AgentResponse.success(requestId: request.requestId)
        let responseData = try encodeAgentResponse(response)
        try writeAll(responseData, to: clientFD)
      } catch {
        serverError.set(error)
      }
      semaphore.signal()
    }

    let request = NotifyRequest(
      requestId: "test-request",
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

  private func makeSocketPath() -> String {
    let suffix = String(UUID().uuidString.prefix(8))
    let baseDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("vna-\(suffix)", isDirectory: true)
    try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    return baseDirectory.appendingPathComponent("agent.sock", isDirectory: false).path
  }
}
