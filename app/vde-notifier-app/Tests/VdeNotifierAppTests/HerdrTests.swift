import Darwin
import Foundation
@testable import VdeNotifierApp
@testable import VdeNotifierAppCore
import XCTest

final class HerdrClientTests: XCTestCase {
  func testLoadsContextAndFocusesExactPaneThroughSocketAPI() throws {
    let socketPath = makeHerdrSocketPath()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
    }
    let completed = DispatchSemaphore(value: 0)
    let serverError = LockedValue<Error?>(nil)
    let requests = LockedValue<[[String: Any]]>([])

    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      for _ in 0..<2 {
        let clientFD = Darwin.accept(serverFD, nil, nil)
        guard clientFD >= 0 else {
          serverError.set(UnixSocketError.syscallFailed(name: "accept", errno: errno))
          return
        }
        defer { Darwin.close(clientFD) }
        do {
          let requestData = try readSocketLine(from: clientFD)
          let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
          requests.withValue { $0.append(request) }
          let requestId = try XCTUnwrap(request["id"] as? String)
          let response = """
          {"id":"\(requestId)","result":{"type":"pane_info","pane":{"pane_id":"w2:p3","terminal_id":"term-3","workspace_id":"w2","tab_id":"w2:t1","focused":true,"cwd":"/tmp/project","foreground_cwd":"/tmp/project/src","label":"tests","agent":"codex","display_agent":"Codex agent","title":"Run tests","agent_status":"working","state_labels":{},"tokens":{},"revision":7}}}
          """
          try writeSocketLine(Data(response.utf8), to: clientFD)
        } catch {
          serverError.set(error)
          return
        }
      }
    }

    let context = try XCTUnwrap(loadHerdrContext(environment: [
      "HERDR_PANE_ID": "w2:p3",
      "HERDR_SOCKET_PATH": socketPath,
    ]))
    XCTAssertEqual(
      context,
      HerdrContext(
        socketPath: socketPath,
        paneId: "w2:p3",
        workspaceId: "w2",
        tabId: "w2:t1",
        label: "tests",
        agent: "Codex agent",
        title: "Run tests",
        currentDirectory: "/tmp/project/src"
      )
    )

    try HerdrAPIClient(socketPath: socketPath).focus(paneId: context.paneId)

    XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
    XCTAssertNil(serverError.get())
    XCTAssertEqual(requests.get().compactMap { $0["method"] as? String }, ["pane.get", "pane.focus"])
    let focusParams = try XCTUnwrap(requests.get().last?["params"] as? [String: String])
    XCTAssertEqual(focusParams["pane_id"], "w2:p3")
  }

  func testHerdrDryRunDoesNotRequireTmux() throws {
    let socketPath = makeHerdrSocketPath()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
    }
    let completed = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      let clientFD = Darwin.accept(serverFD, nil, nil)
      guard clientFD >= 0 else { return }
      defer { Darwin.close(clientFD) }
      do {
        let requestData = try readSocketLine(from: clientFD)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let requestId = try XCTUnwrap(request["id"] as? String)
        let response = """
        {"id":"\(requestId)","result":{"type":"pane_info","pane":{"pane_id":"w1:p1","terminal_id":"term-1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"cwd":"/tmp/project","agent_status":"idle","state_labels":{},"tokens":{},"revision":1}}}
        """
        try writeSocketLine(Data(response.utf8), to: clientFD)
      } catch {}
    }

    XCTAssertEqual(try NotifierCLI.run(
      arguments: ["--dry-run", "--title", "Done"],
      environment: [
        "HERDR_PANE_ID": "w1:p1",
        "HERDR_SOCKET_PATH": socketPath,
        "TERM_PROGRAM": "ghostty",
      ]
    ), 0)
    XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
  }

  func testNestedTmuxAndHerdrTargetsAreBothFocused() throws {
    let socketPath = makeHerdrSocketPath()
    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      try? FileManager.default.removeItem(at: directory)
    }
    let completed = DispatchSemaphore(value: 0)
    let methods = LockedValue<[String]>([])
    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      for _ in 0..<2 {
        let clientFD = Darwin.accept(serverFD, nil, nil)
        guard clientFD >= 0 else { return }
        do {
          defer { Darwin.close(clientFD) }
          let requestData = try readSocketLine(from: clientFD)
          let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
          let requestId = try XCTUnwrap(request["id"] as? String)
          if let method = request["method"] as? String {
            methods.withValue { $0.append(method) }
          }
          let response = """
          {"id":"\(requestId)","result":{"type":"pane_info","pane":{"pane_id":"w1:p1","terminal_id":"term-1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"cwd":"/tmp/project","agent_status":"idle","state_labels":{},"tokens":{},"revision":1}}}
          """
          try writeSocketLine(Data(response.utf8), to: clientFD)
        } catch {
          return
        }
      }
    }

    let tmuxLog = directory.appendingPathComponent("tmux.log")
    let tmuxExecutable = directory.appendingPathComponent("tmux")
    try Data("""
    #!/bin/sh
    printf '%s\\n' "$*" >> '\(tmuxLog.path)'
    case "$*" in
      *list-windows*) printf '@2\\n' ;;
      *list-panes*) printf '%%4\\n' ;;
      *list-clients*) printf '/dev/ttys001\\n' ;;
    esac
    """.utf8).write(to: tmuxExecutable)
    XCTAssertEqual(chmod(tmuxExecutable.path, 0o700), 0)
    let tmux = TmuxContext(
      tmuxBin: tmuxExecutable.path,
      socketPath: "/tmp/tmux.sock",
      clientTTY: "/dev/ttys001",
      sessionId: "$1",
      sessionName: "main",
      windowId: "@2",
      windowIndex: 1,
      paneId: "%4",
      paneIndex: 2,
      paneCurrentCommand: "herdr"
    )
    let herdr = HerdrContext(
      socketPath: socketPath,
      paneId: "w1:p1",
      workspaceId: "w1",
      tabId: "w1:t1"
    )

    try NotifierCLI.focusMultiplexers(tmux: tmux, herdr: herdr)

    XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(methods.get(), ["pane.get", "pane.focus"])
    let tmuxCalls = try String(contentsOf: tmuxLog, encoding: .utf8)
    XCTAssertTrue(tmuxCalls.contains("switch-client"))
    XCTAssertTrue(tmuxCalls.contains("select-pane -t %4"))
  }

  func testHerdrValidationFailureDoesNotTouchTmux() throws {
    let socketPath = makeHerdrSocketPath()
    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      try? FileManager.default.removeItem(at: directory)
    }
    let completed = DispatchSemaphore(value: 0)
    let serverError = LockedValue<Error?>(nil)
    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      let clientFD = Darwin.accept(serverFD, nil, nil)
      guard clientFD >= 0 else { return }
      defer { Darwin.close(clientFD) }
      do {
        let requestData = try readSocketLine(from: clientFD)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let requestId = try XCTUnwrap(request["id"] as? String)
        let response = """
        {"id":"\(requestId)","error":{"code":"pane_not_found","message":"pane not found"}}
        """
        try writeSocketLine(Data(response.utf8), to: clientFD)
      } catch {
        serverError.set(error)
      }
    }

    let tmuxLog = directory.appendingPathComponent("tmux.log")
    let tmuxExecutable = try makeFakeTmuxExecutable(directory: directory, log: tmuxLog, failValidation: false)
    let tmux = makeTmuxContext(executable: tmuxExecutable)
    let herdr = HerdrContext(
      socketPath: socketPath,
      paneId: "w1:missing",
      workspaceId: "w1",
      tabId: "w1:t1"
    )

    XCTAssertThrowsError(try NotifierCLI.focusMultiplexers(tmux: tmux, herdr: herdr))
    XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
    XCTAssertNil(serverError.get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: tmuxLog.path))
  }

  func testTmuxValidationFailureDoesNotFocusHerdrPane() throws {
    let socketPath = makeHerdrSocketPath()
    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      try? FileManager.default.removeItem(at: directory)
    }
    let completed = DispatchSemaphore(value: 0)
    let methods = LockedValue<[String]>([])
    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      let clientFD = Darwin.accept(serverFD, nil, nil)
      guard clientFD >= 0 else { return }
      defer { Darwin.close(clientFD) }
      do {
        let requestData = try readSocketLine(from: clientFD)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let requestId = try XCTUnwrap(request["id"] as? String)
        if let method = request["method"] as? String {
          methods.withValue { $0.append(method) }
        }
        let response = """
        {"id":"\(requestId)","result":{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1"}}}
        """
        try writeSocketLine(Data(response.utf8), to: clientFD)
      } catch {}
    }

    let tmuxLog = directory.appendingPathComponent("tmux.log")
    let tmuxExecutable = try makeFakeTmuxExecutable(directory: directory, log: tmuxLog, failValidation: true)
    let tmux = makeTmuxContext(executable: tmuxExecutable)
    let herdr = HerdrContext(
      socketPath: socketPath,
      paneId: "w1:p1",
      workspaceId: "w1",
      tabId: "w1:t1"
    )

    XCTAssertThrowsError(try NotifierCLI.focusMultiplexers(tmux: tmux, herdr: herdr))
    XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(methods.get(), ["pane.get"])
    let tmuxCalls = try String(contentsOf: tmuxLog, encoding: .utf8)
    XCTAssertTrue(tmuxCalls.contains("has-session"))
    XCTAssertFalse(tmuxCalls.contains("switch-client"))
  }

  func testPaneIdentityRequiresAbsoluteSocketPath() {
    XCTAssertThrowsError(try loadHerdrContext(environment: [
      "HERDR_PANE_ID": "w1:p1",
      "HERDR_SOCKET_PATH": "relative.sock",
    ])) { error in
      guard case HerdrAPIError.invalidEnvironment = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertNil(try loadHerdrContext(environment: ["HERDR_SOCKET_PATH": "/tmp/herdr.sock"]))
  }

  func testRejectsMismatchedPaneIdentity() throws {
    let socketPath = makeHerdrSocketPath()
    let serverFD = try makeListeningUnixSocket(path: socketPath)
    defer {
      Darwin.close(serverFD)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
    }
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      let clientFD = Darwin.accept(serverFD, nil, nil)
      guard clientFD >= 0 else { return }
      defer { Darwin.close(clientFD) }
      do {
        let requestData = try readSocketLine(from: clientFD)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let requestId = try XCTUnwrap(request["id"] as? String)
        let response = """
        {"id":"\(requestId)","result":{"type":"pane_info","pane":{"pane_id":"w1:other","workspace_id":"w1","tab_id":"w1:t1"}}}
        """
        try writeSocketLine(Data(response.utf8), to: clientFD)
      } catch {}
    }

    XCTAssertThrowsError(try HerdrAPIClient(socketPath: socketPath).paneContext(paneId: "w1:requested")) { error in
      guard case HerdrAPIError.invalidResponse = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
  }

  private func makeHerdrSocketPath() -> String {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("vna-herdr-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("herdr.sock", isDirectory: false).path
  }

  private func makeFakeTmuxExecutable(
    directory: URL,
    log: URL,
    failValidation: Bool
  ) throws -> URL {
    let executable = directory.appendingPathComponent("tmux")
    let validationCase = failValidation ? "*has-session*) exit 1 ;;" : ""
    try Data("""
    #!/bin/sh
    printf '%s\\n' "$*" >> '\(log.path)'
    case "$*" in
      \(validationCase)
      *list-windows*) printf '@2\\n' ;;
      *list-panes*) printf '%%4\\n' ;;
      *list-clients*) printf '/dev/ttys001\\n' ;;
    esac
    """.utf8).write(to: executable)
    XCTAssertEqual(chmod(executable.path, 0o700), 0)
    return executable
  }

  private func makeTmuxContext(executable: URL) -> TmuxContext {
    TmuxContext(
      tmuxBin: executable.path,
      socketPath: "/tmp/tmux.sock",
      clientTTY: "/dev/ttys001",
      sessionId: "$1",
      sessionName: "main",
      windowId: "@2",
      windowIndex: 1,
      paneId: "%4",
      paneIndex: 2,
      paneCurrentCommand: "herdr"
    )
  }
}
