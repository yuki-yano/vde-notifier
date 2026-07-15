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

  private func makeSocketPath() -> String {
    let suffix = String(UUID().uuidString.prefix(8))
    let baseDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("vna-\(suffix)", isDirectory: true)
    try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    return baseDirectory.appendingPathComponent("agent.sock", isDirectory: false).path
  }
}
