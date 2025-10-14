import { describe, expect, it } from "vitest";
import { buildFocusCommand, parseFocusPayload } from "../payload.js";
import type { FocusPayload } from "../../types.js";

describe("focus command payload", () => {
  const samplePayload: FocusPayload = {
    tmux: {
      tmuxBin: "/opt/homebrew/bin/tmux",
      socketPath: "/tmp/tmux-501/default",
      clientTTY: "/dev/ttys012",
      sessionName: "dev",
      windowId: "@1",
      windowIndex: 1,
      paneId: "%5",
      paneIndex: 0,
      paneCurrentCommand: "node"
    },
    terminal: {
      key: "alacritty",
      name: "Alacritty",
      bundleId: "org.alacritty",
      source: "default"
    }
  };

  it("serializes and parses payload", () => {
    const command = buildFocusCommand(samplePayload);
    const decoded = parseFocusPayload(command.payload);
    expect(decoded).toEqual(samplePayload);
    expect(command.executable).toBe(process.execPath);
  });

  it("includes verbose flag when requested", () => {
    const command = buildFocusCommand(samplePayload, { verbose: true });
    expect(command.args).toContain("--verbose");
  });

  it("includes log file when provided", () => {
    const logPath = "/tmp/vde-notifier.log";
    const command = buildFocusCommand(samplePayload, { logFile: logPath });
    expect(command.args).toContain("--log-file");
    expect(command.args).toContain(logPath);
  });
});
