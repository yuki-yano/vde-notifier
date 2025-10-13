# vde-notifier

vde-notifier is a tmux-aware notification CLI for macOS. It surfaces long-running pane completions, plays a sound, and returns you to the exact session/window/pane with a single notification click.

## Quick Start

1. Install prerequisites:

- macOS 14 or later
- `tmux`, `terminal-notifier` (default notifier) — optionally `swiftDialog`
- Node.js 20+ or Bun 1.1+
- `pnpm`

```bash
brew install terminal-notifier
# optional: install swiftDialog via Homebrew tap
brew install yuki-yano/swiftdialog/swift-dialog
#   (or download the official pkg from https://github.com/swiftDialog/swiftDialog/releases)
```

2. Run the CLI without installing (choose one):

```bash
bun x vde-notifier@latest      # recommended
npx vde-notifier@latest
pnpm dlx vde-notifier@latest
```

(Optional) Install globally if you prefer a persistent binary:

```bash
bun install --global vde-notifier@latest
npm install -g vde-notifier@latest
pnpm add -g vde-notifier@latest
```

3. Inside tmux, trigger a notification when your pane finishes work:

```bash
vde-notifier --title "Build finished" --message "webpack completed"
```

4. Click the macOS notification. vde-notifier will:

- Play the selected sound (default: Glass)
- Bring your terminal frontmost
- Focus the matching tmux client/session/window/pane

## CLI Options

- `--title <string>`: Override the notification title. Defaults to `[session] window.pane (%paneId)`.
- `--message <string>`: Override the notification body. Defaults to `cmd: <paneCurrentCommand> | tty: <clientTTY>`.
- `--sound <name>`: macOS system sound (for example, `Glass`, `Ping`). Use `None` for silence.
- `--codex`: Consume Codex-style JSON (see below) from a trailing argument (or `CODEX_NOTIFICATION_PAYLOAD`) and build the notification from it.
- `--claude`: Consume Claude Code JSON piped on stdin (supports `transcript_path` to pull the latest assistant reply).
- `--terminal <profile>`: Force a terminal profile (alacritty, wezterm, ghostty, etc.).
- `--term-bundle-id <bundleId>`: Override the bundle identifier when auto detection is insufficient.
- `--notifier <terminal-notifier|swiftdialog>`: Switch the notification backend. Defaults to `terminal-notifier`.
- `--dry-run`: Skips sending a notification. Combine with `--verbose` to print the gathered tmux metadata and focus command.
- `--verbose`: Emits JSON logs describing notify and focus stages.

When `--notifier swiftdialog` is selected, vde-notifier plays the requested sound locally and then sends `dialog --notification ...` with a primary action wired to the focus command. Clicking the notification will restore the tmux pane.

Environment overrides:

- `VDE_NOTIFIER_TERMINAL=alacritty` sets the default terminal profile when `--terminal` is omitted.
  Valid aliases: `terminal`, `apple-terminal`, `mac-terminal`, `iterm`, `iterm2`, `alacritty`, `kitty`, `wezterm`, `hyper`, `ghostty` (non-matching values fall back to Terminal.app).

## Typical Workflow

1. Export a preferred terminal profile:

```bash
export VDE_NOTIFIER_TERMINAL=alacritty
```

2. From tmux, run a long task and send a notification on completion:

```bash
make build && vde-notifier --title "Build" --message "Done" --sound Ping
```

3. When the notification appears, click it. Even if Alacritty already has focus, vde-notifier will:

- Run tmux `switch-client`, `select-window`, `select-pane`
- Activate Alacritty through macOS Automation and make sure it is frontmost
- Preserve IME focus for immediate typing

## Using from AI Agents (Claude Code, Codex, etc.)

Many hosted IDE agents run inside tmux. You can add a notification step after long tasks so the human operator gets paged immediately:

### Agent JSON Input

vde-notifier hydrates notifications from agent payloads in two ways:

- `--codex`: pass a Codex-style JSON payload as the final argument (the format used by hosted Codex agents). You can also preload the same JSON via `CODEX_NOTIFICATION_PAYLOAD`.
- `--claude`: pipe Claude Code's JSON payload to stdin. If the payload contains `transcript_path`, vde-notifier opens the referenced transcript JSONL file and uses the latest assistant message.

Codex notifications always use the repository-scoped title `Codex: <repo-name>`, ignoring payload-provided titles. Claude notifications fall back to `Claude: <repo-name>` when no explicit title is supplied.

For either flag the CLI looks for:

- Title (`notification-title`, `notification_title`, `title`)
- The most recent assistant message (from `notification-message`, `notification_message`, `last-assistant-message`, `message`, `messages`, `transcript`, or Claude transcripts)
- Sound (`sound`, respecting `none`, `default`, or full paths such as `/System/Library/Sounds/Ping.aiff`)

To enable automatic notifications from Codex CLI/agents, add the following to `~/.codex/config.toml`:

```toml
notify = ["bun", "x", "vde-notifier@latest", "--codex"]
```

For Claude Code (Claude Desktop) projects, add a Stop hook to `~/.config/claude/settings.json` so every long-running tool run triggers a notification when it finishes:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bun x vde-notifier@latest --claude"
          }
        ]
      }
    ]
  }
}
```

## Troubleshooting

- **No sound**: Ensure the sound name matches a file in `/System/Library/Sounds/` and is not set to `None`.
- **Notification click does nothing**: Run with `--verbose` to inspect payload and focus command. Confirm `osascript` automation permission is granted.
- **Slow focus switch**: By default tmux commands run first, then the terminal is frontmost. If delays persist, check that Notification Center closes promptly and that tmux socket is reachable.
- **Running from `bunx dlx` or AI agents**: If launched via package runners, vde-notifier reuses the current `process.execPath` so focus mode can start without PATH access.

## Development Notes (Optional)

- Install dependencies: `pnpm install`
- Lint: `pnpm run lint`
- Test: `pnpm run test`
- Build: `pnpm run build`
- Watch build: `pnpm run dev`
