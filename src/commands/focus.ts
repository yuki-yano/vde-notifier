import type { CliOptions } from "../types";
import { activateTerminal } from "../terminal/profile";
import { focusPane } from "../tmux/control";
import { parseFocusPayload } from "../utils/payload";
import { logVerbose } from "../diagnostics/logging";

export const runFocus = async (options: CliOptions): Promise<number> => {
  const payload = parseFocusPayload(options.payload);

  logVerbose(options.verbose, options.logFile, {
    stage: "focus",
    payload
  });

  await focusPane(payload.tmux);
  await activateTerminal(payload.terminal.bundleId);

  return 0;
};
