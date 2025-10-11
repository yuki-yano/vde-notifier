import { describe, expect, it } from "vitest";
import { __internal } from "../../notify/send.js";

const { buildArgs } = __internal;

describe("notification sounds", () => {
  it("defaults to Glass", () => {
    const args = buildArgs({
      notifierPath: "/opt/path/terminal-notifier",
      title: "test",
      message: "done",
      executeCommand: "echo"
    });
    expect(args).toContain("Glass");
  });

  it("respects explicit sound", () => {
    const args = buildArgs({
      notifierPath: "/opt/path/terminal-notifier",
      title: "test",
      message: "done",
      executeCommand: "echo",
      sound: "Ping"
    });
    expect(args).toContain("Ping");
  });

  it("skips sound when None is provided", () => {
    const args = buildArgs({
      notifierPath: "/opt/path/terminal-notifier",
      title: "test",
      message: "done",
      executeCommand: "echo",
      sound: "None"
    });
    expect(args).not.toContain("-sound");
  });
});
