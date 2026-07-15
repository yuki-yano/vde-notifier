#!/usr/bin/env node
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import { argv, env as processEnv, exit } from "node:process";
import { appendFileSync, mkdirSync, realpathSync } from "node:fs";
import { bold, red } from "kleur/colors";
import { execa } from "execa";
import type {
  CliOptions,
  EnvironmentReport,
  FocusPayload,
  NotificationContent,
  TerminalProfile,
  TmuxContext,
  TmuxEnvironmentReport
} from "./types";
import { assertRuntimeSupport, logBinaryReport, verifyRequiredBinaries, verifyTmuxBinary } from "./utils/runtime";
import { resolveTmuxContext } from "./tmux/query";
import { resolveTerminalProfile, activateTerminal } from "./terminal/profile";
import { sendNotification } from "./notify/send";
import { buildFocusCommand, parseFocusPayload } from "./utils/payload";
import { focusPane } from "./tmux/control";
import {
  asNonEmptyString,
  defaultAgentTitle,
  extractCodexMessage,
  readStdin,
  resolveCodexSound,
  type AgentContext as CodexContext
} from "./agents/context";
import { isCodexTitleGenerationPayload, parseCodexContext } from "./agents/codex";
import { detectClaudePrintModeFromProcessChain, loadClaudeContext } from "./agents/claude";
import {
  flagOnlyOptions,
  formatUsage,
  optionsWithValue,
  parseArguments,
  resolveCliVersion,
  resolveControlOptions,
  resolveProgramName
} from "./cli/arguments";

type ForwardCommand = {
  readonly executable: string;
  readonly args: readonly string[];
};

const extractCodexArg = (args: readonly string[]): string | undefined => {
  const separatorIndex = args.indexOf("--");
  const limit = separatorIndex >= 0 ? separatorIndex : args.length;
  const candidates: string[] = [];

  for (let index = 0; index < limit; index += 1) {
    const token = args[index];
    if (!token.startsWith("--")) {
      candidates.push(token);
      continue;
    }

    if (flagOnlyOptions.has(token)) {
      continue;
    }

    if (optionsWithValue.has(token)) {
      if (!token.includes("=") && index + 1 < args.length) {
        index += 1;
      }
      continue;
    }

    const [tokenKey] = token.split("=", 2);
    if (typeof tokenKey === "string" && optionsWithValue.has(tokenKey)) {
      continue;
    }
  }

  for (let index = candidates.length - 1; index >= 0; index -= 1) {
    const candidate = candidates[index];
    if (typeof candidate === "string" && candidate.trim().length > 0) {
      return candidate;
    }
  }

  const forward = resolveForwardCommand(args);
  if (forward === undefined) {
    return undefined;
  }

  for (let index = forward.args.length - 1; index >= 0; index -= 1) {
    const candidate = forward.args[index];
    if (typeof candidate !== "string" || candidate.trim().length === 0) {
      continue;
    }

    try {
      const parsed = JSON.parse(candidate);
      if (parsed !== null && typeof parsed === "object") {
        return candidate;
      }
    } catch {
      continue;
    }
  }

  return undefined;
};

const resolveForwardCommand = (args: readonly string[]): ForwardCommand | undefined => {
  const separatorIndex = args.indexOf("--");
  if (separatorIndex < 0 || separatorIndex >= args.length - 1) {
    return undefined;
  }

  const executable = args[separatorIndex + 1];
  if (typeof executable !== "string" || executable.trim().length === 0) {
    return undefined;
  }

  return {
    executable,
    args: args.slice(separatorIndex + 2)
  };
};

const loadCodexContext = async (
  rawArgs: readonly string[],
  stdinOverride?: string
): Promise<CodexContext | undefined> => {
  const envPayload = asNonEmptyString(processEnv.CODEX_NOTIFICATION_PAYLOAD);
  const argPayload = extractCodexArg(rawArgs);
  let rawPayload = argPayload ?? envPayload;
  if (rawPayload === undefined) {
    const rawInput = typeof stdinOverride === "string" ? stdinOverride : await readStdin();
    rawPayload = rawInput.length > 0 ? rawInput : undefined;
  }

  if (rawPayload === undefined || rawPayload.length === 0) {
    return undefined;
  }

  return parseCodexContext(rawPayload);
};

const resolveForwardArgs = (
  options: CliOptions,
  forward: ForwardCommand | undefined,
  agentContext: CodexContext | undefined
): readonly string[] | undefined => {
  if (forward === undefined) {
    return undefined;
  }

  if (!options.codex || typeof agentContext?.rawPayload !== "string") {
    return forward.args;
  }

  if (forward.args.includes(agentContext.rawPayload)) {
    return forward.args;
  }

  return [...forward.args, agentContext.rawPayload];
};

const resolveNotificationDetails = (
  tmux: TmuxContext,
  options: CliOptions,
  context: CodexContext | undefined
): NotificationContent => {
  const defaultTitle = `[${tmux.sessionName}] ${tmux.windowIndex}.${tmux.paneIndex} (${tmux.paneId})`;
  const defaultMessage = `cmd: ${tmux.paneCurrentCommand} | tty: ${tmux.clientTTY}`;

  const agentDefaultTitle = options.codex
    ? defaultAgentTitle("codex")
    : options.claude
      ? defaultAgentTitle("claude")
      : undefined;

  let title = options.title ?? context?.title ?? agentDefaultTitle ?? defaultTitle;
  let message: string;

  const contextualMessage = context?.message;
  if (typeof options.message === "string" && options.message.length > 0) {
    message = options.message;
  } else if (typeof contextualMessage === "string" && contextualMessage.length > 0) {
    message = contextualMessage;
  } else {
    message = defaultMessage;
  }

  if (title === undefined || title.length === 0) {
    title = defaultTitle;
  }

  const sound = options.sound ?? context?.sound;

  return {
    title,
    message,
    sound
  };
};

const isMainModule = (): boolean => {
  const entry = argv[1];
  if (typeof entry !== "string") {
    return false;
  }
  try {
    const normalizedEntry = realpathSync(entry);
    const modulePath = realpathSync(fileURLToPath(import.meta.url));
    return modulePath === normalizedEntry;
  } catch {
    return false;
  }
};

const printError = (error: unknown): void => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(red(bold(message)));
};

const appendDiagnosticLog = (logFile: string | undefined, detail: unknown): void => {
  if (typeof logFile !== "string" || logFile.trim().length === 0) {
    return;
  }
  try {
    const directory = dirname(logFile);
    if (directory !== "" && directory !== "." && directory !== "/") {
      mkdirSync(directory, { recursive: true });
    }
    const entry = {
      timestamp: new Date().toISOString(),
      detail
    };
    appendFileSync(logFile, `${JSON.stringify(entry)}\n`, { encoding: "utf8" });
  } catch {
    // Avoid impacting runtime behavior if logging fails
  }
};

const performDryRun = (
  tmux: TmuxContext,
  terminal: TerminalProfile,
  notification: NotificationContent,
  payload: FocusPayload,
  command: string,
  sound?: string,
  verbose?: boolean,
  logFile?: string
): void => {
  const summary = {
    tmux,
    terminal,
    notification,
    focus: {
      payload,
      command
    },
    sound
  };
  if (verbose === true) {
    console.log(JSON.stringify(summary, null, 2));
  }
  appendDiagnosticLog(logFile, { stage: "dry-run", data: summary });
};

const logVerbose = (enabled: boolean, logFile: string | undefined, detail: unknown): void => {
  if (enabled) {
    console.error(JSON.stringify(detail, null, 2));
  }
  appendDiagnosticLog(logFile, detail);
};

const isNotificationEnvironmentReport = (report: TmuxEnvironmentReport): report is EnvironmentReport => {
  const binaries = report.binaries as Partial<EnvironmentReport["binaries"]>;
  return (
    typeof binaries.notifier === "string" &&
    (binaries.notifierKind === "terminal-notifier" ||
      binaries.notifierKind === "swiftdialog" ||
      binaries.notifierKind === "vde-notifier-app")
  );
};

const resolveNotifySkipReason = (options: CliOptions, agentContext: CodexContext | undefined): string | undefined => {
  if (options.codex && agentContext?.isTitleGeneration === true) {
    return "codex-title-generation";
  }
  if (options.codex && options.skipCodexSubagent && agentContext?.isSubagent === true) {
    return "codex-subagent";
  }
  if (options.codex && options.skipCodexNonInteractive && agentContext?.isNonInteractive === true) {
    return "codex-non-interactive";
  }
  if (options.claude && options.skipClaudeNonInteractive && agentContext?.isNonInteractive === true) {
    return "claude-non-interactive";
  }
  return undefined;
};

const runForwardCommand = async (
  options: CliOptions,
  rawArgs: readonly string[],
  agentContext: CodexContext | undefined
): Promise<void> => {
  const forward = resolveForwardCommand(rawArgs);
  if (forward === undefined) {
    return;
  }

  const forwardArgs = resolveForwardArgs(options, forward, agentContext);
  logVerbose(options.verbose, options.logFile, {
    stage: "forward",
    executable: forward.executable,
    args: forwardArgs
  });
  await execa(forward.executable, [...(forwardArgs ?? [])], { stdio: "inherit" });
};

const runNotify = async (
  options: CliOptions,
  report?: EnvironmentReport,
  rawArgs: readonly string[] = [],
  stdinOverride?: string
): Promise<number> => {
  const agentContext = options.claude
    ? await loadClaudeContext(stdinOverride)
    : options.codex
      ? await loadCodexContext(rawArgs, stdinOverride)
      : undefined;

  const skipReason = resolveNotifySkipReason(options, agentContext);
  if (skipReason !== undefined) {
    logVerbose(options.verbose, options.logFile, {
      stage: "notify",
      skipped: true,
      reason: skipReason,
      context: agentContext
    });
    await runForwardCommand(options, rawArgs, agentContext);
    return 0;
  }

  const resolvedReport: TmuxEnvironmentReport =
    report ?? (options.dryRun ? await verifyTmuxBinary() : await verifyRequiredBinaries(options.notifier));
  logBinaryReport(resolvedReport, options.verbose);

  const tmux = await resolveTmuxContext(resolvedReport.binaries.tmux);
  const envOverride =
    typeof processEnv.VDE_NOTIFIER_TERMINAL === "string" ? processEnv.VDE_NOTIFIER_TERMINAL : undefined;
  const terminal = resolveTerminalProfile({
    explicitKey: options.terminal ?? envOverride,
    bundleOverride: options.termBundleId,
    env: processEnv
  });
  const notification = resolveNotificationDetails(tmux, options, agentContext);
  const payload: FocusPayload = {
    tmux,
    terminal
  };
  const focusCommand = buildFocusCommand(payload, { verbose: options.verbose, logFile: options.logFile });

  if (options.dryRun) {
    performDryRun(
      tmux,
      terminal,
      notification,
      payload,
      focusCommand.command,
      notification.sound,
      options.verbose,
      options.logFile
    );
    return 0;
  }

  const soundName = notification.sound;

  logVerbose(options.verbose, options.logFile, {
    stage: "notify",
    tmux,
    terminal,
    notification,
    focusCommand,
    sound: soundName,
    context: agentContext
  });

  if (!isNotificationEnvironmentReport(resolvedReport)) {
    throw new Error("Notifier binary verification was not performed.");
  }

  await sendNotification({
    notifierKind: resolvedReport.binaries.notifierKind,
    notifierPath: resolvedReport.binaries.notifier,
    title: notification.title,
    message: notification.message,
    focusCommand,
    sound: soundName
  });

  await runForwardCommand(options, rawArgs, agentContext);

  return 0;
};

const runFocus = async (options: CliOptions): Promise<number> => {
  const payload = parseFocusPayload(options.payload);

  logVerbose(options.verbose, options.logFile, {
    stage: "focus",
    payload
  });

  await focusPane(payload.tmux);
  await activateTerminal(payload.terminal.bundleId);

  return 0;
};

export const main = async (): Promise<number> => {
  try {
    const rawArgs = argv.slice(2);
    const controls = resolveControlOptions(rawArgs);
    if (controls.help) {
      console.log(formatUsage(resolveProgramName()));
      return 0;
    }
    if (controls.version) {
      console.log(resolveCliVersion());
      return 0;
    }

    const options = parseArguments(rawArgs);
    assertRuntimeSupport();
    if (options.mode === "notify") {
      return await runNotify(options, undefined, rawArgs);
    }
    return await runFocus(options);
  } catch (error) {
    printError(error);
    if (error instanceof Error && error.message.startsWith("Failed to parse CLI options:")) {
      console.error("");
      console.error(formatUsage(resolveProgramName()));
    }
    return 1;
  }
};

if (isMainModule()) {
  main()
    .then((code) => exit(code))
    .catch((error) => {
      printError(error);
      exit(1);
    });
}

export const __internal = {
  formatUsage,
  resolveCliVersion,
  resolveControlOptions,
  parseArguments,
  runNotify,
  runFocus,
  resolveNotificationDetails,
  loadCodexContext,
  loadClaudeContext,
  detectClaudePrintModeFromProcessChain,
  extractCodexMessage,
  isCodexTitleGenerationPayload,
  resolveCodexSound
};
