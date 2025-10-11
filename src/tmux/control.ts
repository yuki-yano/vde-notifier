import { execa } from "execa";
import type { TmuxContext } from "../types.js";
const tmuxArgs = (context: TmuxContext) => ["-S", context.socketPath];

export const focusPane = async (context: TmuxContext): Promise<void> => {
  const baseArgs = tmuxArgs(context);
  const switchArgs = [
    ...baseArgs,
    "switch-client",
    ...(context.clientTTY.length > 0 ? ["-c", context.clientTTY] : []),
    "-t",
    context.sessionName
  ];

  await execa(context.tmuxBin, switchArgs);
  await execa(context.tmuxBin, [...baseArgs, "select-window", "-t", context.windowId]);
  await execa(context.tmuxBin, [...baseArgs, "select-pane", "-t", context.paneId]);
};
