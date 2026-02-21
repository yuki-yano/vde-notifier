# vde-notifier

vde-notifier is a tmux-aware notification CLI for macOS. It surfaces long-running pane completions, plays a sound, and returns you to the exact session/window/pane with a single notification click.

## Quick Start

1. Install prerequisites:

- macOS 14 or later
- `tmux`, `vde-notifier-app` (default notifier)
- Node.js 22+ or Bun 1.1+
- `pnpm`

`vde-notifier` is published as a macOS-only npm package (`os: darwin`, `engines.node: >=22`).

```bash
# install default notifier backend
brew tap yuki-yano/vde-notifier
brew install --cask yuki-yano/vde-notifier/vde-notifier-app
# optional fallback notifier backends
brew install terminal-notifier
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
- `--codex`: Consume Codex-style JSON (see below) from a trailing argument, `CODEX_NOTIFICATION_PAYLOAD`, or stdin (in that priority order) and build the notification from it.
- `--skip-codex-subagent`: Skip sending notifications when Codex payload belongs to a subagent turn (`thread-id` lookup from `~/.codex/sessions`).
- `--claude`: Consume Claude Code JSON piped on stdin (supports `transcript_path` to pull the latest assistant reply).
- `--terminal <profile>`: Force a terminal profile (alacritty, wezterm, ghostty, etc.).
- `--term-bundle-id <bundleId>`: Override the bundle identifier when auto detection is insufficient.
- `--notifier <terminal-notifier|swiftdialog|vde-notifier-app>`: Switch the notification backend. Defaults to `vde-notifier-app`.
- `--dry-run`: Skips sending a notification. Combine with `--verbose` to print the gathered tmux metadata and focus command.
- `--verbose`: Emits JSON logs describing notify and focus stages.
- `--log-file <path>`: Appends the same JSON diagnostics to the given file (one JSON object per line). Also propagates to focus-mode invocations.
- `--help`, `-h`: Show usage.
- `--version`, `-v`: Show CLI version.

Short option bundling (for example, `-hv`) is intentionally unsupported.

When `--notifier swiftdialog` is selected, vde-notifier plays the requested sound locally and then sends `dialog --notification ...` with a primary action wired to the focus command. Clicking the notification will restore the tmux pane.

When `--notifier vde-notifier-app` is selected, vde-notifier calls the local Swift agent (`vde-notifier-app notify ...`) with action executable and arguments so notification clicks can restore the tmux pane without shell interpolation.

## Using `vde-notifier-app` via Cask

1. Install the app:

```bash
brew tap yuki-yano/vde-notifier
brew install --cask yuki-yano/vde-notifier/vde-notifier-app
```

2. Verify runtime health:

```bash
vde-notifier-app doctor
vde-notifier-app agent status
```

3. Send notifications through the Swift backend (default):

```bash
vde-notifier --title "Build finished" --message "Done" --sound Ping
```

4. Optional smoke test for the app binary directly:

```bash
vde-notifier-app notify --title "swift smoke" --message "click me" --sound Ping --action-exec /usr/bin/say --action-arg "clicked"
```

Environment overrides:

- `VDE_NOTIFIER_TERMINAL=alacritty` sets the default terminal profile when `--terminal` is omitted.
  Valid aliases: `terminal`, `apple-terminal`, `mac-terminal`, `iterm`, `iterm2`, `alacritty`, `kitty`, `wezterm`, `hyper`, `ghostty` (non-matching values fall back to Terminal.app).
- `VDE_NOTIFIER_LOG_FILE=/path/to/diagnostics.log` mirrors `--log-file` so every run writes diagnostics even without passing the CLI flag.

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

- `--codex`: pass a Codex-style JSON payload as the final argument (the format used by hosted Codex agents). You can also preload the same JSON via `CODEX_NOTIFICATION_PAYLOAD`; if neither is present, stdin is used.
- `--claude`: pipe Claude Code's JSON payload to stdin. If the payload contains `transcript_path`, vde-notifier opens the referenced transcript JSONL file and uses the latest assistant message.

Codex notifications always use the repository-scoped title `Codex: <repo-name>`, ignoring payload-provided titles. Claude notifications fall back to `Claude: <repo-name>` when no explicit title is supplied.
If either payload is malformed JSON, the command exits with a non-zero status.

For either flag the CLI looks for:

- Title (`notification-title`, `notification_title`, `title`)
- The most recent assistant message (from `notification-message`, `notification_message`, `last-assistant-message`, `message`, `messages`, `transcript`, or Claude transcripts)
- Sound (`sound`, respecting `none`, `default`, or full paths such as `/System/Library/Sounds/Ping.aiff`)
- Codex thread id (`thread-id`, `thread_id`, `threadId`) to support `--skip-codex-subagent`

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

## Release Flows (GitHub Actions)

NPM publish and app/cask release are separated.

### NPM publish

Workflow:

- `.github/workflows/publish.yml`

Trigger:

- Push a tag with `npm-v*` (example: `npm-v0.1.1`)
- The tag version must match `package.json` (for example, `npm-v0.1.1` with `"version": "0.1.1"`).

Example:

```bash
git tag npm-v0.1.1
git push origin npm-v0.1.1
```

`publish.yml` also verifies that the target version is not already on npm and publishes with provenance (`npm publish --provenance`).

### App/cask release

`vde-notifier-app` cask distribution expects this fixed asset name on `yuki-yano/vde-notifier` releases:

- `VdeNotifierApp.app.tar.gz`

Release automation is defined in:

- `.github/workflows/release-vde-notifier-app.yml`

The workflow:

1. Builds the Swift app release asset.
2. Uploads/replaces `VdeNotifierApp.app.tar.gz` on the target release tag.
3. Computes SHA256 for the uploaded asset.
4. Sends `repository_dispatch` to `yuki-yano/homebrew-vde-notifier` so cask `version` and `sha256` are updated automatically.

Repository secret required in `yuki-yano/vde-notifier`:

- `HOMEBREW_TAP_DISPATCH_TOKEN`: token with write permission to `yuki-yano/homebrew-vde-notifier`.

### Standard release flow

1. Create and push an app tag:

```bash
git tag app-v0.1.1
git push origin app-v0.1.1
```

2. Wait for `release-vde-notifier-app` workflow to complete.
3. Confirm the release contains `VdeNotifierApp.app.tar.gz`.
4. Confirm `yuki-yano/homebrew-vde-notifier` receives an `update-cask` run and commits updated `version`/`sha256`.

### Manual rerun flow

If you need to regenerate the asset for an existing tag, run the workflow manually (`workflow_dispatch`) and set:

- `tag`: `app-v0.1.1` (existing app tag)

If tap update does not run automatically, manually trigger `update-cask.yml` in
`yuki-yano/homebrew-vde-notifier` with the same app version (without `app-v`)
and the SHA256 of `VdeNotifierApp.app.tar.gz`.

### Local pre-check

Before tagging, you can build the exact release asset locally:

```bash
pnpm run swift:release-asset
```

## Troubleshooting

- **No sound**: Ensure the sound name matches a file in `/System/Library/Sounds/` and is not set to `None`.
- **`vde-notifier-app` command is missing**: Install the default notifier backend:
  `brew tap yuki-yano/vde-notifier && brew install --cask yuki-yano/vde-notifier/vde-notifier-app`
- **Notification click does nothing**: Run with `--verbose` to inspect payload and focus command. Confirm `osascript` automation permission is granted.
- **`vde-notifier-app doctor` stays `notDetermined`**: Rebuild the app bundle (`pnpm run swift:app`) and verify the signature identifier (`codesign -dv --verbose=4 build/VdeNotifierApp.app 2>&1 | rg '^Identifier='`) is `com.yuki-yano.vde-notifier-app.agent`.
- **Slow focus switch**: By default tmux commands run first, then the terminal is frontmost. If delays persist, check that Notification Center closes promptly and that tmux socket is reachable.
- **Running from `bunx dlx` or AI agents**: If launched via package runners, vde-notifier reuses the current `process.execPath` so focus mode can start without PATH access.

## Development Notes (Optional)

- Install dependencies: `pnpm install`
- Lint: `pnpm run lint`
- Test: `pnpm run test`
- Package dry-run check: `pnpm run pack:check`
- Build: `pnpm run build`
- Watch build: `pnpm run dev`
- Swift backend tests: `pnpm run swift:test`
- Swift backend build: `pnpm run swift:build`
- Build app bundle: `pnpm run swift:app`
