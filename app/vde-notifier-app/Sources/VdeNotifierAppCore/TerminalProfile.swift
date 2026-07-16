import Foundation

private struct TerminalDescriptor {
  let name: String
  let bundleIdentifier: String
  let aliases: [String]
}

private let terminalCatalog: [String: TerminalDescriptor] = [
  "terminal": .init(name: "Terminal.app", bundleIdentifier: "com.apple.Terminal", aliases: ["terminal", "apple-terminal", "mac-terminal"]),
  "iterm": .init(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", aliases: ["iterm", "iterm2"]),
  "alacritty": .init(name: "Alacritty", bundleIdentifier: "org.alacritty", aliases: ["alacritty"]),
  "kitty": .init(name: "kitty", bundleIdentifier: "net.kovidgoyal.kitty", aliases: ["kitty"]),
  "wezterm": .init(name: "WezTerm", bundleIdentifier: "com.github.wez.wezterm", aliases: ["wezterm"]),
  "hyper": .init(name: "Hyper", bundleIdentifier: "co.zeit.hyper", aliases: ["hyper"]),
  "ghostty": .init(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty", aliases: ["ghostty"]),
]

private func terminalKey(alias: String) -> String? {
  let value = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  return terminalCatalog.first { $0.value.aliases.contains(value) }?.key
}

private func terminalKey(bundleIdentifier: String) -> String? {
  let value = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  return terminalCatalog.first { $0.value.bundleIdentifier.lowercased() == value }?.key
}

private func makeTerminalProfile(key: String, source: TerminalProfileSource) -> TerminalProfile {
  let resolvedKey = terminalCatalog[key] == nil ? "terminal" : key
  let descriptor = terminalCatalog[resolvedKey]!
  return TerminalProfile(key: resolvedKey, name: descriptor.name, bundleId: descriptor.bundleIdentifier, source: source)
}

public func resolveTerminalProfile(
  explicitKey: String?,
  bundleOverride: String?,
  environment: [String: String]
) -> TerminalProfile {
  if let override = nonEmptyString(bundleOverride) {
    if let key = terminalKey(bundleIdentifier: override) { return makeTerminalProfile(key: key, source: .override) }
    return TerminalProfile(key: "custom", name: override, bundleId: override, source: .override)
  }
  if let explicit = nonEmptyString(explicitKey) {
    if let key = terminalKey(alias: explicit) ?? terminalKey(bundleIdentifier: explicit) {
      return makeTerminalProfile(key: key, source: .override)
    }
    return TerminalProfile(key: "custom", name: explicit, bundleId: explicit, source: .override)
  }
  for key in ["CA_TERM", "TERM_PROGRAM", "TERM"] {
    if let value = environment[key], let profileKey = terminalKey(alias: value) {
      return makeTerminalProfile(key: profileKey, source: .environment)
    }
  }
  return makeTerminalProfile(key: "terminal", source: .default)
}

public func appleScriptQuoted(_ value: String) -> String {
  let escaped = value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\r", with: " ")
    .replacingOccurrences(of: "\n", with: " ")
  return "\"\(escaped)\""
}

public func terminalFrontmostScript(bundleIdentifier: String) -> String {
  let quoted = appleScriptQuoted(bundleIdentifier)
  return """
  tell application "System Events"
    try
      if name of processes contains "NotificationCenter" then
        tell process "NotificationCenter" to set frontmost to false
      end if
    end try
    repeat with proc in processes
      try
        if bundle identifier of proc is \(quoted) then
          set frontmost of proc to true
          exit repeat
        end if
      end try
    end repeat
  end tell
  """
}
