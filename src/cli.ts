#!/usr/bin/env node
import { fileURLToPath } from "node:url";
import { basename, dirname, join, relative, resolve } from "node:path";
import { argv, env as processEnv, exit, stdin as processStdin } from "node:process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, realpathSync } from "node:fs";
import { z } from "zod";
import { bold, red } from "kleur/colors";
import type {
  CliOptions,
  EnvironmentReport,
  FocusPayload,
  NotifierKind,
  NotificationContent,
  TerminalProfile,
  TmuxContext
} from "./types.js";
import { assertRuntimeSupport, logBinaryReport, verifyRequiredBinaries } from "./utils/runtime.js";
import { resolveTmuxContext } from "./tmux/query.js";
import { resolveTerminalProfile, activateTerminal } from "./terminal/profile.js";
import { sendNotification } from "./notify/send.js";
import { buildFocusCommand, parseFocusPayload } from "./utils/payload.js";
import { focusPane } from "./tmux/control.js";

const MODES = ["notify", "focus"] as const;

type CodexContext = {
  readonly title?: string;
  readonly message?: string;
  readonly sound?: string;
};

const resolveRepositoryDisplayName = (): string => {
  try {
    const cwd = process.cwd();
    const name = basename(cwd);
    if (typeof name === "string" && name.length > 0 && name !== "." && name !== "/") {
      return name;
    }
  } catch {
    /* ignore resolution failures */
  }
  return "Repository";
};

const defaultAgentTitle = (agent: "codex" | "claude"): string => {
  const repo = resolveRepositoryDisplayName();
  return agent === "codex" ? `Codex: ${repo}` : `Claude: ${repo}`;
};

const asNonEmptyString = (value: unknown): string | undefined => {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
};

const readStdin = async (): Promise<string> => {
  if (processStdin.isTTY) {
    return "";
  }

  const chunks: string[] = [];
  for await (const chunk of processStdin) {
    chunks.push(typeof chunk === "string" ? chunk : chunk.toString("utf8"));
  }

  return chunks.join("").trim();
};

const extractCodexMessage = (payload: Record<string, unknown>): string | undefined => {
  const direct = asNonEmptyString(payload["last-assistant-message"]);
  if (typeof direct === "string") {
    return direct;
  }

  const messageField = asNonEmptyString(payload.message);
  if (typeof messageField === "string") {
    return messageField;
  }

  const messages = payload.messages;
  if (Array.isArray(messages)) {
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const entry = messages[index];
      if (entry === null || typeof entry !== "object") {
        continue;
      }

      const roleValue = (entry as { role?: unknown }).role;
      const role = typeof roleValue === "string" ? roleValue.trim() : "";
      if (role !== "assistant") {
        continue;
      }

      const contentValue = (entry as { content?: unknown }).content;
      if (typeof contentValue === "string") {
        const text = asNonEmptyString(contentValue);
        if (typeof text === "string") {
          return text;
        }
      }

      if (Array.isArray(contentValue)) {
        for (const part of contentValue) {
          if (part === null || typeof part !== "object") {
            continue;
          }
          const text = asNonEmptyString((part as { text?: string }).text);
          if (typeof text === "string") {
            return text;
          }
        }
      }
    }
  }

  const transcript = payload.transcript;
  if (transcript !== null && typeof transcript === "object") {
    const messageObject = (transcript as { message?: unknown }).message;
    if (messageObject !== null && typeof messageObject === "object") {
      const contentArray = (messageObject as { content?: unknown }).content;
      if (Array.isArray(contentArray) && contentArray.length > 0) {
        const lastPart = contentArray[contentArray.length - 1];
        if (lastPart !== null && typeof lastPart === "object") {
          const text = asNonEmptyString((lastPart as { text?: string }).text);
          if (typeof text === "string") {
            return text;
          }
        }
      }
    }
  }

  return undefined;
};

const CODEX_DEFAULT_TITLE = defaultAgentTitle("codex");

const extractCodexTitle = (payload: Record<string, unknown>): string | undefined => {
  const explicit = asNonEmptyString(payload["notification-title"]);
  if (typeof explicit === "string") {
    return explicit;
  }
  const fallback = asNonEmptyString(payload.title);
  if (typeof fallback === "string") {
    return fallback;
  }
  return CODEX_DEFAULT_TITLE;
};

const extractSoundNameFromPath = (soundPath: string): string | undefined => {
  const segments = soundPath.split("/");
  const last = segments[segments.length - 1];
  if (!last) {
    return undefined;
  }
  const base = last.replace(/\.[^/.]+$/, "");
  return base.length > 0 ? base : undefined;
};

const resolveCodexSound = (payload: Record<string, unknown>): string | undefined => {
  const envValue = asNonEmptyString(processEnv.CODEX_NOTIFICATION_SOUND);
  const raw = Object.prototype.hasOwnProperty.call(payload, "sound") ? (payload.sound as unknown) : envValue;

  if (raw === undefined || raw === null) {
    return undefined;
  }

  if (typeof raw === "boolean") {
    return raw ? "Glass" : "None";
  }

  if (typeof raw === "number") {
    return raw === 0 ? "None" : undefined;
  }

  const stringValue = asNonEmptyString(raw);
  if (typeof stringValue !== "string") {
    return undefined;
  }

  const lower = stringValue.toLowerCase();
  if (lower === "none") {
    return "None";
  }
  if (lower === "true") {
    return "Glass";
  }
  if (lower === "false") {
    return "None";
  }
  if (lower === "default" || lower === "glass") {
    return "Glass";
  }

  if (stringValue.includes("/")) {
    return extractSoundNameFromPath(stringValue) ?? "Glass";
  }

  return stringValue;
};

const optionsWithValue = new Set<string>([
  "--title",
  "--message",
  "--terminal",
  "--term-bundle-id",
  "--sound",
  "--payload",
  "--notifier",
  "--log-file"
]);

const flagOnlyOptions = new Set<string>(["--codex", "--claude", "--dry-run", "--verbose"]);

const extractCodexArg = (args: readonly string[]): string | undefined => {
  const candidates: string[] = [];

  for (let index = 0; index < args.length; index += 1) {
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
  }

  return candidates.find((candidate) => candidate.trim().length > 0);
};

const loadCodexContext = async (
  rawArgs: readonly string[],
  stdinOverride?: string
): Promise<CodexContext | undefined> => {
  const rawInput = typeof stdinOverride === "string" ? stdinOverride : await readStdin();
  const envPayload = asNonEmptyString(processEnv.CODEX_NOTIFICATION_PAYLOAD);
  const argPayload = extractCodexArg(rawArgs);
  const fallback = rawInput.length > 0 ? rawInput : (argPayload ?? envPayload ?? "");

  if (fallback.length === 0) {
    return undefined;
  }

  try {
    const parsed = JSON.parse(fallback);
    if (parsed === null || typeof parsed !== "object") {
      return undefined;
    }
    const record = parsed as Record<string, unknown>;
    return {
      message: extractCodexMessage(record),
      title: defaultAgentTitle("codex"),
      sound: resolveCodexSound(record)
    };
  } catch (error) {
    console.error("Failed to parse Codex payload");
    return undefined;
  }
};

const CLAUDE_DEFAULT_TITLE = defaultAgentTitle("claude");

const isPathWithinBase = (target: string, base: string): boolean => {
  const relativePath = relative(base, target);
  if (relativePath === "") {
    return true;
  }
  if (relativePath.startsWith("..")) {
    return false;
  }
  if (relativePath.includes("../") || relativePath.includes("..\\")) {
    return false;
  }
  return true;
};

const resolveClaudeTranscriptPath = (rawPath: unknown): string | undefined => {
  const home = asNonEmptyString(processEnv.HOME);
  const inputPath = asNonEmptyString(rawPath);
  if (typeof inputPath !== "string" || inputPath.length === 0) {
    return undefined;
  }

  const expanded = inputPath.startsWith("~/") && typeof home === "string" ? join(home, inputPath.slice(2)) : inputPath;
  const absolute = resolve(expanded);

  const allowedBases =
    typeof home === "string"
      ? [resolve(home, ".claude", "projects"), resolve(home, ".config", "claude", "projects")]
      : [];

  if (allowedBases.length > 0 && !allowedBases.some((base) => isPathWithinBase(absolute, base))) {
    return undefined;
  }

  if (!existsSync(absolute)) {
    return undefined;
  }

  return absolute;
};

const extractTextFromClaudeMessage = (message: Record<string, unknown>): string | undefined => {
  const direct = asNonEmptyString((message as { text?: string }).text);
  if (typeof direct === "string") {
    return direct;
  }

  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") {
    const textValue = asNonEmptyString(content);
    if (typeof textValue === "string") {
      return textValue;
    }
  }

  if (Array.isArray(content)) {
    for (const part of content) {
      if (typeof part === "string") {
        const textValue = asNonEmptyString(part);
        if (typeof textValue === "string") {
          return textValue;
        }
        continue;
      }
      if (part !== null && typeof part === "object") {
        const textValue = asNonEmptyString((part as { text?: string }).text);
        if (typeof textValue === "string") {
          return textValue;
        }
      }
    }
  }

  return undefined;
};

const readClaudeTranscript = (transcriptPath: string): string | undefined => {
  try {
    const content = readFileSync(transcriptPath, { encoding: "utf8" });
    const lines = content.split(/\r?\n/);
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      const line = lines[index]?.trim();
      if (!line) {
        continue;
      }
      try {
        const parsedLine = JSON.parse(line) as { message?: unknown };
        const message = parsedLine.message;
        if (message === null || typeof message !== "object") {
          continue;
        }
        const role = asNonEmptyString((message as { role?: string }).role);
        if (typeof role === "string" && role !== "assistant") {
          continue;
        }
        const text = extractTextFromClaudeMessage(message as Record<string, unknown>);
        if (typeof text === "string" && text.length > 0) {
          return text;
        }
      } catch {
        // skip malformed transcript line
      }
    }
  } catch {
    return undefined;
  }

  return undefined;
};

const extractClaudeTitle = (payload: Record<string, unknown>): string | undefined => {
  const explicit =
    asNonEmptyString((payload as { notification_title?: unknown }).notification_title) ??
    asNonEmptyString(payload["notification-title"]);
  if (typeof explicit === "string") {
    return explicit;
  }
  const fallback = asNonEmptyString(payload.title);
  if (typeof fallback === "string") {
    return fallback;
  }
  return CLAUDE_DEFAULT_TITLE;
};

const extractClaudeMessage = (payload: Record<string, unknown>): string | undefined => {
  const explicit =
    asNonEmptyString((payload as { notification_message?: unknown }).notification_message) ??
    asNonEmptyString(payload["notification-message"]);
  if (typeof explicit === "string") {
    return explicit;
  }
  return extractCodexMessage(payload);
};

const loadClaudeContext = async (stdinOverride?: string): Promise<CodexContext | undefined> => {
  const rawInput = typeof stdinOverride === "string" ? stdinOverride : await readStdin();
  const source = rawInput.trim();
  if (source.length === 0) {
    return undefined;
  }

  try {
    const parsed = JSON.parse(source);
    if (parsed === null || typeof parsed !== "object") {
      return undefined;
    }
    const record = parsed as Record<string, unknown>;
    const messageFromPayload = extractClaudeMessage(record);
    const transcriptPath = resolveClaudeTranscriptPath(
      (record as { transcript_path?: unknown }).transcript_path ?? record.transcriptPath
    );
    const transcriptMessage = typeof transcriptPath === "string" ? readClaudeTranscript(transcriptPath) : undefined;

    return {
      title: extractClaudeTitle(record),
      message: messageFromPayload ?? transcriptMessage,
      sound: resolveCodexSound(record)
    };
  } catch (error) {
    console.error("Failed to parse Claude payload");
    return undefined;
  }
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

const notifierSchema = z.unknown().transform<NotifierKind>((value) => {
  if (value === undefined || value === null) {
    return "vde-notifier-app";
  }
  if (typeof value !== "string") {
    throw new Error("Notifier must be a string");
  }

  const normalized = value.toLowerCase();
  if (normalized === "terminal-notifier") {
    return "terminal-notifier";
  }
  if (normalized === "swiftdialog" || normalized === "dialog") {
    return "swiftdialog";
  }
  if (normalized === "vde-notifier-app" || normalized === "vde-notifier") {
    return "vde-notifier-app";
  }

  throw new Error(`Unsupported notifier: ${value}`);
});

const cliSchema = z.object({
  mode: z.enum(MODES).default("notify"),
  title: z.string().optional(),
  message: z.string().optional(),
  terminal: z.string().optional(),
  termBundleId: z.string().optional(),
  sound: z
    .string()
    .optional()
    .transform((value) => (typeof value === "string" && value.length > 0 ? value : undefined)),
  notifier: notifierSchema,
  codex: z.boolean().default(false),
  claude: z.boolean().default(false),
  dryRun: z.boolean().default(false),
  verbose: z.boolean().default(false),
  logFile: z
    .string()
    .optional()
    .transform((value) => (typeof value === "string" && value.trim().length > 0 ? value : undefined)),
  payload: z.string().optional()
});

const parseArguments = (args: readonly string[]): CliOptions => {
  const collected: Record<string, string | boolean | undefined> = {};

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!arg.startsWith("--")) {
      continue;
    }

    const raw = arg.slice(2);
    if (raw.startsWith("no-")) {
      const key = raw.slice(3);
      collected[key] = false;
      continue;
    }

    const [key, inlineValue] = raw.split("=", 2);
    const flagLabel = `--${key}`;
    if (inlineValue !== undefined) {
      collected[key] = inlineValue;
      continue;
    }

    if (flagOnlyOptions.has(flagLabel)) {
      collected[key] = true;
      continue;
    }

    if (optionsWithValue.has(flagLabel)) {
      const next = args[index + 1];
      if (typeof next === "string" && !next.startsWith("--")) {
        collected[key] = next;
        index += 1;
      }
      continue;
    }

    const next = args[index + 1];
    if (typeof next === "string" && !next.startsWith("--")) {
      collected[key] = next;
      index += 1;
    } else {
      collected[key] = true;
    }
  }

  const optionLogFile = asNonEmptyString(collected["log-file"]);
  const envLogFile = asNonEmptyString(processEnv.VDE_NOTIFIER_LOG_FILE);
  const resolvedLogFile = optionLogFile ?? envLogFile;

  const parsed = cliSchema.safeParse({
    mode: collected.mode,
    title: collected.title,
    message: collected.message,
    terminal: collected.terminal,
    termBundleId: collected["term-bundle-id"],
    sound: collected.sound,
    notifier: collected.notifier,
    codex: collected.codex === true,
    claude: collected.claude === true,
    dryRun: collected["dry-run"],
    verbose: collected.verbose,
    logFile: resolvedLogFile,
    payload: collected.payload
  });

  if (!parsed.success) {
    const issues = parsed.error.issues.map((issue) => issue.message).join("\n");
    throw new Error(`Failed to parse CLI options:\n${issues}`);
  }

  return parsed.data;
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

const runNotify = async (
  options: CliOptions,
  report: EnvironmentReport,
  rawArgs: readonly string[] = [],
  stdinOverride?: string
): Promise<number> => {
  const tmux = await resolveTmuxContext(report.binaries.tmux);
  const envOverride =
    typeof processEnv.VDE_NOTIFIER_TERMINAL === "string" ? processEnv.VDE_NOTIFIER_TERMINAL : undefined;
  const terminal = resolveTerminalProfile({
    explicitKey: options.terminal ?? envOverride,
    bundleOverride: options.termBundleId,
    env: processEnv
  });
  const agentContext = options.claude
    ? await loadClaudeContext(stdinOverride)
    : options.codex
      ? await loadCodexContext(rawArgs, stdinOverride)
      : undefined;
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

  await sendNotification({
    notifierKind: report.binaries.notifierKind,
    notifierPath: report.binaries.notifier,
    title: notification.title,
    message: notification.message,
    focusCommand,
    sound: soundName
  });

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
    const options = parseArguments(rawArgs);
    assertRuntimeSupport();
    if (options.mode === "notify") {
      const report = await verifyRequiredBinaries(options.notifier);
      logBinaryReport(report, options.verbose);
      return await runNotify(options, report, rawArgs);
    }
    return await runFocus(options);
  } catch (error) {
    printError(error);
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
  parseArguments,
  runNotify,
  runFocus,
  resolveNotificationDetails,
  loadCodexContext,
  loadClaudeContext,
  extractCodexMessage,
  extractCodexTitle,
  resolveCodexSound
};
