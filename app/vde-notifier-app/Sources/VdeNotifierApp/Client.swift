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
  var timeout: TimeInterval = 2.0

  func send(_ request: NotifyRequest) throws -> AgentResponse {
    let fd = try connectUnixSocket(path: socketPath)
    defer { Darwin.close(fd) }
    try setSocketTimeout(on: fd, seconds: timeout)

    let requestData = try encodeNotifyRequest(request)
    try writeFrame(requestData, to: fd)

    let responseData = try readFrame(from: fd)
    do {
      return try decodeAgentResponse(responseData)
    } catch {
      throw ClientError.invalidResponse(String(describing: error))
    }
  }

  func ping() -> Bool {
    do {
      let fd = try connectUnixSocket(path: socketPath)
      defer { Darwin.close(fd) }
      try setSocketTimeout(on: fd, seconds: timeout)
      try writeFrame(try encodePingRequest(), to: fd)
      let response = try decodeAgentResponse(readFrame(from: fd))
      return response.ok && response.code == "pong"
    } catch {
      return false
    }
  }
}

enum AgentBootstrap {
  static func ensureRunning(socketPath: String, timeout: TimeInterval = 3.0) throws {
    if isRunning(socketPath: socketPath) {
      return
    }

    try launchAgent()

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if isRunning(socketPath: socketPath) {
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }

    throw ClientError.agentStartFailed
  }

  static func isRunning(socketPath: String) -> Bool {
    AgentClient(socketPath: socketPath).ping()
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

    let executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
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
