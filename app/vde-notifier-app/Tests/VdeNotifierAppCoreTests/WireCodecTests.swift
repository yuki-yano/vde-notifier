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
        executable: "/usr/local/bin/node",
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
}
