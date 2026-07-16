import XCTest
@testable import VdeNotifierAppCore

final class CommandParserTests: XCTestCase {
  func testParseNotifyCommand() throws {
    let command = try parseCommandLine([
      "notify",
      "--title",
      "Build finished",
      "--message",
      "webpack done",
      "--sound",
      "Ping",
      "--action-exec",
      "/usr/bin/say",
      "--action-arg",
      "/opt/homebrew/bin/vde-notifier",
      "--action-arg",
      "--mode",
      "--action-arg",
      "focus",
    ])

    guard case let .notify(notify) = command else {
      XCTFail("Expected notify command")
      return
    }

    XCTAssertEqual(notify.title, "Build finished")
    XCTAssertEqual(notify.message, "webpack done")
    XCTAssertEqual(notify.sound, "Ping")
    XCTAssertEqual(notify.actionExecutable, "/usr/bin/say")
    XCTAssertEqual(notify.actionArguments, ["/opt/homebrew/bin/vde-notifier", "--mode", "focus"])
  }

  func testParseNotifyMissingRequired() throws {
    do {
      _ = try parseCommandLine([
        "notify",
        "--title",
        "Build finished",
        "--message",
        "webpack done",
      ])
      XCTFail("Expected parse failure")
    } catch let error as CommandParseError {
      XCTAssertEqual(error, .missingRequired(flag: "--action-exec"))
    }
  }

  func testParseNotifyAcceptsValuesStartingWithDoubleHyphen() throws {
    let command = try parseCommandLine([
      "notify",
      "--title",
      "--deployment-finished",
      "--message",
      "--all-tasks-complete",
      "--action-exec",
      "/usr/bin/true",
    ])

    guard case let .notify(notify) = command else {
      XCTFail("Expected notify command")
      return
    }

    XCTAssertEqual(notify.title, "--deployment-finished")
    XCTAssertEqual(notify.message, "--all-tasks-complete")
  }

  func testParseNotifyRejectsKnownOptionAsMissingValue() throws {
    XCTAssertThrowsError(try parseCommandLine(["notify", "--title", "--message", "done"])) { error in
      XCTAssertEqual(error as? CommandParseError, .missingValue(flag: "--title"))
    }
  }

  func testParseDefaultHelp() throws {
    let command = try parseCommandLine([])
    XCTAssertEqual(command, .help)
  }

  func testParseAgentStart() throws {
    let command = try parseCommandLine(["agent", "start"])
    XCTAssertEqual(command, .agentStart)
  }

  func testParseUnknownOption() throws {
    do {
      _ = try parseCommandLine(["notify", "--foo", "bar"])
      XCTFail("Expected parse failure")
    } catch let error as CommandParseError {
      XCTAssertEqual(error, .unknownFlag("--foo"))
    }
  }

  func testParseVersion() throws {
    XCTAssertEqual(try parseCommandLine(["--version"]), .version)
    XCTAssertEqual(try parseCommandLine(["-v"]), .version)
  }
}
