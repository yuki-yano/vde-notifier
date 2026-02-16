import XCTest
@testable import VdeNotifierAppCore

final class WireCodecTests: XCTestCase {
  func testNotifyRequestRoundTrip() throws {
    let request = NotifyRequest(
      requestId: "req-1",
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
}
