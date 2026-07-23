import Foundation
import XCTest
@testable import VdeNotifierAppCore

final class NotifierCLIArgumentTests: XCTestCase {
  func testParsesSupportedOptionsAndForwardCommand() throws {
    let options = try parseNotifierCLIArguments([
      "--mode", "notify", "--title=Done", "--message", "-h", "--codex", "--skip-codex-subagent",
      "--terminal", "wezterm", "--", "/usr/bin/say", "finished",
    ])

    XCTAssertEqual(options.title, "Done")
    XCTAssertEqual(options.message, "-h")
    XCTAssertTrue(options.codex)
    XCTAssertTrue(options.skipCodexSubagent)
    XCTAssertFalse(options.help)
    XCTAssertEqual(options.forwardCommand, ForwardCommand(executable: "/usr/bin/say", arguments: ["finished"]))
  }

  func testParsesPayloadAsPositionalArgument() throws {
    let options = try parseNotifierCLIArguments(["--codex", #"{"message":"done"}"#])
    XCTAssertEqual(options.positionalArguments, [#"{"message":"done"}"#])
  }

  func testEnvironmentProvidesLogFileOnlyWhenOptionIsAbsent() throws {
    let fromEnvironment = try parseNotifierCLIArguments([], environment: ["VDE_NOTIFIER_LOG_FILE": "/tmp/env.log"])
    let explicit = try parseNotifierCLIArguments(
      ["--log-file", "/tmp/option.log"],
      environment: ["VDE_NOTIFIER_LOG_FILE": "/tmp/env.log"]
    )
    XCTAssertEqual(fromEnvironment.logFile, "/tmp/env.log")
    XCTAssertEqual(explicit.logFile, "/tmp/option.log")
  }

  func testRejectsConflictingAgentModes() {
    XCTAssertThrowsError(try parseNotifierCLIArguments(["--codex", "--claude"])) { error in
      XCTAssertEqual(error as? NotifierCLIError, .conflictingOptions("--codex", "--claude"))
    }
  }

  func testRejectsRemovedNotifierOption() {
    XCTAssertThrowsError(try parseNotifierCLIArguments(["--notifier", "terminal-notifier"]))
  }

  func testRejectsMissingValueAndBundledShortOptions() {
    XCTAssertThrowsError(try parseNotifierCLIArguments(["--title", "--verbose"]))
    XCTAssertThrowsError(try parseNotifierCLIArguments(["-hv"]))
  }

  func testBooleanNegationIsExplicit() throws {
    let options = try parseNotifierCLIArguments(["--codex", "--no-codex"])
    XCTAssertFalse(options.codex)
  }
}

final class AgentPayloadTests: XCTestCase {
  private let tmux = TmuxContext(
    tmuxBin: "/opt/homebrew/bin/tmux",
    socketPath: "/tmp/tmux.sock",
    clientTTY: "/dev/ttys001",
    sessionId: "$1",
    sessionName: "work",
    windowId: "@2",
    windowIndex: 3,
    paneId: "%4",
    paneIndex: 5,
    paneCurrentCommand: "swift"
  )

  func testCodexUsesRepositoryTitleAndMessagePriority() throws {
    let context = try XCTUnwrap(parseCodexPayload(
      #"{"last-assistant-message":"latest","last_agent_message":"older","title":"ignored"}"#,
      currentDirectory: "/tmp/my-repo",
      environment: [:]
    ))
    XCTAssertEqual(context.title, "Codex: my-repo")
    XCTAssertEqual(context.message, "latest")
  }

  func testExtractsLatestAssistantMessageAndTranscriptPart() {
    XCTAssertEqual(extractAgentMessage([
      "messages": [
        ["role": "assistant", "content": "first"],
        ["role": "user", "content": "ignored"],
        ["role": "assistant", "content": [["text": "latest"]]],
      ],
    ]), "latest")
    XCTAssertEqual(extractAgentMessage([
      "transcript": ["message": ["content": [["text": "one"], ["text": "final"]]]],
    ]), "final")
  }

  func testNormalizesSoundValues() {
    XCTAssertEqual(resolveAgentSound(["sound": true], environment: [:]), "Glass")
    XCTAssertEqual(resolveAgentSound(["sound": false], environment: [:]), "None")
    XCTAssertEqual(resolveAgentSound(["sound": 0], environment: [:]), "None")
    XCTAssertNil(resolveAgentSound(["sound": 1], environment: [:]))
    XCTAssertEqual(resolveAgentSound(["sound": "/System/Library/Sounds/Ping.aiff"], environment: [:]), "Ping")
    XCTAssertEqual(resolveAgentSound([:], environment: ["CODEX_NOTIFICATION_SOUND": "default"]), "Glass")
  }

  func testDetectsCodexTitleGeneration() {
    XCTAssertTrue(isCodexTitleGenerationPayload([
      "type": "agent-turn-complete",
      "last-assistant-message": #"{"title":"Generated"}"#,
    ]))
    XCTAssertFalse(isCodexTitleGenerationPayload([
      "type": "agent-turn-complete",
      "last-assistant-message": #"{"title":"Generated","other":true}"#,
    ]))
  }

  func testValidatesCodexThreadIdentifier() {
    XCTAssertEqual(extractCodexThreadIdentifier(["thread_id": "01234567-89ab-cdef"]), "01234567-89ab-cdef")
    XCTAssertNil(extractCodexThreadIdentifier(["thread_id": "../../sessions"]), "unsafe identifier must be rejected")
  }

  func testClaudePayloadPriorityAndNonInteractiveDetection() {
    let context = extractClaudePayloadDetails(
      [
        "notification_title": "Explicit",
        "notification_message": "Done",
        "type": "result",
        "result": "fallback",
      ],
      currentDirectory: "/tmp/repo",
      environment: [:],
      transcriptMessage: "transcript"
    )
    XCTAssertEqual(context.title, "Explicit")
    XCTAssertEqual(context.message, "Done")
    XCTAssertTrue(context.isNonInteractive)
  }

  func testClaudeStopRequiresPrintMode() {
    let payload: [String: Any] = ["hook_event_name": "Stop"]
    XCTAssertFalse(extractClaudePayloadDetails(payload, environment: [:], printModeDetected: false).isNonInteractive)
    XCTAssertTrue(extractClaudePayloadDetails(payload, environment: [:], printModeDetected: true).isNonInteractive)
  }

  func testNotificationDetailsPreferExplicitValues() {
    var options = NotifierCLIOptions()
    options.codex = true
    options.title = "Explicit title"
    options.message = "Explicit message"
    options.sound = "Ping"
    let result = notificationDetails(
      tmux: tmux,
      herdr: nil,
      options: options,
      context: AgentContext(title: "Context title", message: "Context message", sound: "Glass")
    )
    XCTAssertEqual(result, NotificationContent(title: "Explicit title", message: "Explicit message", sound: "Ping"))
  }

  func testNotificationDetailsFallbackToTmux() {
    let result = notificationDetails(tmux: tmux, herdr: nil, options: NotifierCLIOptions(), context: nil)
    XCTAssertEqual(result.title, "[work] 3.5 (%4)")
    XCTAssertEqual(result.message, "cmd: swift | tty: /dev/ttys001")
  }

  func testNotificationDetailsPreferHerdrFallbackWhenNestedInTmux() {
    let herdr = HerdrContext(
      socketPath: "/tmp/herdr.sock",
      paneId: "w2:p3",
      workspaceId: "w2",
      tabId: "w2:t1",
      label: "tests",
      agent: "codex",
      currentDirectory: "/tmp/project"
    )

    let result = notificationDetails(tmux: tmux, herdr: herdr, options: NotifierCLIOptions(), context: nil)

    XCTAssertEqual(result.title, "[Herdr] w2/w2:t1 (w2:p3)")
    XCTAssertEqual(result.message, "agent: codex | pane: tests")
  }
}

final class FocusAndEnvironmentTests: XCTestCase {
  private let payload = FocusPayload(
    tmux: TmuxContext(
      tmuxBin: "/usr/bin/tmux", socketPath: "/tmp/socket", clientTTY: "/dev/ttys001", sessionId: "$1",
      sessionName: "main", windowId: "@2", windowIndex: 3, paneId: "%4", paneIndex: 5,
      paneCurrentCommand: "zsh"
    ),
    herdr: HerdrContext(
      socketPath: "/tmp/herdr.sock",
      paneId: "w1:p2",
      workspaceId: "w1",
      tabId: "w1:t1",
      label: "agent"
    ),
    terminal: TerminalProfile(key: "wezterm", name: "WezTerm", bundleId: "com.github.wez.wezterm", source: .override)
  )

  func testFocusPayloadRoundTrip() throws {
    XCTAssertEqual(try decodeFocusPayload(encodeFocusPayload(payload)), payload)
    XCTAssertThrowsError(try decodeFocusPayload("not-base64"))
  }

  func testTerminalResolutionOrder() {
    XCTAssertEqual(
      resolveTerminalProfile(explicitKey: "wezterm", bundleOverride: nil, environment: ["TERM_PROGRAM": "kitty"]).key,
      "wezterm"
    )
    XCTAssertEqual(resolveTerminalProfile(explicitKey: nil, bundleOverride: nil, environment: ["TERM_PROGRAM": "kitty"]).key, "kitty")
    XCTAssertEqual(resolveTerminalProfile(explicitKey: nil, bundleOverride: "com.example.term", environment: [:]).key, "custom")
  }

  func testMajorTerminalEnvironmentAliases() {
    let cases: [(environment: [String: String], key: String, bundleId: String)] = [
      (["TERM_PROGRAM": "Apple_Terminal"], "terminal", "com.apple.Terminal"),
      (["TERM_PROGRAM": "iTerm.app"], "iterm", "com.googlecode.iterm2"),
      (["TERM_PROGRAM": "WarpTerminal"], "warp", "dev.warp.Warp-Stable"),
      (["TERM_PROGRAM": "vscode"], "vscode", "com.microsoft.VSCode"),
      (["TERM_PROGRAM": "zed"], "zed", "dev.zed.Zed"),
    ]

    for testCase in cases {
      let profile = resolveTerminalProfile(explicitKey: nil, bundleOverride: nil, environment: testCase.environment)
      XCTAssertEqual(profile.key, testCase.key)
      XCTAssertEqual(profile.bundleId, testCase.bundleId)
      XCTAssertEqual(profile.source, .environment)
    }
  }

  func testVSCodeVariantsAreDistinguished() {
    let agentProfile = resolveTerminalProfile(
      explicitKey: nil,
      bundleOverride: nil,
      environment: ["TERM_PROGRAM": "vscode", "CURSOR_AGENT": "1"]
    )
    XCTAssertEqual(agentProfile.key, "cursor")
    XCTAssertEqual(agentProfile.bundleId, "com.todesktop.230313mzl4w4u92")

    let integratedTerminalProfile = resolveTerminalProfile(
      explicitKey: nil,
      bundleOverride: nil,
      environment: ["TERM_PROGRAM": "vscode", "CURSOR_CLI": "/Applications/Cursor.app/Contents/MacOS/Cursor"]
    )
    XCTAssertEqual(integratedTerminalProfile.key, "cursor")

    let tracedCursorProfile = resolveTerminalProfile(
      explicitKey: nil,
      bundleOverride: nil,
      environment: ["TERM_PROGRAM": "vscode", "CURSOR_TRACE_ID": "trace-1"]
    )
    XCTAssertEqual(tracedCursorProfile.key, "cursor")

    let vscodiumProfile = resolveTerminalProfile(
      explicitKey: nil,
      bundleOverride: nil,
      environment: [
        "TERM_PROGRAM": "vscode",
        "VSCODE_GIT_ASKPASS_NODE": "/Applications/VSCodium.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler",
      ]
    )
    XCTAssertEqual(vscodiumProfile.key, "vscodium")
  }

  func testBundleIdentifierDetectsOuterTerminalInsideTmux() {
    let cases = [
      ("com.apple.Terminal", "terminal"),
      ("com.googlecode.iterm2", "iterm"),
      ("org.alacritty", "alacritty"),
      ("dev.warp.Warp-Stable", "warp"),
      ("com.microsoft.VSCode", "vscode"),
      ("com.vscodium", "vscodium"),
      ("com.todesktop.230313mzl4w4u92", "cursor"),
      ("dev.zed.Zed", "zed"),
    ]

    for (bundleIdentifier, expectedKey) in cases {
      let profile = resolveTerminalProfile(
        explicitKey: nil,
        bundleOverride: nil,
        environment: [
          "__CFBundleIdentifier": bundleIdentifier,
          "TERM_PROGRAM": "tmux",
          "TERM": "tmux-256color",
        ]
      )
      XCTAssertEqual(profile.key, expectedKey)
      XCTAssertEqual(profile.source, .environment)
    }
  }

  func testCATermStillTakesPriorityOverBundleIdentifierAndTermProgram() {
    let profile = resolveTerminalProfile(
      explicitKey: nil,
      bundleOverride: nil,
      environment: [
        "CA_TERM": "ghostty",
        "__CFBundleIdentifier": "com.microsoft.VSCode",
        "TERM_PROGRAM": "vscode",
        "CURSOR_AGENT": "1",
      ]
    )
    XCTAssertEqual(profile.key, "ghostty")
  }

  func testAppleScriptEscapesUntrustedBundleIdentifier() {
    let script = terminalFrontmostScript(bundleIdentifier: "bad\"\nidentifier")
    XCTAssertTrue(script.contains(#""bad\" identifier""#))
    XCTAssertTrue(script.contains("NotificationCenter"))
  }

  func testTmuxResponseParsing() throws {
    let output = "/tmp/socket\n/dev/ttys001\n$1\nmain\n@2\n3\n%4\n5\nzsh\n"
    XCTAssertEqual(try parseTmuxContext(output: output, tmuxBinary: "/usr/bin/tmux"), try XCTUnwrap(payload.tmux))
    XCTAssertThrowsError(try parseTmuxContext(output: output.replacingOccurrences(of: "\n3\n", with: "\n3x\n"), tmuxBinary: "/usr/bin/tmux"))
  }

  func testTmuxTargetPaneIsOptional() {
    XCTAssertEqual(tmuxContextArguments(targetPane: "%2").prefix(4), ["display-message", "-p", "-t", "%2"])
    XCTAssertFalse(tmuxContextArguments(targetPane: nil).contains("-t"))
  }

  func testMessageTruncationUsesGraphemeClusters() {
    let family = "👨‍👩‍👧‍👦"
    let message = String(repeating: family, count: 101)
    XCTAssertEqual(truncateNotificationMessage(message).count, 100)
    XCTAssertEqual(truncateNotificationMessage("-flag"), " -flag")
  }
}
