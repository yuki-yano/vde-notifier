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

  private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("vde-notifier-app-action-store-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
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
