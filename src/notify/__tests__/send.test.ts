import { beforeEach, describe, expect, it, vi } from "vitest";
import { sendNotification } from "../send.js";

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
