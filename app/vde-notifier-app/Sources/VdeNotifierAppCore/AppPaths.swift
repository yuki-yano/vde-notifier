import Foundation

public enum AppPaths {
  public static let appName = "vde-notifier-app"

  public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent(appName, isDirectory: true)
  }

  public static func socketURL(fileManager: FileManager = .default) -> URL {
    applicationSupportDirectory(fileManager: fileManager)
      .appendingPathComponent("agent.sock", isDirectory: false)
  }

  public static func actionsURL(fileManager: FileManager = .default) -> URL {
    applicationSupportDirectory(fileManager: fileManager)
      .appendingPathComponent("actions.json", isDirectory: false)
  }

  public static func logsDirectory(fileManager: FileManager = .default) -> URL {
    applicationSupportDirectory(fileManager: fileManager)
      .appendingPathComponent("logs", isDirectory: true)
  }

  public static func agentLogURL(fileManager: FileManager = .default) -> URL {
    logsDirectory(fileManager: fileManager)
      .appendingPathComponent("agent.log", isDirectory: false)
  }
}
