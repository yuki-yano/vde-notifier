import { execa } from "execa";
import type { TmuxContext } from "../types.js";

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
  const parsed = Number.parseInt(value, 10);
  if (Number.isNaN(parsed)) {
    throw new Error(`Failed to parse ${label} as number: ${value}`);
  }
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
  const lines = stdout.trim().split("\n");
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
