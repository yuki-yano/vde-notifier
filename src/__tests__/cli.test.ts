import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";
import type {
  CliOptions,
  EnvironmentReport,
  FocusCommand,
  FocusPayload,
  TerminalProfile,
  TmuxContext
} from "../types.js";
import { __internal } from "../cli.js";

vi.mock("../tmux/query.js", () => ({
  resolveTmuxContext: vi.fn()
}));

vi.mock("../terminal/profile.js", () => ({
  resolveTerminalProfile: vi.fn(),
  activateTerminal: vi.fn()
}));

vi.mock("../notify/send.js", () => ({
  sendNotification: vi.fn()
}));

vi.mock("../utils/payload.js", () => ({
  buildFocusCommand: vi.fn(),
  parseFocusPayload: vi.fn()
}));

vi.mock("../tmux/control.js", () => ({
  focusPane: vi.fn()
}));

const resolveTmuxContextMock = vi.mocked(await import("../tmux/query.js")).resolveTmuxContext;
const resolveTerminalProfileMock = vi.mocked(await import("../terminal/profile.js")).resolveTerminalProfile;
const activateTerminalMock = vi.mocked(await import("../terminal/profile.js")).activateTerminal;
const sendNotificationMock = vi.mocked(await import("../notify/send.js")).sendNotification;
const buildFocusCommandMock = vi.mocked(await import("../utils/payload.js")).buildFocusCommand;
const parseFocusPayloadMock = vi.mocked(await import("../utils/payload.js")).parseFocusPayload;
const focusPaneMock = vi.mocked(await import("../tmux/control.js")).focusPane;

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
  payload: "encoded"
};

const environmentReport: EnvironmentReport = {
  runtime: {
    nodeVersion: "22.0.0"
  },
  binaries: {
    tmux: sampleTmux.tmuxBin,
    terminalNotifier: "/opt/homebrew/bin/terminal-notifier",
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
      codex: false
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
      codex: false
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
      codex: false
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
      codex: false
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
      codex: false
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
      codex: true
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
      codex: true
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
      claude: false
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

  it("enables Claude mode flag", () => {
    const options = __internal.parseArguments(["--claude"]);
    expect(options.claude).toBe(true);
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
  it("prefers stdin payload over arguments", async () => {
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
