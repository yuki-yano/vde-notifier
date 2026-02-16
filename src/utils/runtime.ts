import { yellow } from "kleur/colors";
import type { EnvironmentReport, NotifierKind, RuntimeInfo } from "../types";
import { ensureBinary } from "./binary";

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

const DEFAULT_NOTIFIER: NotifierKind = "vde-notifier-app";

const defaultNotifierInstallGuide = (): string => {
  return [
    "Default notifier `vde-notifier-app` is not installed.",
    "Install it with:",
    "  brew tap yuki-yano/vde-notifier",
    "  brew install --cask yuki-yano/vde-notifier/vde-notifier-app",
    "",
    "Or override notifier explicitly, for example:",
    "  --notifier terminal-notifier"
  ].join("\n");
};

export const verifyRequiredBinaries = async (notifier: NotifierKind = DEFAULT_NOTIFIER): Promise<EnvironmentReport> => {
  const notifierCommandByKind: Record<NotifierKind, string> = {
    "terminal-notifier": "terminal-notifier",
    swiftdialog: "dialog",
    "vde-notifier-app": "vde-notifier-app"
  };
  const notifierCommand = notifierCommandByKind[notifier];

  const tmuxPath = await ensureBinary("tmux");
  let notifierPath: string;
  try {
    notifierPath = await ensureBinary(notifierCommand);
  } catch (error) {
    if (notifier === DEFAULT_NOTIFIER) {
      throw new Error(defaultNotifierInstallGuide());
    }
    throw error;
  }
  const osascriptPath = await ensureBinary("osascript");

  const report: EnvironmentReport = {
    runtime: detectRuntime(),
    binaries: {
      tmux: tmuxPath,
      notifier: notifierPath,
      notifierKind: notifier,
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
