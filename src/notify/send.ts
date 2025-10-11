import { execa } from "execa";
import type { NotificationOptions } from "../types.js";

const DEFAULT_SOUND = "Glass";

const buildArgs = ({ title, message, executeCommand, sound }: NotificationOptions): string[] => {
  const args = ["-title", title, "-message", message, "-execute", executeCommand];

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
  DEFAULT_SOUND
};
