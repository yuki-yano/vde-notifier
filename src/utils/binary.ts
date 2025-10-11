import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { delimiter, isAbsolute, join } from "node:path";
import { env } from "node:process";

const isExecutable = async (absolutePath: string): Promise<boolean> => {
  try {
    await access(absolutePath, constants.X_OK);
    return true;
  } catch {
    return false;
  }
};

const resolveFromPath = async (command: string): Promise<string | undefined> => {
  const { PATH } = env;
  if (typeof PATH !== "string" || PATH.length === 0) {
    return undefined;
  }

  const segments = PATH.split(delimiter);
  for (const segment of segments) {
    if (segment.length === 0) {
      continue;
    }
    const candidate = join(segment, command);
    const executable = await isExecutable(candidate);
    if (executable) {
      return candidate;
    }
  }
  return undefined;
};

export const ensureBinary = async (command: string, explicitPath?: string): Promise<string> => {
  if (typeof explicitPath === "string" && explicitPath.length > 0) {
    if (!isAbsolute(explicitPath)) {
      throw new Error(`The given path must be absolute: ${explicitPath}`);
    }
    const executable = await isExecutable(explicitPath);
    if (!executable) {
      throw new Error(`Command is not executable: ${explicitPath}`);
    }
    return explicitPath;
  }

  const resolved = await resolveFromPath(command);
  if (resolved === undefined) {
    throw new Error(`Unable to locate command on PATH: ${command}`);
  }
  return resolved;
};
