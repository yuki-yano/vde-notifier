import XCTest
@testable import VdeNotifierAppCore

final class WireCodecTests: XCTestCase {
  func testNotifyRequestRoundTrip() throws {
    let request = NotifyRequest(
      requestId: "6ad1a90f-2d12-4f7c-a0bc-8c81b93a96b2",
      title: "Build",
      message: "Done",
      sound: "Ping",
      action: ActionPayload(
        executable: "/usr/bin/say",
        arguments: ["/opt/homebrew/bin/vde-notifier", "--mode", "focus"]
      ),
      source: "vde-notifier"
    )

    let data = try encodeNotifyRequest(request)
    let decoded = try decodeNotifyRequest(data)

    XCTAssertEqual(decoded, request)
  }

  func testAgentResponseRoundTrip() throws {
    let response = AgentResponse.success(requestId: "req-2")
    let data = try encodeAgentResponse(response)
    let decoded = try decodeAgentResponse(data)

    XCTAssertEqual(decoded.ok, true)
    XCTAssertEqual(decoded.requestId, "req-2")
    XCTAssertNotNil(decoded.queuedAt)
  }

  func testDecodeEmptyPayloadFails() throws {
    do {
      _ = try decodeNotifyRequest(Data("\n".utf8))
      XCTFail("Expected empty payload failure")
    } catch let error as WireCodecError {
      switch error {
      case .emptyPayload:
        XCTAssertTrue(true)
      default:
        XCTFail("Unexpected wire error: \(error)")
      }
    }
  }

  func testPingRequestRoundTrip() throws {
    let encoded = try encodePingRequest()
    XCTAssertEqual(try decodeAgentRequest(encoded), .ping(PingRequest()))
    XCTAssertEqual(AgentResponse.pong().code, "pong")
  }

  func testDecodeRejectsUnsupportedVersion() throws {
    let request = NotifyRequest(
      version: agentProtocolVersion + 1,
      requestId: "6ad1a90f-2d12-4f7c-a0bc-8c81b93a96b2",
      title: "Build",
      message: "Done",
      sound: nil,
      action: ActionPayload(executable: "/usr/bin/say", arguments: [])
    )

    XCTAssertThrowsError(try decodeAgentRequest(try encodeNotifyRequest(request))) { error in
      guard case WireCodecError.unsupportedVersion = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testDecodeRejectsInvalidRequestId() throws {
    let request = NotifyRequest(
      requestId: "not-a-uuid",
      title: "Build",
      message: "Done",
      sound: nil,
      action: ActionPayload(executable: "/usr/bin/say", arguments: [])
    )

    XCTAssertThrowsError(try decodeAgentRequest(try encodeNotifyRequest(request))) { error in
      guard case WireCodecError.invalidRequest = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testDecodeRejectsUnsupportedRequestType() throws {
    let request = NotifyRequest(
      type: "unknown",
      requestId: UUID().uuidString.lowercased(),
      title: "Build",
      message: "Done",
      sound: nil,
      action: ActionPayload(executable: "/usr/bin/say", arguments: [])
    )

    XCTAssertThrowsError(try decodeAgentRequest(try encodeNotifyRequest(request))) { error in
      guard case WireCodecError.invalidRequest = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testDecodeRejectsOversizedTitle() throws {
    let request = makeNotifyRequest(title: String(repeating: "t", count: 1025))

    XCTAssertThrowsError(try decodeAgentRequest(try encodeNotifyRequest(request))) { error in
      guard case WireCodecError.invalidRequest = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testDecodeRejectsOversizedMessage() throws {
    let request = makeNotifyRequest(message: String(repeating: "m", count: (64 * 1024) + 1))

    XCTAssertThrowsError(try decodeAgentRequest(try encodeNotifyRequest(request))) { error in
      guard case WireCodecError.invalidRequest = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testDecodeRejectsTooManyActionArguments() throws {
    let request = makeNotifyRequest(arguments: Array(repeating: "arg", count: 513))

    XCTAssertThrowsError(try decodeAgentRequest(try encodeNotifyRequest(request))) { error in
      guard case WireCodecError.invalidRequest = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testDecodeRejectsOversizedActionArguments() throws {
    let request = makeNotifyRequest(arguments: [String(repeating: "a", count: (512 * 1024) + 1)])

    XCTAssertThrowsError(try decodeAgentRequest(try encodeNotifyRequest(request))) { error in
      guard case WireCodecError.invalidRequest = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func makeNotifyRequest(
    title: String = "Build",
    message: String = "Done",
    arguments: [String] = []
  ) -> NotifyRequest {
    NotifyRequest(
      requestId: UUID().uuidString.lowercased(),
      title: title,
      message: message,
      sound: nil,
      action: ActionPayload(executable: "/usr/bin/say", arguments: arguments)
    )
  }
}
