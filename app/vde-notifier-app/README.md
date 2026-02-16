# vde-notifier-app

`vde-notifier-app` is a Swift-based notification backend for `vde-notifier`.

It provides:

- Local macOS notifications
- Notification click action (`Return to pane`)
- Action execution using an absolute executable path and argument array

## Development

```bash
swift test --package-path app/vde-notifier-app
swift build --package-path app/vde-notifier-app --product vde-notifier-app
```

## Build `.app`

```bash
app/vde-notifier-app/scripts/build-app.sh
```

This creates:

- `build/VdeNotifierApp.app`
- An ad-hoc signed app bundle (`Identifier=com.yuki-yano.vde-notifier-app.agent`)

If `doctor` stays `notDetermined` and the app does not appear in Notification settings, verify the signature identifier:

```bash
codesign -dv --verbose=4 build/VdeNotifierApp.app 2>&1 | rg '^Identifier='
```

## CLI

```bash
vde-notifier-app notify \
  --title "Build finished" \
  --message "Done" \
  --sound Ping \
  --action-exec /opt/homebrew/bin/node \
  --action-arg /opt/homebrew/bin/vde-notifier \
  --action-arg --mode \
  --action-arg focus
```

Agent commands:

```bash
vde-notifier-app agent run
vde-notifier-app agent start
vde-notifier-app agent status
vde-notifier-app doctor
vde-notifier-app --version
```
