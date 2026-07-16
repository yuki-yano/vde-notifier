import Foundation

struct ProcessResult: Equatable {
  let status: Int32
  let standardOutput: String
  let standardError: String
}

enum ProcessRunnerError: Error, CustomStringConvertible {
  case launch(executable: String, message: String)
  case failed(executable: String, status: Int32, standardError: String)

  var description: String {
    switch self {
    case let .launch(executable, message):
      return "Failed to launch \(executable): \(message)"
    case let .failed(executable, status, standardError):
      let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      return detail.isEmpty
        ? "Command failed with status \(status): \(executable)"
        : "Command failed with status \(status): \(executable): \(detail)"
    }
  }
}

enum ProcessRunner {
  static func capture(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil
  ) throws -> ProcessResult {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("vde-notifier-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let stdoutURL = directory.appendingPathComponent("stdout")
    let stderrURL = directory.appendingPathComponent("stderr")
    guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
          FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw ProcessRunnerError.launch(executable: executable, message: "Unable to create output files")
    }

    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    do {
      try process.run()
      process.waitUntilExit()
      try stdoutHandle.close()
      try stderrHandle.close()
    } catch {
      try? stdoutHandle.close()
      try? stderrHandle.close()
      throw ProcessRunnerError.launch(executable: executable, message: error.localizedDescription)
    }

    let standardOutput = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
    let standardError = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
    return ProcessResult(status: process.terminationStatus, standardOutput: standardOutput, standardError: standardError)
  }

  static func requireSuccess(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil
  ) throws -> ProcessResult {
    let result = try capture(executable: executable, arguments: arguments, environment: environment)
    guard result.status == 0 else {
      throw ProcessRunnerError.failed(executable: executable, status: result.status, standardError: result.standardError)
    }
    return result
  }

  static func inherit(executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw ProcessRunnerError.launch(executable: executable, message: error.localizedDescription)
    }
    guard process.terminationStatus == 0 else {
      throw ProcessRunnerError.failed(executable: executable, status: process.terminationStatus, standardError: "")
    }
  }
}

func resolveExecutable(_ command: String, environment: [String: String]) throws -> String {
  if command.hasPrefix("/") {
    guard FileManager.default.isExecutableFile(atPath: command) else {
      throw ProcessRunnerError.launch(executable: command, message: "Command is not executable")
    }
    return command
  }
  for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  throw ProcessRunnerError.launch(executable: command, message: "Unable to locate command on PATH")
}
