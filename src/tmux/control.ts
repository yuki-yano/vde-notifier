import { execa } from "execa";
import type { TmuxContext } from "../types";

const tmuxArgs = (context: TmuxContext) => ["-S", context.socketPath];

const parseTmuxIdentifiers = (stdout: string): ReadonlySet<string> =>
  new Set(
    stdout
      .split(/\r?\n/u)
      .map((value) => value.trim())
      .filter((value) => value.length > 0)
  );

const assertIdentifierExists = (identifiers: ReadonlySet<string>, identifier: string, label: string): void => {
  if (!identifiers.has(identifier)) {
    throw new Error(`tmux ${label} is no longer available: ${identifier}`);
  }
};

export const validateFocusTargets = async (context: TmuxContext): Promise<void> => {
  const baseArgs = tmuxArgs(context);

  await execa(context.tmuxBin, [...baseArgs, "has-session", "-t", context.sessionId]);

  const windows = await execa(context.tmuxBin, [
    ...baseArgs,
    "list-windows",
    "-t",
    context.sessionId,
    "-F",
    "#{window_id}"
  ]);
  assertIdentifierExists(parseTmuxIdentifiers(windows.stdout), context.windowId, "window");

  const panes = await execa(context.tmuxBin, [...baseArgs, "list-panes", "-t", context.windowId, "-F", "#{pane_id}"]);
  assertIdentifierExists(parseTmuxIdentifiers(panes.stdout), context.paneId, "pane");

  if (context.clientTTY.length === 0) {
    throw new Error("tmux client TTY is unavailable");
  }
  const clients = await execa(context.tmuxBin, [...baseArgs, "list-clients", "-F", "#{client_tty}"]);
  assertIdentifierExists(parseTmuxIdentifiers(clients.stdout), context.clientTTY, "client");
};

export const focusPane = async (context: TmuxContext): Promise<void> => {
  const baseArgs = tmuxArgs(context);
  await validateFocusTargets(context);

  const switchArgs = [...baseArgs, "switch-client", "-c", context.clientTTY, "-t", context.sessionId];

  await execa(context.tmuxBin, switchArgs);
  await execa(context.tmuxBin, [...baseArgs, "select-window", "-t", context.windowId]);
  await execa(context.tmuxBin, [...baseArgs, "select-pane", "-t", context.paneId]);
};
