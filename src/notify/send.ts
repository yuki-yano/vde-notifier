import { execa } from "execa";
import type { NotificationOptions } from "../types.js";

const DEFAULT_SOUND = "Glass";
const MAX_MESSAGE_LENGTH = 100;

const truncateMessage = (value: string): string =>
  value.length > MAX_MESSAGE_LENGTH ? value.slice(0, MAX_MESSAGE_LENGTH) : value;

const buildArgs = ({ title, message, executeCommand, sound }: NotificationOptions): string[] => {
  const args = ["-title", title, "-message", truncateMessage(message), "-execute", executeCommand];

  const resolvedSound = sound ?? DEFAULT_SOUND;

  if (resolvedSound.toLowerCase() !== "none") {
    args.push("-sound", resolvedSound);
  }

  return args;
};

export const sendNotification = async (options: NotificationOptions): Promise<void> => {
  const args = buildArgs(options);
  await execa(options.notifierPath, args);
};

export const __internal = {
  buildArgs,
  DEFAULT_SOUND,
  MAX_MESSAGE_LENGTH
};
