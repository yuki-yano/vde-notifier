import Darwin
import Foundation
import VdeNotifierAppCore

enum HerdrAPIError: Error, CustomStringConvertible {
  case invalidEnvironment(String)
  case invalidResponse(String)
  case requestFailed(code: String, message: String)

  var description: String {
    switch self {
    case let .invalidEnvironment(message):
      return "Invalid Herdr environment: \(message)"
    case let .invalidResponse(message):
      return "Invalid Herdr API response: \(message)"
    case let .requestFailed(code, message):
      return "Herdr API request failed (\(code)): \(message)"
    }
  }
}

private struct HerdrRequest: Encodable {
  let id: String
  let method: String
  let params: [String: String]
}

private struct HerdrResponse: Decodable {
  struct Result: Decodable {
    let type: String
    let pane: Pane?
  }

  struct Pane: Decodable {
    let paneId: String
    let workspaceId: String
    let tabId: String
    let cwd: String?
    let foregroundCwd: String?
    let label: String?
    let agent: String?
    let displayAgent: String?
    let title: String?
    let terminalTitle: String?
    let terminalTitleStripped: String?

    enum CodingKeys: String, CodingKey {
      case paneId = "pane_id"
      case workspaceId = "workspace_id"
      case tabId = "tab_id"
      case cwd
      case foregroundCwd = "foreground_cwd"
      case label
      case agent
      case displayAgent = "display_agent"
      case title
      case terminalTitle = "terminal_title"
      case terminalTitleStripped = "terminal_title_stripped"
    }
  }

  struct Failure: Decodable {
    let code: String
    let message: String
  }

  let id: String
  let result: Result?
  let error: Failure?
}

struct HerdrAPIClient {
  let socketPath: String
  var timeout: TimeInterval = 2.0

  func paneContext(paneId: String) throws -> HerdrContext {
    let pane = try requestPane(method: "pane.get", paneId: paneId)
    return HerdrContext(
      socketPath: socketPath,
      paneId: pane.paneId,
      workspaceId: pane.workspaceId,
      tabId: pane.tabId,
      label: nonEmptyString(pane.label),
      agent: nonEmptyString(pane.displayAgent) ?? nonEmptyString(pane.agent),
      title: nonEmptyString(pane.title)
        ?? nonEmptyString(pane.terminalTitleStripped)
        ?? nonEmptyString(pane.terminalTitle),
      currentDirectory: nonEmptyString(pane.foregroundCwd) ?? nonEmptyString(pane.cwd)
    )
  }

  func focus(paneId: String) throws {
    _ = try requestPane(method: "pane.focus", paneId: paneId)
  }

  private func requestPane(method: String, paneId: String) throws -> HerdrResponse.Pane {
    guard socketPath.hasPrefix("/") else {
      throw HerdrAPIError.invalidEnvironment("HERDR_SOCKET_PATH must be absolute")
    }
    let requestId = "vde-notifier:\(method):\(UUID().uuidString)"
    let request = HerdrRequest(id: requestId, method: method, params: ["pane_id": paneId])
    let fd = try connectUnixSocket(path: socketPath)
    defer { Darwin.close(fd) }
    try setSocketTimeout(on: fd, seconds: timeout)
    try writeSocketLine(JSONEncoder().encode(request), to: fd)

    let response: HerdrResponse
    do {
      response = try JSONDecoder().decode(HerdrResponse.self, from: readSocketLine(from: fd))
    } catch let error as HerdrAPIError {
      throw error
    } catch {
      throw HerdrAPIError.invalidResponse(error.localizedDescription)
    }
    guard response.id == requestId else {
      throw HerdrAPIError.invalidResponse("unexpected request ID: \(response.id)")
    }
    if let failure = response.error {
      throw HerdrAPIError.requestFailed(code: failure.code, message: failure.message)
    }
    guard let result = response.result, result.type == "pane_info", let pane = result.pane else {
      throw HerdrAPIError.invalidResponse("expected pane_info result")
    }
    guard pane.paneId == paneId else {
      throw HerdrAPIError.invalidResponse("unexpected pane ID: \(pane.paneId)")
    }
    return pane
  }
}

func loadHerdrContext(environment: [String: String]) throws -> HerdrContext? {
  guard let paneId = nonEmptyString(environment["HERDR_PANE_ID"]) else {
    return nil
  }
  guard let socketPath = nonEmptyString(environment["HERDR_SOCKET_PATH"]) else {
    throw HerdrAPIError.invalidEnvironment("HERDR_SOCKET_PATH is required when HERDR_PANE_ID is set")
  }
  guard socketPath.hasPrefix("/") else {
    throw HerdrAPIError.invalidEnvironment("HERDR_SOCKET_PATH must be absolute")
  }
  return try HerdrAPIClient(socketPath: socketPath).paneContext(paneId: paneId)
}
