import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";
import type { CliOptions, EnvironmentReport, FocusCommand, FocusPayload, TerminalProfile, TmuxContext } from "./types";
import { __internal } from "./cli";

vi.mock("execa", () => ({
  execa: vi.fn()
}));

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
const execaMock = vi.mocked(await import("execa")).execa;

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

const writeCodexSessionMeta = (homeDir: string, threadId: string, source: unknown): void => {
  const sessionsDir = join(homeDir, ".codex", "sessions", "2026", "02", "21");
  mkdirSync(sessionsDir, { recursive: true });
  const rolloutPath = join(sessionsDir, `rollout-2026-02-21T00-00-00-${threadId}.jsonl`);
  const line = JSON.stringify({
    timestamp: "2026-02-21T00:00:00.000Z",
    type: "session_meta",
    payload: {
      id: threadId,
      source
    }
  });
  writeFileSync(rolloutPath, `${line}\n`, { encoding: "utf8" });
};

beforeEach(() => {
  vi.clearAllMocks();
  resolveTmuxContextMock.mockResolvedValue(sampleTmux);
  resolveTerminalProfileMock.mockReturnValue(sampleTerminal);
  buildFocusCommandMock.mockReturnValue(focusCommand);
  parseFocusPayloadMock.mockReturnValue(samplePayload);
  execaMock.mockResolvedValue({} as Awaited<ReturnType<typeof execaMock>>);
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

  it("skips notification for codex subagent when configured", async () => {
    const originalHome = process.env.HOME;
    const tempHome = mkdtempSync(join(tmpdir(), "vde-notifier-codex-subagent-"));
    process.env.HOME = tempHome;

    try {
      const threadId = "019c0930-5842-7352-9467-e2bcc5b40908";
      writeCodexSessionMeta(tempHome, threadId, {
        subagent: {
          thread_spawn: {
            parent_thread_id: "019c086a-cfed-7cb2-8e17-12c6585f1197",
            depth: 1
          }
        }
      });
      const payload = JSON.stringify({ "thread-id": threadId, message: "From subagent" });
      const options: CliOptions = {
        mode: "notify",
        dryRun: false,
        verbose: false,
        codex: true,
        skipCodexSubagent: true,
        notifier: "terminal-notifier"
      } as CliOptions;

      const result = await __internal.runNotify(options, environmentReport, ["--codex", payload], "");

      expect(result).toBe(0);
      expect(sendNotificationMock).not.toHaveBeenCalled();
      expect(resolveTmuxContextMock).not.toHaveBeenCalled();
    } finally {
      if (originalHome === undefined) {
        delete process.env.HOME;
      } else {
        process.env.HOME = originalHome;
      }
      rmSync(tempHome, { recursive: true, force: true });
    }
  });

  it("skips notification for codex non-interactive sessions when configured", async () => {
    const originalHome = process.env.HOME;
    const tempHome = mkdtempSync(join(tmpdir(), "vde-notifier-codex-non-interactive-"));
    process.env.HOME = tempHome;

    try {
      const threadId = "019c0b18-d734-71a2-a5ec-f662e62868de";
      writeCodexSessionMeta(tempHome, threadId, "exec");
      const payload = JSON.stringify({ "thread-id": threadId, message: "From non-interactive codex" });
      const options: CliOptions = {
        mode: "notify",
        dryRun: false,
        verbose: false,
        codex: true,
        skipCodexNonInteractive: true,
        notifier: "terminal-notifier"
      } as CliOptions;

      const result = await __internal.runNotify(options, environmentReport, ["--codex", payload], "");

      expect(result).toBe(0);
      expect(sendNotificationMock).not.toHaveBeenCalled();
      expect(resolveTmuxContextMock).not.toHaveBeenCalled();
    } finally {
      if (originalHome === undefined) {
        delete process.env.HOME;
      } else {
        process.env.HOME = originalHome;
      }
      rmSync(tempHome, { recursive: true, force: true });
    }
  });

  it("skips notification for claude non-interactive payloads when configured", async () => {
    const payload = JSON.stringify({
      type: "result",
      subtype: "success",
      result: "Hi",
      session_id: "f4d9b71a-163f-4c3f-a921-e0f46a511c9a"
    });
    const options: CliOptions = {
      mode: "notify",
      dryRun: false,
      verbose: false,
      claude: true,
      skipClaudeNonInteractive: true,
      notifier: "terminal-notifier"
    } as CliOptions;

    const result = await __internal.runNotify(options, environmentReport, ["--claude"], payload);

    expect(result).toBe(0);
    expect(sendNotificationMock).not.toHaveBeenCalled();
    expect(resolveTmuxContextMock).not.toHaveBeenCalled();
  });

  it("forwards post-separator command with payload after sending notification", async () => {
    const payload = JSON.stringify({ message: "From forwarded payload", sound: "Glass" });
    const options: CliOptions = {
      mode: "notify",
      dryRun: false,
      verbose: false,
      codex: true,
      notifier: "terminal-notifier"
    } as CliOptions;

    const result = await __internal.runNotify(
      options,
      environmentReport,
      ["--codex", "--", "other-command", payload],
      ""
    );

    expect(result).toBe(0);
    expect(sendNotificationMock).toHaveBeenCalledWith(expect.objectContaining({ message: "From forwarded payload" }));
    expect(execaMock).toHaveBeenCalledWith("other-command", [payload], { stdio: "inherit" });
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

  it("enables codex subagent skip flag", () => {
    const options = __internal.parseArguments(["--skip-codex-subagent"]);
    expect(options.skipCodexSubagent).toBe(true);
  });

  it("enables codex non-interactive skip flag", () => {
    const options = __internal.parseArguments(["--skip-codex-non-interactive"]);
    expect(options.skipCodexNonInteractive).toBe(true);
  });

  it("enables claude non-interactive skip flag", () => {
    const options = __internal.parseArguments(["--skip-claude-non-interactive"]);
    expect(options.skipClaudeNonInteractive).toBe(true);
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
    expect(usage).toContain("-- <command> [args...]");
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

  it("extracts payload argument from forwarded command chain", async () => {
    const payload = '{"message":"From forwarded args","sound":"Ping"}';
    const result = await __internal.loadCodexContext(["--codex", "--", "other-command", payload], "");
    expect(result?.message).toBe("From forwarded args");
    expect(result?.sound).toBe("Ping");
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

  it("throws on invalid codex JSON payload", async () => {
    await expect(__internal.loadCodexContext(["--codex", "{not-json}"], "")).rejects.toThrow(
      "Failed to parse Codex payload JSON:"
    );
  });

  it("detects subagent thread id from codex sessions metadata", async () => {
    const originalHome = process.env.HOME;
    const tempHome = mkdtempSync(join(tmpdir(), "vde-notifier-codex-context-"));
    process.env.HOME = tempHome;

    try {
      const threadId = "019bbab9-b980-7450-b179-4ce8ce6743b9";
      writeCodexSessionMeta(tempHome, threadId, { subagent: "review" });
      const payload = JSON.stringify({ "thread-id": threadId, message: "From subagent" });
      const context = await __internal.loadCodexContext(["--codex", payload], "");
      expect(context?.threadId).toBe(threadId);
      expect(context?.isSubagent).toBe(true);
    } finally {
      if (originalHome === undefined) {
        delete process.env.HOME;
      } else {
        process.env.HOME = originalHome;
      }
      rmSync(tempHome, { recursive: true, force: true });
    }
  });

  it("detects non-interactive codex thread from sessions metadata", async () => {
    const originalHome = process.env.HOME;
    const tempHome = mkdtempSync(join(tmpdir(), "vde-notifier-codex-non-interactive-context-"));
    process.env.HOME = tempHome;

    try {
      const threadId = "019c0b18-d734-71a2-a5ec-f662e62868de";
      writeCodexSessionMeta(tempHome, threadId, "exec");
      const payload = JSON.stringify({ "thread-id": threadId, message: "From non-interactive codex" });
      const context = await __internal.loadCodexContext(["--codex", payload], "");
      expect(context?.threadId).toBe(threadId);
      expect(context?.isNonInteractive).toBe(true);
    } finally {
      if (originalHome === undefined) {
        delete process.env.HOME;
      } else {
        process.env.HOME = originalHome;
      }
      rmSync(tempHome, { recursive: true, force: true });
    }
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

  it("throws on invalid Claude payload JSON", async () => {
    await expect(__internal.loadClaudeContext("{not-json}")).rejects.toThrow("Failed to parse Claude payload JSON:");
  });

  it("detects claude non-interactive payload", async () => {
    const payload = JSON.stringify({
      type: "result",
      subtype: "success",
      result: "Hi, how can I help you today?",
      session_id: "f4d9b71a-163f-4c3f-a921-e0f46a511c9a"
    });

    const context = await __internal.loadClaudeContext(payload);
    expect(context?.isNonInteractive).toBe(true);
  });
});
