# vde-notifier

vde-notifier is a Swift-based, tmux- and [Herdr](https://herdr.dev/)-aware notification CLI for macOS. It reports long-running pane completions and returns you to the exact multiplexer pane when you click the notification.

The CLI and the resident notification agent are distributed together in one app bundle. Node.js, Bun, npm, and pnpm are not required.

## Requirements

- macOS 14 or later
- tmux or Herdr 0.7.5 or later

The distributed app contains universal `arm64` and `x86_64` binaries.

## Install

```bash
brew install --cask yuki-yano/vde-notifier/vde-notifier-app
```

The Cask installs two commands:

- `vde-notifier`: user-facing notification and focus CLI
- `vde-notifier-app`: resident agent management and diagnostics

Verify the installation:

```bash
vde-notifier --version
vde-notifier-app doctor
vde-notifier-app agent status
```

## Basic usage

Run inside tmux or a Herdr pane:

```bash
vde-notifier --title "Build finished" --message "Done" --sound Ping
```

Clicking the notification performs the following operations:

1. Revalidates the original Herdr pane and/or tmux session, window, pane, and client.
2. Focuses the original multiplexer pane. When Herdr runs inside tmux, both layers are restored.
3. Activates the original terminal application.

## CLI options

- `--title <string>`: notification title. Defaults to the current Herdr or tmux pane identity.
- `--message <string>`: notification body. Defaults to the current Herdr pane metadata or tmux command and client TTY.
- `--sound <name>`: macOS system sound, such as `Glass` or `Ping`. Use `None` for silence.
- `--codex`: parses a Codex notification payload.
- `--skip-codex-subagent`: skips Codex subagent turns.
- `--skip-codex-non-interactive`: skips Codex exec/review turns.
- `--claude`: parses a Claude Code hook payload from stdin.
- `--skip-claude-non-interactive`: skips Claude non-interactive payloads.
- `--terminal <profile>`: forces a terminal profile.
- `--term-bundle-id <bundleId>`: overrides the terminal bundle identifier.
- `--dry-run`: resolves the notification without sending it.
- `--verbose`: writes structured diagnostics.
- `--log-file <path>`: appends JSON Lines diagnostics.
- `-- <command> [args...]`: runs another command after notification processing.
- `--help`, `-h`: shows usage.
- `--version`, `-v`: shows the app version.

Short option bundling, such as `-hv`, is intentionally unsupported.

Environment overrides:

- `VDE_NOTIFIER_TERMINAL`: default terminal profile
- `VDE_NOTIFIER_LOG_FILE`: default diagnostics file
- `CODEX_NOTIFICATION_PAYLOAD`: Codex payload when it is not passed as an argument
- `CODEX_NOTIFICATION_SOUND`: Codex sound override when the payload omits `sound`

Supported terminal aliases are `terminal`, `apple-terminal`, `mac-terminal`, `apple_terminal`, `iterm`, `iterm2`, `iterm.app`, `alacritty`, `kitty`, `wezterm`, `hyper`, `ghostty`, `warp`, `warpterminal`, `vscode`, `visual-studio-code`, `code`, `vscodium`, `codium`, `cursor`, and `zed`.

Every cataloged terminal is detected automatically from `CA_TERM`, its macOS bundle identifier, `TERM_PROGRAM`, or `TERM`, in that priority order. This also works when tmux replaces `TERM_PROGRAM` with `tmux`. VS Code variants are distinguished by their bundle identifier or, where available, app-specific environment markers.

## Herdr integration

No Herdr-specific configuration is required. Herdr injects `HERDR_SOCKET_PATH` and `HERDR_PANE_ID` into managed panes; vde-notifier uses them to capture the pane and sends `pane.focus` to the same local Herdr session when the notification is clicked.

The normal Codex and Claude integrations work unchanged when their agent runs in a Herdr pane.

## Codex integration

Add the native command to `~/.codex/config.toml`:

```toml
notify = ["vde-notifier", "--codex"]
```

Payload resolution order is:

1. A positional JSON argument
2. `CODEX_NOTIFICATION_PAYLOAD`
3. stdin

Codex notifications use the repository-scoped title `Codex: <repo-name>`. Title-generation turns are skipped automatically. The optional subagent and non-interactive checks inspect the matching rollout metadata under `~/.codex/sessions`.

To run another command with the resolved payload:

```toml
notify = ["vde-notifier", "--codex", "--", "other-command"]
```

The resolved payload is appended to the forwarded arguments unless it is already present.

## Claude Code integration

Add a Stop hook to `~/.config/claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "vde-notifier --claude"
          }
        ]
      }
    ]
  }
}
```

When `transcript_path` is present, vde-notifier reads the latest assistant message from transcripts located below `~/.claude/projects` or `~/.config/claude/projects`. Paths outside those directories are rejected.

## Agent commands

```bash
vde-notifier-app agent run
vde-notifier-app agent start
vde-notifier-app agent status
vde-notifier-app doctor
```

`doctor` reports agent reachability, notification authorization lookup, persistent action-store access, and runtime paths.

The low-level notification command is available for diagnostics:

```bash
vde-notifier-app notify \
  --title "Smoke test" \
  --message "Click me" \
  --sound Ping \
  --action-exec /usr/bin/say \
  --action-arg clicked
```

## Development

```bash
# tests
env -u LIBRARY_PATH swift test \
  --package-path app/vde-notifier-app \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

# debug build
env -u LIBRARY_PATH swift build \
  --package-path app/vde-notifier-app \
  --product vde-notifier-app

# universal app bundle
app/vde-notifier-app/scripts/build-app.sh

# release archive
app/vde-notifier-app/scripts/create-release-asset.sh
```

## Release

App and CLI releases use one `app-v*` tag:

```bash
git tag app-v0.2.0
git push origin app-v0.2.0
```

The `release-vde-notifier-app` workflow:

1. Runs strict Swift tests.
2. Builds and verifies the universal app containing both commands.
3. Publishes `VdeNotifierApp.app.tar.gz` to the GitHub release.
4. Dispatches the version and SHA256 to `yuki-yano/homebrew-vde-notifier`.

The repository secret `HOMEBREW_TAP_DISPATCH_TOKEN` must have write access to the tap repository.

## Troubleshooting

- Command missing: reinstall with `brew install --cask yuki-yano/vde-notifier/vde-notifier-app`.
- Notification permission unknown: run `vde-notifier-app doctor` and inspect `authorization_check`.
- Notification click does nothing: use `--verbose --log-file <path>` and confirm terminal Automation permission.
- Herdr or tmux target disappeared: the focus action fails safely before switching to another available target.

The app uses agent protocol v2. Replace the complete app bundle during upgrades so the command client and resident agent remain on the same protocol version.
