import Darwin
import Foundation
@testable import VdeNotifierApp
@testable import VdeNotifierAppCore
import XCTest

final class ProcessRunnerTests: XCTestCase {
  func testCapturesOutputAndExitStatus() throws {
    let result = try ProcessRunner.capture(
      executable: "/bin/sh",
      arguments: ["-c", "printf output; printf error >&2; exit 7"]
    )
    XCTAssertEqual(result, ProcessResult(status: 7, standardOutput: "output", standardError: "error"))
  }

  func testRequireSuccessReportsStandardError() {
    XCTAssertThrowsError(try ProcessRunner.requireSuccess(
      executable: "/bin/sh",
      arguments: ["-c", "printf failure >&2; exit 2"]
    )) { error in
      XCTAssertTrue(String(describing: error).contains("failure"))
      XCTAssertTrue(String(describing: error).contains("status 2"))
    }
  }

  func testResolvesOnlyExecutablePathEntries() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("tool")
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    XCTAssertThrowsError(try resolveExecutable("tool", environment: ["PATH": directory.path]))
    XCTAssertEqual(chmod(executable.path, 0o700), 0)
    XCTAssertEqual(try resolveExecutable("tool", environment: ["PATH": directory.path]), executable.path)
  }
}

final class AgentContextLoaderTests: XCTestCase {
  func testCodexPayloadPriorityAndSessionClassification() throws {
    let home = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let sessionDirectory = home.appendingPathComponent(".codex/sessions/2026/07/16", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let thread = "01234567-89ab-cdef"
    let rollout = sessionDirectory.appendingPathComponent("rollout-test-\(thread).jsonl")
    try Data(#"{"payload":{"source":"exec"}}"#.utf8).write(to: rollout)
    var options = NotifierCLIOptions()
    options.codex = true
    options.positionalArguments = [#"{"thread-id":"01234567-89ab-cdef","message":"argument"}"#]

    let context = try XCTUnwrap(loadCodexContext(
      options: options,
      environment: ["HOME": home.path, "CODEX_NOTIFICATION_PAYLOAD": #"{"message":"environment"}"#],
      standardInput: #"{"message":"stdin"}"#
    ))
    XCTAssertEqual(context.message, "argument")
    XCTAssertTrue(context.isNonInteractive)
  }

  func testCodexReadsForwardedJSONObjectBeforeEnvironment() throws {
    var options = NotifierCLIOptions()
    options.codex = true
    options.forwardCommand = ForwardCommand(executable: "/usr/bin/say", arguments: ["--flag", #"{"message":"forwarded"}"#])
    let context = try XCTUnwrap(loadCodexContext(
      options: options,
      environment: ["CODEX_NOTIFICATION_PAYLOAD": #"{"message":"environment"}"#],
      standardInput: ""
    ))
    XCTAssertEqual(context.message, "forwarded")
  }

  func testClaudeReadsLatestAssistantTranscriptWithinAllowedDirectory() throws {
    let home = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appendingPathComponent(".claude/projects/repo", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let transcript = project.appendingPathComponent("session.jsonl")
    try Data("""
    {"message":{"role":"assistant","content":[{"text":"first"}]}}
    malformed
    {"message":{"role":"assistant","content":[{"text":"latest"}]}}
    """.utf8).write(to: transcript)
    let input = #"{"transcript_path":"~/.claude/projects/repo/session.jsonl"}"#

    let context = try XCTUnwrap(loadClaudeContext(
      environment: ["HOME": home.path],
      standardInput: input,
      printModeDetected: false
    ))
    XCTAssertEqual(context.message, "latest")
  }

  func testClaudeRejectsTranscriptSymlinkEscapingAllowedDirectory() throws {
    let home = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appendingPathComponent(".claude/projects/repo", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let outside = home.appendingPathComponent("outside.jsonl")
    try Data(#"{"message":{"role":"assistant","content":"secret"}}"#.utf8).write(to: outside)
    let link = project.appendingPathComponent("session.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    let context = try XCTUnwrap(loadClaudeContext(
      environment: ["HOME": home.path],
      standardInput: #"{"transcript_path":"~/.claude/projects/repo/session.jsonl"}"#,
      printModeDetected: false
    ))
    XCTAssertNil(context.message)
  }

  func testDetectClaudePrintModeStopsAtFirstClaudeAncestor() {
    let processes: [Int32: (parentPID: Int32, command: String)] = [
      100: (90, "/usr/bin/env wrapper"),
      90: (80, "/opt/bin/claude --print --output-format json"),
      80: (1, "/opt/bin/claude"),
    ]
    XCTAssertTrue(detectClaudePrintMode(startPID: 100, readProcess: { processes[$0] }))
    let interactive: [Int32: (parentPID: Int32, command: String)] = [90: (1, "/opt/bin/claude")]
    XCTAssertFalse(detectClaudePrintMode(startPID: 90, readProcess: { interactive[$0] }))
  }
}

final class NotifierCLIIntegrationTests: XCTestCase {
  func testHelpAndVersionDoNotRequireTmux() throws {
    XCTAssertEqual(try NotifierCLI.run(arguments: ["--help"], environment: [:]), 0)
    XCTAssertEqual(try NotifierCLI.run(arguments: ["--version"], environment: [:]), 0)
  }

  func testDryRunUsesSwiftTmuxPipelineWithoutStartingAgent() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tmux = directory.appendingPathComponent("tmux")
    try Data("""
    #!/bin/sh
    printf '/tmp/socket\\n/dev/ttys001\\n$1\\nmain\\n@2\\n3\\n%%4\\n5\\nzsh\\n'
    """.utf8).write(to: tmux)
    XCTAssertEqual(chmod(tmux.path, 0o700), 0)

    XCTAssertEqual(try NotifierCLI.run(
      arguments: ["--dry-run", "--verbose", "--title", "Done"],
      environment: ["PATH": directory.path, "TMUX_PANE": "%4", "TERM_PROGRAM": "wezterm"]
    ), 0)
  }

  func testFocusValidatesTargetsBeforeChangingTmuxState() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = directory.appendingPathComponent("calls.log")
    let tmux = directory.appendingPathComponent("tmux")
    try Data("""
    #!/bin/sh
    printf '%s\\n' "$*" >> '\(log.path)'
    case "$*" in
      *list-windows*) printf '@2\\n' ;;
      *list-panes*) printf '%%4\\n' ;;
      *list-clients*) printf '/dev/ttys001\\n' ;;
    esac
    """.utf8).write(to: tmux)
    XCTAssertEqual(chmod(tmux.path, 0o700), 0)
    let context = TmuxContext(
      tmuxBin: tmux.path, socketPath: "/tmp/socket", clientTTY: "/dev/ttys001", sessionId: "$1",
      sessionName: "main", windowId: "@2", windowIndex: 3, paneId: "%4", paneIndex: 5,
      paneCurrentCommand: "zsh"
    )

    try NotifierCLI.focusPane(context)

    let calls = try String(contentsOf: log, encoding: .utf8)
    XCTAssertLessThan(try XCTUnwrap(calls.range(of: "list-panes")?.lowerBound), try XCTUnwrap(calls.range(of: "switch-client")?.lowerBound))
    XCTAssertTrue(calls.contains("select-window -t @2"))
    XCTAssertTrue(calls.contains("select-pane -t %4"))
  }

  func testFocusDoesNotSwitchWhenPaneDisappeared() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = directory.appendingPathComponent("calls.log")
    let tmux = directory.appendingPathComponent("tmux")
    try Data("""
    #!/bin/sh
    printf '%s\\n' "$*" >> '\(log.path)'
    case "$*" in
      *list-windows*) printf '@2\\n' ;;
      *list-panes*) printf '%%deleted\\n' ;;
    esac
    """.utf8).write(to: tmux)
    XCTAssertEqual(chmod(tmux.path, 0o700), 0)
    let context = TmuxContext(
      tmuxBin: tmux.path, socketPath: "/tmp/socket", clientTTY: "/dev/ttys001", sessionId: "$1",
      sessionName: "main", windowId: "@2", windowIndex: 3, paneId: "%4", paneIndex: 5,
      paneCurrentCommand: "zsh"
    )

    XCTAssertThrowsError(try NotifierCLI.focusPane(context))
    XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("switch-client"))
  }
}

private func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("vde-notifier-runtime-tests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
}
