import { beforeEach, describe, expect, it, vi } from "vitest";
import { sendNotification, __internal } from "../send.js";

vi.mock("execa", () => ({
  execa: vi.fn()
}));

import { execa } from "execa";

const execaMock = vi.mocked(execa);

describe("sendNotification", () => {
  beforeEach(() => {
    execaMock.mockReset();
    execaMock.mockResolvedValue({} as unknown as Awaited<ReturnType<typeof execa>>);
  });

  it("executes terminal-notifier with computed args", async () => {
    await sendNotification({
      notifierPath: "/opt/homebrew/bin/terminal-notifier",
      title: "Done",
      message: "Build finished",
      executeCommand: "focus-command",
      sound: "Ping"
    });

    expect(execaMock).toHaveBeenCalledWith("/opt/homebrew/bin/terminal-notifier", [
      "-title",
      "Done",
      "-message",
      "Build finished",
      "-execute",
      "focus-command",
      "-sound",
      "Ping"
    ]);
  });

  it("truncates long messages before sending", async () => {
    const longMessage = "x".repeat(__internal.MAX_MESSAGE_LENGTH + 10);

    await sendNotification({
      notifierPath: "/opt/homebrew/bin/terminal-notifier",
      title: "Done",
      message: longMessage,
      executeCommand: "focus-command",
      sound: "Ping"
    });

    const args = execaMock.mock.calls[0][1] as string[];
    expect(args[3]).toHaveLength(__internal.MAX_MESSAGE_LENGTH);
    expect(args[3]).toBe(longMessage.slice(0, __internal.MAX_MESSAGE_LENGTH));
  });

  it("omits sound flag when None is requested", async () => {
    await sendNotification({
      notifierPath: "/opt/homebrew/bin/terminal-notifier",
      title: "Done",
      message: "Build finished",
      executeCommand: "focus-command",
      sound: "None"
    });

    const args = execaMock.mock.calls[0][1] as string[];
    expect(args).not.toContain("-sound");
  });
});
