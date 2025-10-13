import { execa } from "execa";
import type { NotificationOptions } from "../types.js";

const DEFAULT_SOUND = "Glass";
const MAX_MESSAGE_LENGTH = 100;
const SWIFT_DIALOG_BUTTON_TEXT = "Return to pane";
const SWIFT_DIALOG_SOUND_PLAYER = "afplay";
const SYSTEM_SOUND_DIRECTORY = "/System/Library/Sounds";
const SOUND_RESOURCE_EXTENSION = ".aiff";

const truncateMessage = (value: string): string =>
  value.length > MAX_MESSAGE_LENGTH ? value.slice(0, MAX_MESSAGE_LENGTH) : value;

const resolveSoundRequest = (sound?: string): string | undefined => {
  const candidate = (sound ?? DEFAULT_SOUND).trim();

  if (candidate === "") {
    return undefined;
  }

  if (candidate.toLowerCase() === "none") {
    return undefined;
  }

  return candidate;
};

const resolveSoundResource = (sound: string): string => {
  if (sound.includes("/") || sound.includes(".")) {
    return sound;
  }

  return `${SYSTEM_SOUND_DIRECTORY}/${sound}${SOUND_RESOURCE_EXTENSION}`;
};

const playSoundRequest = async (sound?: string): Promise<void> => {
  const resolvedSound = resolveSoundRequest(sound);

  if (resolvedSound === undefined) {
    return;
  }

  const resource = resolveSoundResource(resolvedSound);

  try {
    await execa(SWIFT_DIALOG_SOUND_PLAYER, [resource]);
  } catch {
    // 音再生が失敗しても通知送信は継続する
  }
};

const buildTerminalNotifierArgs = ({ title, message, focusCommand, sound }: NotificationOptions): string[] => {
  const args = ["-title", title, "-message", truncateMessage(message), "-execute", focusCommand.command];

  const resolvedSound = resolveSoundRequest(sound);

  if (resolvedSound !== undefined) {
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
  await playSoundRequest(options.sound);
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
  SWIFT_DIALOG_SOUND_PLAYER,
  resolveSoundRequest,
  resolveSoundResource,
  playSoundRequest,
  truncateMessage
};
