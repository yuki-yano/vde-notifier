import { readFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { argv, env as processEnv } from "node:process";
import { fileURLToPath } from "node:url";
import { parseArgs, type ArgsDef } from "citty";
import { z } from "zod";
import type { CliOptions, NotifierKind } from "../types";
import { asNonEmptyString } from "../agents/context";

const MODES = ["notify", "focus"] as const;

export const optionsWithValue = new Set<string>([
  "--mode",
  "--title",
  "--message",
  "--terminal",
  "--term-bundle-id",
  "--sound",
  "--payload",
  "--notifier",
  "--log-file"
]);

export const flagOnlyOptions = new Set<string>([
  "--codex",
  "--skip-codex-subagent",
  "--skip-codex-non-interactive",
  "--claude",
  "--skip-claude-non-interactive",
  "--dry-run",
  "--verbose"
]);

export const formatUsage = (programName = "vde-notifier"): string =>
  [
    `Usage: ${programName} [options]`,
    "",
    "Options:",
    "  --mode <notify|focus>                  Mode to run (default: notify)",
    "  --title <string>                       Notification title",
    "  --message <string>                     Notification message",
    "  --terminal <profile>                   Terminal profile (e.g. wezterm, alacritty)",
    "  --term-bundle-id <bundle-id>           Explicit terminal bundle identifier",
    "  --sound <name|None>                    Notification sound",
    "  --notifier <vde-notifier-app|swiftdialog|terminal-notifier>",
    "                                         Notification backend",
    "  --codex                                Parse Codex payload",
    "  --skip-codex-subagent                  Skip notification for Codex subagent turns",
    "  --skip-codex-non-interactive           Skip notifications for Codex non-interactive turns",
    "  --claude                               Parse Claude payload",
    "  --skip-claude-non-interactive          Skip notifications for Claude non-interactive payloads",
    "  --dry-run                              Print payload without sending notification",
    "  --verbose                              Print diagnostic JSON logs",
    "  --log-file <path>                      Append diagnostic logs to file",
    "  --payload <base64>                     Focus payload for --mode focus",
    "  -- <command> [args...]                 Run command after notification with forwarded args",
    "  --help, -h                             Show help",
    "  --version, -v                          Show version"
  ].join("\n");

export const resolveCliVersion = (): string => {
  const envVersion = asNonEmptyString(processEnv.npm_package_version);
  if (typeof envVersion === "string") {
    return envVersion;
  }

  try {
    const modulePath = fileURLToPath(import.meta.url);
    const packageJsonPath = resolve(dirname(modulePath), "..", "..", "package.json");
    const packageJson = JSON.parse(readFileSync(packageJsonPath, { encoding: "utf8" })) as { version?: unknown };
    const version = asNonEmptyString(packageJson.version);
    if (typeof version === "string") {
      return version;
    }
  } catch {
    // fall through
  }

  return "0.0.0";
};

export const resolveProgramName = (): string => {
  const entry = asNonEmptyString(argv[1]);
  if (typeof entry === "string") {
    const name = basename(entry);
    if (name === "cli.js" || name === "index.js") {
      return "vde-notifier";
    }
    if (name.length > 0) {
      return name;
    }
  }
  return "vde-notifier";
};

const failCliOptionParse = (message: string): never => {
  throw new Error(`Failed to parse CLI options:\n${message}`);
};

const controlLongOptions = new Set<string>(["--help", "--version"]);
const knownLongOptions = new Set<string>([...optionsWithValue, ...flagOnlyOptions, "--help", "--version"]);
const knownShortOptions = new Set<string>(["-h", "-v"]);

type ControlOptions = {
  readonly help: boolean;
  readonly version: boolean;
};

type ParsedRawArgs = {
  readonly normalizedArgs: readonly string[];
  readonly controls: ControlOptions;
};

const parseRawArgs = (rawArgs: readonly string[]): ParsedRawArgs => {
  const normalizedArgs: string[] = [];
  let help = false;
  let version = false;

  for (let index = 0; index < rawArgs.length; index += 1) {
    const arg = rawArgs[index];

    if (arg === "--") {
      normalizedArgs.push(arg, ...rawArgs.slice(index + 1));
      break;
    }

    if (!arg.startsWith("-")) {
      normalizedArgs.push(arg);
      continue;
    }

    if (arg.startsWith("--")) {
      const raw = arg.slice(2);
      if (raw.length === 0) {
        failCliOptionParse("Unknown option: --");
      }

      if (raw.startsWith("no-")) {
        const key = raw.slice(3);
        const flagLabel = `--${key}`;
        if (!flagOnlyOptions.has(flagLabel)) {
          failCliOptionParse(`Unknown boolean option: --no-${key}`);
        }
        normalizedArgs.push(arg);
        continue;
      }

      const [key, inlineValue] = raw.split("=", 2);
      const flagLabel = `--${key}`;

      if (!knownLongOptions.has(flagLabel)) {
        failCliOptionParse(`Unknown option: ${flagLabel}`);
      }
      if ((flagOnlyOptions.has(flagLabel) || controlLongOptions.has(flagLabel)) && inlineValue !== undefined) {
        failCliOptionParse(`Option ${flagLabel} does not take a value.`);
      }
      if (optionsWithValue.has(flagLabel)) {
        if (inlineValue !== undefined) {
          normalizedArgs.push(arg);
          continue;
        }
        const next = rawArgs[index + 1];
        const nextLongOption = typeof next === "string" ? `--${next.slice(2).split("=", 1)[0]}` : undefined;
        if (
          typeof next !== "string" ||
          next === "--" ||
          (next.startsWith("--") && nextLongOption !== undefined && knownLongOptions.has(nextLongOption))
        ) {
          failCliOptionParse(`Option ${flagLabel} requires a value.`);
        }
        normalizedArgs.push(`${flagLabel}=${next}`);
        index += 1;
        continue;
      }

      if (flagLabel === "--help") {
        help = true;
      }
      if (flagLabel === "--version") {
        version = true;
      }
      normalizedArgs.push(flagLabel);

      continue;
    }

    if (!knownShortOptions.has(arg)) {
      failCliOptionParse(`Unknown short option: ${arg}`);
    }
    if (arg === "-h") {
      help = true;
    }
    if (arg === "-v") {
      version = true;
    }
    normalizedArgs.push(arg);
  }

  return {
    normalizedArgs,
    controls: {
      help,
      version
    }
  };
};

export const resolveControlOptions = (args: readonly string[]): ControlOptions => {
  return parseRawArgs(args).controls;
};

const cliArgsDef = {
  mode: {
    type: "string",
    default: "notify"
  },
  title: {
    type: "string"
  },
  message: {
    type: "string"
  },
  terminal: {
    type: "string"
  },
  "term-bundle-id": {
    type: "string"
  },
  sound: {
    type: "string"
  },
  notifier: {
    type: "string",
    default: "vde-notifier-app"
  },
  codex: {
    type: "boolean",
    default: false
  },
  "skip-codex-subagent": {
    type: "boolean",
    default: false
  },
  "skip-codex-non-interactive": {
    type: "boolean",
    default: false
  },
  claude: {
    type: "boolean",
    default: false
  },
  "skip-claude-non-interactive": {
    type: "boolean",
    default: false
  },
  "dry-run": {
    type: "boolean",
    default: false
  },
  verbose: {
    type: "boolean",
    default: false
  },
  "log-file": {
    type: "string"
  },
  payload: {
    type: "string"
  },
  help: {
    type: "boolean",
    alias: "h",
    default: false
  },
  version: {
    type: "boolean",
    alias: "v",
    default: false
  }
} satisfies ArgsDef;

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
  skipCodexSubagent: z.boolean().default(false),
  skipCodexNonInteractive: z.boolean().default(false),
  claude: z.boolean().default(false),
  skipClaudeNonInteractive: z.boolean().default(false),
  dryRun: z.boolean().default(false),
  verbose: z.boolean().default(false),
  logFile: z
    .string()
    .optional()
    .transform((value) => (typeof value === "string" && value.trim().length > 0 ? value : undefined)),
  payload: z.string().optional()
});

export const parseArguments = (args: readonly string[]): CliOptions => {
  const parsedRawArgs = parseRawArgs(args);
  const parsedArgs = parseArgs([...parsedRawArgs.normalizedArgs], cliArgsDef);

  const optionLogFile = asNonEmptyString(parsedArgs["log-file"]);
  const envLogFile = asNonEmptyString(processEnv.VDE_NOTIFIER_LOG_FILE);
  const resolvedLogFile = optionLogFile ?? envLogFile;

  const parsed = cliSchema.safeParse({
    mode: parsedArgs.mode,
    title: parsedArgs.title,
    message: parsedArgs.message,
    terminal: parsedArgs.terminal,
    termBundleId: parsedArgs["term-bundle-id"],
    sound: parsedArgs.sound,
    notifier: parsedArgs.notifier,
    codex: parsedArgs.codex === true,
    skipCodexSubagent: parsedArgs["skip-codex-subagent"] === true,
    skipCodexNonInteractive: parsedArgs["skip-codex-non-interactive"] === true,
    claude: parsedArgs.claude === true,
    skipClaudeNonInteractive: parsedArgs["skip-claude-non-interactive"] === true,
    dryRun: parsedArgs["dry-run"] === true,
    verbose: parsedArgs.verbose === true,
    logFile: resolvedLogFile,
    payload: parsedArgs.payload
  });

  if (!parsed.success) {
    const issues = parsed.error.issues.map((issue) => issue.message).join("\n");
    failCliOptionParse(issues);
  }

  const parsedOptions = parsed.data as CliOptions;

  if (parsedOptions.codex && parsedOptions.claude) {
    throw new Error("Options --codex and --claude cannot be used together.");
  }

  return parsedOptions;
};
