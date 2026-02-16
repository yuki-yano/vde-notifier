import { describe, expect, it } from "vitest";
import { __internal } from "../notify/send";

const { buildTerminalNotifierArgs } = __internal;

const focusCommand = {
  command: "node dist/index.js --mode focus",
  args: ["dist/index.js", "--mode", "focus"],
  executable: process.execPath,
  payload: "encoded"
};

describe("notification sounds", () => {
  it("defaults to Glass", () => {
    const args = buildTerminalNotifierArgs({
      notifierKind: "terminal-notifier",
      notifierPath: "/opt/path/terminal-notifier",
      title: "test",
      message: "done",
      focusCommand
    });
    expect(args).toContain("Glass");
  });

  it("respects explicit sound", () => {
    const args = buildTerminalNotifierArgs({
      notifierKind: "terminal-notifier",
      notifierPath: "/opt/path/terminal-notifier",
      title: "test",
      message: "done",
      focusCommand,
      sound: "Ping"
    });
    expect(args).toContain("Ping");
  });

  it("skips sound when None is provided", () => {
    const args = buildTerminalNotifierArgs({
      notifierKind: "terminal-notifier",
      notifierPath: "/opt/path/terminal-notifier",
      title: "test",
      message: "done",
      focusCommand,
      sound: "None"
    });
    expect(args).not.toContain("-sound");
  });
});
