import { yellow } from "kleur/colors";
import type { EnvironmentReport, RuntimeInfo } from "../types.js";
import { ensureBinary } from "./binary.js";

const detectRuntime = (): RuntimeInfo => ({
  nodeVersion: globalThis.process?.versions?.node,
  bunVersion: (globalThis as unknown as { Bun?: { version: string } }).Bun?.version
});

export const assertRuntimeSupport = (): void => {
  const runtime = detectRuntime();
  const hasNode = typeof runtime.nodeVersion === "string" && runtime.nodeVersion.length > 0;
  const hasBun = typeof runtime.bunVersion === "string" && runtime.bunVersion.length > 0;
  if (!hasNode && !hasBun) {
    throw new Error("Unsupported runtime. Please run under Node.js or Bun.");
  }
};

export const verifyRequiredBinaries = async (): Promise<EnvironmentReport> => {
  const [tmuxPath, notifierPath, osascriptPath] = await Promise.all([
    ensureBinary("tmux"),
    ensureBinary("terminal-notifier"),
    ensureBinary("osascript")
  ]);

  const report: EnvironmentReport = {
    runtime: detectRuntime(),
    binaries: {
      tmux: tmuxPath,
      terminalNotifier: notifierPath,
      osascript: osascriptPath
    }
  };

  return report;
};

export const logBinaryReport = (report: EnvironmentReport, verbose: boolean): void => {
  if (verbose !== true) {
    return;
  }
  console.error(yellow(JSON.stringify(report, null, 2)));
};
