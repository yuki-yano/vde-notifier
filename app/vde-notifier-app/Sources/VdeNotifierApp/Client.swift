import Darwin
import Foundation
import VdeNotifierAppCore

enum ClientError: Error, CustomStringConvertible {
  case agentStartFailed
  case invalidResponse(String)
  case notificationFailed(code: String, message: String)

  var description: String {
    switch self {
    case .agentStartFailed:
      return "Failed to start notification agent"
    case let .invalidResponse(message):
      return "Invalid response from agent: \(message)"
    case let .notificationFailed(code, message):
      return "Notification request failed (\(code)): \(message)"
    }
  }
}

struct AgentClient {
  let socketPath: String

  func send(_ request: NotifyRequest) throws -> AgentResponse {
    let fd = try connectUnixSocket(path: socketPath)
    defer { Darwin.close(fd) }

    let requestData = try encodeNotifyRequest(request)
    try writeAll(requestData, to: fd)
    Darwin.shutdown(fd, SHUT_WR)

    let responseData = try readAll(from: fd)
    do {
      return try decodeAgentResponse(responseData)
    } catch {
      throw ClientError.invalidResponse(String(describing: error))
    }
  }
}

enum AgentBootstrap {
  static func ensureRunning(socketPath: String, timeout: TimeInterval = 3.0) throws {
    if socketExistsAndReachable(path: socketPath) {
      return
    }

    try launchAgent()

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if socketExistsAndReachable(path: socketPath) {
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }

    throw ClientError.agentStartFailed
  }

  private static func launchAgent() throws {
    if let appURL = resolveAppBundleURL() {
      let openProcess = Process()
      openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      openProcess.arguments = ["-g", appURL.path]
      try openProcess.run()
      openProcess.waitUntilExit()
      if openProcess.terminationStatus == 0 {
        return
      }
    }

    guard let executablePath = resolveCurrentExecutablePath() else {
      throw ClientError.agentStartFailed
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = ["agent", "run"]
    process.standardInput = nil
    process.standardOutput = nil
    process.standardError = nil
    try process.run()
  }

  private static func resolveAppBundleURL() -> URL? {
    let bundleURL = Bundle.main.bundleURL
    if bundleURL.pathExtension == "app" {
      return bundleURL
    }

    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let path = executableURL.path
    guard let range = path.range(of: "/Contents/MacOS/") else {
      return nil
    }

    let appPath = String(path[..<range.lowerBound])
    guard appPath.hasSuffix(".app") else {
      return nil
    }
    return URL(fileURLWithPath: appPath)
  }

  private static func resolveCurrentExecutablePath() -> String? {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    guard size > 0 else {
      return nil
    }

    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
      return nil
    }

    let nullIndex = buffer.firstIndex(of: 0) ?? buffer.count
    let bytes = buffer[0..<nullIndex].map { UInt8(bitPattern: $0) }
    let rawPath = String(decoding: bytes, as: UTF8.self)
    let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
    if FileManager.default.isExecutableFile(atPath: resolved) {
      return resolved
    }

    return nil
  }
}
