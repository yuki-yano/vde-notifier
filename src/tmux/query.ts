import { execa } from "execa";
import type { TmuxContext } from "../types";

const FORMAT_SEQUENCE = [
  "#{socket_path}",
  "#{client_tty}",
  "#{session_name}",
  "#{window_id}",
  "#{window_index}",
  "#{pane_id}",
  "#{pane_index}",
  "#{pane_current_command}"
] as const;

const TMUX_FORMAT = FORMAT_SEQUENCE.join("\n");

const parseNumber = (value: string, label: string): number => {
  const trimmedValue = value.trim();
  if (!/^\d+$/.test(trimmedValue)) {
    throw new Error(`Failed to parse ${label} as number: ${value}`);
  }
  const parsed = Number.parseInt(trimmedValue, 10);
  return parsed;
};

export const resolveTmuxContext = async (tmuxPath: string): Promise<TmuxContext> => {
  const targetPane = process.env.TMUX_PANE;
  let args: string[];
  if (typeof targetPane === "string") {
    const trimmedTarget = targetPane.trim();
    if (trimmedTarget.length > 0) {
      args = ["display-message", "-p", "-t", trimmedTarget, TMUX_FORMAT];
    } else {
      args = ["display-message", "-p", TMUX_FORMAT];
    }
  } else {
    args = ["display-message", "-p", TMUX_FORMAT];
  }
  const { stdout } = await execa(tmuxPath, args);
  const lines = stdout.replace(/\r\n/g, "\n").split("\n");
  while (lines.length > FORMAT_SEQUENCE.length && lines.at(-1) === "") {
    lines.pop();
  }
  if (lines.length !== FORMAT_SEQUENCE.length) {
    throw new Error("Unexpected tmux response while collecting pane metadata");
  }

  const [socketPath, clientTTY, sessionName, windowId, windowIndex, paneId, paneIndex, paneCurrentCommand] = lines;

  return {
    tmuxBin: tmuxPath,
    socketPath,
    clientTTY,
    sessionName,
    windowId,
    windowIndex: parseNumber(windowIndex, "window index"),
    paneId,
    paneIndex: parseNumber(paneIndex, "pane index"),
    paneCurrentCommand
  };
};
