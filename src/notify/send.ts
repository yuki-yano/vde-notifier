import { execa } from "execa";
import type { NotificationOptions } from "../types.js";

const DEFAULT_SOUND = "Glass";
const MAX_MESSAGE_LENGTH = 100;
const SWIFT_DIALOG_BUTTON_TEXT = "Return to pane";

const truncateMessage = (value: string): string =>
  value.length > MAX_MESSAGE_LENGTH ? value.slice(0, MAX_MESSAGE_LENGTH) : value;

const buildTerminalNotifierArgs = ({ title, message, focusCommand, sound }: NotificationOptions): string[] => {
  const args = ["-title", title, "-message", truncateMessage(message), "-execute", focusCommand.command];

  const resolvedSound = sound ?? DEFAULT_SOUND;

  if (resolvedSound.toLowerCase() !== "none") {
    args.push("-sound", resolvedSound);
  }

  return args;
};

const buildSwiftDialogArgs = ({ title, message, focusCommand }: NotificationOptions): string[] => [
  "--notification",
  "--title",
  title,
  "--message",
  truncateMessage(message),
  "--button1text",
  SWIFT_DIALOG_BUTTON_TEXT,
  "--button1action",
  focusCommand.command
];

const sendViaTerminalNotifier = async (options: NotificationOptions): Promise<void> => {
  const args = buildTerminalNotifierArgs(options);
  await execa(options.notifierPath, args);
};

const sendViaSwiftDialog = async (options: NotificationOptions): Promise<void> => {
  const args = buildSwiftDialogArgs(options);
  await execa(options.notifierPath, args);
};

export const sendNotification = async (options: NotificationOptions): Promise<void> => {
  if (options.notifierKind === "swiftdialog") {
    await sendViaSwiftDialog(options);
    return;
  }

  await sendViaTerminalNotifier(options);
};

export const __internal = {
  buildTerminalNotifierArgs,
  buildSwiftDialogArgs,
  sendViaSwiftDialog,
  sendViaTerminalNotifier,
  DEFAULT_SOUND,
  MAX_MESSAGE_LENGTH,
  SWIFT_DIALOG_BUTTON_TEXT,
  truncateMessage
};
