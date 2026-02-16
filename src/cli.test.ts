import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";
import type { CliOptions, EnvironmentReport, FocusCommand, FocusPayload, TerminalProfile, TmuxContext } from "./types";
import { __internal } from "./cli";

vi.mock("./tmux/query", () => ({
  resolveTmuxContext: vi.fn()
}));

vi.mock("./terminal/profile", () => ({
  resolveTerminalProfile: vi.fn(),
  activateTerminal: vi.fn()
}));

vi.mock("./notify/send", () => ({
  sendNotification: vi.fn()
}));

vi.mock("./utils/payload", () => ({
  buildFocusCommand: vi.fn(),
  parseFocusPayload: vi.fn()
}));

vi.mock("./tmux/control", () => ({
  focusPane: vi.fn()
}));

const resolveTmuxContextMock = vi.mocked(await import("./tmux/query")).resolveTmuxContext;
const resolveTerminalProfileMock = vi.mocked(await import("./terminal/profile")).resolveTerminalProfile;
const activateTerminalMock = vi.mocked(await import("./terminal/profile")).activateTerminal;
const sendNotificationMock = vi.mocked(await import("./notify/send")).sendNotification;
const buildFocusCommandMock = vi.mocked(await import("./utils/payload")).buildFocusCommand;
const parseFocusPayloadMock = vi.mocked(await import("./utils/payload")).parseFocusPayload;
const focusPaneMock = vi.mocked(await import("./tmux/control")).focusPane;

const sampleTmux: TmuxContext = {
  tmuxBin: "/opt/homebrew/bin/tmux",
  socketPath: "/tmp/tmux-501/default",
  clientTTY: "/dev/ttys012",
  sessionName: "dev",
  windowId: "@1",
  windowIndex: 1,
  paneId: "%5",
  paneIndex: 0,
  paneCurrentCommand: "node"
};

const sampleTerminal: TerminalProfile = {
  key: "wezterm",
  name: "WezTerm",
  bundleId: "com.github.wez.wezterm",
  source: "override"
};

const samplePayload: FocusPayload = {
  tmux: sampleTmux,
  terminal: sampleTerminal
};

const focusCommand: FocusCommand = {
  command: "node dist/index.js --mode focus",
  args: ["dist/index.js", "--mode", "focus"],
  executable: process.execPath,
  payload: "encoded"
};

const environmentReport: EnvironmentReport = {
  runtime: {
    nodeVersion: "22.0.0"
  },
  binaries: {
    tmux: sampleTmux.tmuxBin,
    notifier: "/opt/homebrew/bin/terminal-notifier",
    notifierKind: "terminal-notifier",
    osascript: "/usr/bin/osascript"
  }
};

beforeEach(() => {
  vi.clearAllMocks();
  resolveTmuxContextMock.mockResolvedValue(sampleTmux);
  resolveTerminalProfileMock.mockReturnValue(sampleTerminal);
  buildFocusCommandMock.mockReturnValue(focusCommand);
  parseFocusPayloadMock.mockReturnValue(samplePayload);
  delete process.env.VDE_NOTIFIER_TERMINAL;
  delete process.env.CODEX_NOTIFICATION_PAYLOAD;
  delete process.env.CODEX_NOTIFICATION_SOUND;
});

describe("runNotify", () => {
  it("logs dry-run output when verbose is enabled", async () => {
    const spy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const options: CliOptions = {
      mode: "notify",
      dryRun: true,
      verbose: true,
      codex: false,
      notifier: "terminal-notifier"
    } as CliOptions;

    const result = await __internal.runNotify(options, environmentReport);

    expect(result).toBe(0);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(sendNotificationMock).not.toHaveBeenCalled();
    spy.mockRestore();
  });

  it("skips dry-run logging when verbose is disabled", async () => {
    const spy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const options: CliOptions = {
      mode: "notify",
      dryRun: true,
      verbose: false,
      codex: false,
      notifier: "terminal-notifier"
    } as CliOptions;

    const result = await __internal.runNotify(options, environmentReport);

    expect(result).toBe(0);
    expect(spy).not.toHaveBeenCalled();
    expect(sendNotificationMock).not.toHaveBeenCalled();
    spy.mockRestore();
  });

  it("honors VDE_NOTIFIER_TERMINAL override", async () => {
    process.env.VDE_NOTIFIER_TERMINAL = "ghostty";
    const options: CliOptions = {
      mode: "notify",
      dryRun: true,
      verbose: false,
      codex: false,
      notifier: "terminal-notifier"
    } as CliOptions;

    await __internal.runNotify(options, environmentReport);

    expect(resolveTerminalProfileMock).toHaveBeenCalledWith(expect.objectContaining({ explicitKey: "ghostty" }));
  });

  it("passes sound option to notification sender", async () => {
    const options: CliOptions = {
      mode: "notify",
      sound: "Ping",
      dryRun: false,
      verbose: false,
      codex: false,
      notifier: "terminal-notifier"
    } as CliOptions;

    await __internal.runNotify(options, environmentReport);

    expect(sendNotificationMock).toHaveBeenCalledWith(expect.objectContaining({ sound: "Ping" }));
  });
});

describe("runFocus", () => {
  it("activates terminal and focuses pane", async () => {
    const options: CliOptions = {
      mode: "focus",
      payload: focusCommand.payload,
      dryRun: false,
      verbose: false,
      codex: false,
      notifier: "terminal-notifier"
    } as CliOptions;

    const result = await __internal.runFocus(options);

    expect(result).toBe(0);
    expect(parseFocusPayloadMock).toHaveBeenCalledWith(focusCommand.payload);
    expect(activateTerminalMock).toHaveBeenCalledWith(sampleTerminal.bundleId);
    expect(focusPaneMock).toHaveBeenCalledWith(sampleTmux);
  });
});

describe("resolveNotificationDetails", () => {
  it("merges codex payload into message and sound", () => {
    const codex = {
      title: "Codex",
      message: "Codex task finished",
      sound: "None"
    };

    const options: CliOptions = {
      mode: "notify",
      dryRun: false,
      verbose: false,
      codex: true,
      notifier: "terminal-notifier"
    } as CliOptions;

    const details = __internal.resolveNotificationDetails(sampleTmux, options, codex);

    expect(details.title).toBe("Codex");
    expect(details.message).toBe("Codex task finished");
    expect(details.sound).toBe("None");
  });

  it("prefers explicit CLI overrides", () => {
    const codex = {
      title: "Codex",
      message: "Task complete",
      sound: "Ping"
    };

    const options: CliOptions = {
      mode: "notify",
      message: "Manual message",
      title: "Manual title",
      sound: "Glass",
      dryRun: false,
      verbose: false,
      codex: true,
      notifier: "terminal-notifier"
    } as CliOptions;

    const details = __internal.resolveNotificationDetails(sampleTmux, options, codex);

    expect(details.title).toBe("Manual title");
    expect(details.message).toBe("Manual message");
    expect(details.sound).toBe("Glass");
  });

  it("falls back to repository-scoped Codex title when context is missing", () => {
    const options: CliOptions = {
      mode: "notify",
      dryRun: false,
      verbose: false,
      codex: true,
      claude: false,
      notifier: "terminal-notifier"
    } as CliOptions;

    const details = __internal.resolveNotificationDetails(sampleTmux, options, undefined);

    expect(details.title).toBe(`Codex: ${basename(process.cwd())}`);
  });
});

describe("parseArguments", () => {
  it("treats mode as value option when provided as separate token", () => {
    const options = __internal.parseArguments(["--mode", "focus"]);
    expect(options.mode).toBe("focus");
  });

  it("accepts inline mode assignment", () => {
    const options = __internal.parseArguments(["--mode=focus"]);
    expect(options.mode).toBe("focus");
  });

  it("treats short help flag as value when consumed by --message", () => {
    const options = __internal.parseArguments(["--message", "-h"]);
    expect(options.message).toBe("-h");
  });

  it("enables Claude mode flag", () => {
    const options = __internal.parseArguments(["--claude"]);
    expect(options.claude).toBe(true);
  });

  it("defaults notifier to vde-notifier-app", () => {
    const options = __internal.parseArguments([]);
    expect(options.notifier).toBe("vde-notifier-app");
  });

  it("allows selecting swiftDialog notifier", () => {
    const options = __internal.parseArguments(["--notifier", "swiftdialog"]);
    expect(options.notifier).toBe("swiftdialog");
  });

  it("allows selecting vde-notifier-app notifier", () => {
    const options = __internal.parseArguments(["--notifier", "vde-notifier-app"]);
    expect(options.notifier).toBe("vde-notifier-app");
  });

  it("rejects enabling codex and claude together", () => {
    expect(() => __internal.parseArguments(["--codex", "--claude"])).toThrow(
      "Options --codex and --claude cannot be used together."
    );
  });

  it("rejects unknown options", () => {
    expect(() => __internal.parseArguments(["--unknown"])).toThrow("Failed to parse CLI options:\nUnknown option:");
  });

  it("rejects missing value for value options", () => {
    expect(() => __internal.parseArguments(["--mode"])).toThrow(
      "Failed to parse CLI options:\nOption --mode requires a value."
    );
  });

  it("rejects values for boolean flags", () => {
    expect(() => __internal.parseArguments(["--verbose=true"])).toThrow(
      "Failed to parse CLI options:\nOption --verbose does not take a value."
    );
  });
});

describe("control options", () => {
  it("detects help flags", () => {
    expect(__internal.resolveControlOptions(["--help"]).help).toBe(true);
    expect(__internal.resolveControlOptions(["-h"]).help).toBe(true);
  });

  it("does not treat consumed values as control flags", () => {
    expect(__internal.resolveControlOptions(["--message", "-h"]).help).toBe(false);
    expect(__internal.resolveControlOptions(["--title", "-v"]).version).toBe(false);
  });

  it("detects version flags", () => {
    expect(__internal.resolveControlOptions(["--version"]).version).toBe(true);
    expect(__internal.resolveControlOptions(["-v"]).version).toBe(true);
  });

  it("formats usage output", () => {
    const usage = __internal.formatUsage("vde-notifier");
    expect(usage).toContain("Usage: vde-notifier [options]");
    expect(usage).toContain("--help, -h");
    expect(usage).toContain("--version, -v");
  });

  it("resolves a semantic CLI version", () => {
    const version = __internal.resolveCliVersion();
    expect(version).toMatch(/^\d+\.\d+\.\d+/);
  });
});

describe("resolveCodexSound", () => {
  it("maps file path to system sound name", () => {
    const sound = __internal.resolveCodexSound({ sound: "/System/Library/Sounds/Submarine.aiff" });
    expect(sound).toBe("Submarine");
  });

  it("returns None when disabled", () => {
    expect(__internal.resolveCodexSound({ sound: "none" })).toBe("None");
    expect(__internal.resolveCodexSound({ sound: false })).toBe("None");
  });
});

describe("loadCodexContext", () => {
  it("prefers argument payload over stdin input", async () => {
    const json = JSON.stringify({
      message: "From stdin",
      sound: "None"
    });
    const rawArgs = ["--codex", '{"message":"From arg","sound":"Glass"}'];
    const result = await __internal.loadCodexContext(rawArgs, json);
    expect(result?.message).toBe("From arg");
    expect(result?.sound).toBe("Glass");
  });

  it("uses stdin payload when argument and environment payloads are absent", async () => {
    process.env.CODEX_NOTIFICATION_PAYLOAD = "";
    const json = JSON.stringify({
      message: "From stdin",
      sound: "None"
    });
    const result = await __internal.loadCodexContext([], json);
    expect(result?.message).toBe("From stdin");
    expect(result?.sound).toBe("None");
  });

  it("defaults title to Codex when not provided", async () => {
    const json = JSON.stringify({ message: "Done" });
    const result = await __internal.loadCodexContext([], json);
    const expectedTitle = `Codex: ${basename(process.cwd())}`;
    expect(result?.title).toBe(expectedTitle);
  });

  it("ignores Codex payload title overrides", async () => {
    const json = JSON.stringify({ title: "Terminal", message: "Complete" });
    const result = await __internal.loadCodexContext([], json);
    const expectedTitle = `Codex: ${basename(process.cwd())}`;
    expect(result?.title).toBe(expectedTitle);
  });

  it("falls back to argument payload when stdin is empty", async () => {
    process.env.CODEX_NOTIFICATION_PAYLOAD = "";
    const rawArgs = ["--codex", '{"message":"From arg","sound":"Glass"}'];
    const result = await __internal.loadCodexContext(rawArgs, "");
    expect(result?.message).toBe("From arg");
    expect(result?.sound).toBe("Glass");
  });

  it("falls back to environment variable when neither stdin nor args provide JSON", async () => {
    process.env.CODEX_NOTIFICATION_PAYLOAD = '{"message":"From env","sound":"Ping"}';
    const result = await __internal.loadCodexContext([], "");
    expect(result?.message).toBe("From env");
    expect(result?.sound).toBe("Ping");
  });

  it("prefers environment payload over stdin input when argument payload is absent", async () => {
    process.env.CODEX_NOTIFICATION_PAYLOAD = '{"message":"From env","sound":"Ping"}';
    const result = await __internal.loadCodexContext([], '{"message":"From stdin","sound":"None"}');
    expect(result?.message).toBe("From env");
    expect(result?.sound).toBe("Ping");
  });
});

describe("loadClaudeContext", () => {
  const originalHome = process.env.HOME;

  afterEach(() => {
    if (originalHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = originalHome;
    }
  });

  it("extracts transcript message when provided", async () => {
    const tempHome = mkdtempSync(join(tmpdir(), "vde-notifier-claude-"));
    process.env.HOME = tempHome;

    try {
      const projectDir = join(tempHome, ".claude", "projects", "demo");
      mkdirSync(projectDir, { recursive: true });
      const transcriptPath = join(projectDir, "session.jsonl");
      const lines = [
        JSON.stringify({ type: "user", message: { role: "user", content: [{ text: "run tests" }] } }),
        JSON.stringify({
          type: "assistant",
          message: { role: "assistant", content: [{ text: "All tests passed" }] }
        })
      ];
      writeFileSync(transcriptPath, `${lines.join("\n")}\n`, { encoding: "utf8" });

      const payload = JSON.stringify({ transcript_path: transcriptPath, notification_title: "Claude" });
      const context = await __internal.loadClaudeContext(payload);

      expect(context?.message).toBe("All tests passed");
      expect(context?.title).toBe("Claude");
    } finally {
      rmSync(tempHome, { recursive: true, force: true });
    }
  });

  it("accepts direct notification message fields", async () => {
    const payload = JSON.stringify({ notification_message: "Claude finished", sound: "None" });
    const context = await __internal.loadClaudeContext(payload);
    expect(context?.message).toBe("Claude finished");
    expect(context?.sound).toBe("None");
  });

  it("defaults title to repository-scoped Claude label", async () => {
    const payload = JSON.stringify({ message: "Complete" });
    const context = await __internal.loadClaudeContext(payload);
    const expectedTitle = `Claude: ${basename(process.cwd())}`;
    expect(context?.title).toBe(expectedTitle);
  });
});
