import { beforeEach, describe, expect, it, vi } from "vitest";
import { sendNotification, __internal } from "../send.js";

vi.mock("execa", () => ({
  execa: vi.fn()
}));

import { execa } from "execa";

const execaMock = vi.mocked(execa);

const focusCommand = {
  command: "'/usr/local/bin/node' '/opt/homebrew/bin/vde-notifier' --mode focus",
  executable: "/usr/local/bin/node",
  args: ["/opt/homebrew/bin/vde-notifier", "--mode", "focus"],
  payload: "encoded"
};

describe("sendNotification", () => {
  beforeEach(() => {
    execaMock.mockReset();
    execaMock.mockResolvedValue({ exitCode: 0 } as unknown as Awaited<ReturnType<typeof execa>>);
  });

  it("executes terminal-notifier with computed args", async () => {
    await sendNotification({
      notifierKind: "terminal-notifier",
      notifierPath: "/opt/homebrew/bin/terminal-notifier",
      title: "Done",
      message: "Build finished",
      focusCommand,
      sound: "Ping"
    });

    expect(execaMock).toHaveBeenCalledWith("/opt/homebrew/bin/terminal-notifier", [
      "-title",
      "Done",
      "-message",
      "Build finished",
      "-execute",
      focusCommand.command,
      "-sound",
      "Ping"
    ]);
    expect(execaMock).toHaveBeenCalledTimes(1);
  });

  it("truncates long messages before sending", async () => {
    const longMessage = "x".repeat(__internal.MAX_MESSAGE_LENGTH + 10);

    await sendNotification({
      notifierKind: "terminal-notifier",
      notifierPath: "/opt/homebrew/bin/terminal-notifier",
      title: "Done",
      message: longMessage,
      focusCommand,
      sound: "Ping"
    });

    const args = execaMock.mock.calls[0][1] as string[];
    expect(args[3]).toHaveLength(__internal.MAX_MESSAGE_LENGTH);
    expect(args[3]).toBe(longMessage.slice(0, __internal.MAX_MESSAGE_LENGTH));
  });

  it("omits sound flag when None is requested", async () => {
    await sendNotification({
      notifierKind: "terminal-notifier",
      notifierPath: "/opt/homebrew/bin/terminal-notifier",
      title: "Done",
      message: "Build finished",
      focusCommand,
      sound: "None"
    });

    const args = execaMock.mock.calls[0][1] as string[];
    expect(args).not.toContain("-sound");
  });

  it("runs swiftDialog notification with focus action", async () => {
    await sendNotification({
      notifierKind: "swiftdialog",
      notifierPath: "/usr/local/bin/dialog",
      title: "Done",
      message: "Build finished",
      focusCommand,
      sound: "Ping"
    });

    expect(execaMock).toHaveBeenCalledTimes(2);

    const [soundCommand, soundArgs] = execaMock.mock.calls[0];
    expect(soundCommand).toBe(__internal.SWIFT_DIALOG_SOUND_PLAYER);
    expect(soundArgs).toEqual([__internal.resolveSoundResource("Ping")]);

    const [command, args] = execaMock.mock.calls[1];
    expect(command).toBe("/usr/local/bin/dialog");
    expect(args).toEqual(
      expect.arrayContaining([
        "--notification",
        "--title",
        "Done",
        "--message",
        "Build finished",
        "--button1text",
        __internal.SWIFT_DIALOG_BUTTON_TEXT,
        "--button1action",
        focusCommand.command
      ])
    );
  });

  it("skips playing sound for swiftDialog when None is requested", async () => {
    await sendNotification({
      notifierKind: "swiftdialog",
      notifierPath: "/usr/local/bin/dialog",
      title: "Done",
      message: "Build finished",
      focusCommand,
      sound: "none"
    });

    expect(execaMock).toHaveBeenCalledTimes(1);
    const [command] = execaMock.mock.calls[0];
    expect(command).toBe("/usr/local/bin/dialog");
  });

  it("adds a leading space when message starts with hyphen for terminal-notifier", () => {
    const args = __internal.buildTerminalNotifierArgs({
      notifierKind: "terminal-notifier",
      notifierPath: "/opt/homebrew/bin/terminal-notifier",
      title: "Done",
      message: "- bullet",
      focusCommand,
      sound: undefined
    });

    const messageIndex = args.indexOf("-message") + 1;
    expect(args[messageIndex]).toBe(" - bullet");
  });

  it("adds a leading space when message starts with hyphen for swiftDialog", () => {
    const args = __internal.buildSwiftDialogArgs({
      notifierKind: "swiftdialog",
      notifierPath: "/usr/local/bin/dialog",
      title: "Done",
      message: "- bullet",
      focusCommand,
      sound: undefined
    });

    const messageIndex = args.indexOf("--message") + 1;
    expect(args[messageIndex]).toBe(" - bullet");
  });
});
