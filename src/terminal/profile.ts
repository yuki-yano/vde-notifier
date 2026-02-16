import { execa } from "execa";
import type { TerminalProfile } from "../types.js";

const PROFILE_CATALOG: Record<string, { name: string; bundleId: string; aliases: readonly string[] }> = {
  terminal: {
    name: "Terminal.app",
    bundleId: "com.apple.Terminal",
    aliases: ["terminal", "apple-terminal", "mac-terminal"]
  },
  iterm: {
    name: "iTerm2",
    bundleId: "com.googlecode.iterm2",
    aliases: ["iterm", "iterm2"]
  },
  alacritty: {
    name: "Alacritty",
    bundleId: "org.alacritty",
    aliases: ["alacritty"]
  },
  kitty: {
    name: "kitty",
    bundleId: "net.kovidgoyal.kitty",
    aliases: ["kitty"]
  },
  wezterm: {
    name: "WezTerm",
    bundleId: "com.github.wez.wezterm",
    aliases: ["wezterm"]
  },
  hyper: {
    name: "Hyper",
    bundleId: "co.zeit.hyper",
    aliases: ["hyper"]
  },
  ghostty: {
    name: "Ghostty",
    bundleId: "com.mitchellh.ghostty",
    aliases: ["ghostty"]
  }
};

const DEFAULT_KEY = "terminal";

const normalize = (value: string): string => value.trim().toLowerCase();

const findByAlias = (value: string): string | undefined => {
  const normalized = normalize(value);
  const entry = Object.entries(PROFILE_CATALOG).find(([, descriptor]) =>
    descriptor.aliases.some((alias) => alias === normalized)
  );
  return entry?.[0];
};

const findByBundleId = (bundleId: string): string | undefined => {
  const normalized = bundleId.trim().toLowerCase();
  const entry = Object.entries(PROFILE_CATALOG).find(
    ([, descriptor]) => descriptor.bundleId.toLowerCase() === normalized
  );
  return entry?.[0];
};

type ResolveInput = {
  readonly explicitKey?: string;
  readonly bundleOverride?: string;
  readonly env?: NodeJS.ProcessEnv;
};

const detectFromEnv = (env?: NodeJS.ProcessEnv): string | undefined => {
  if (env === undefined || env === null) {
    return undefined;
  }
  const candidates = [env.CA_TERM, env.TERM_PROGRAM, env.TERM];
  for (const candidate of candidates) {
    if (typeof candidate !== "string" || candidate.length === 0) {
      continue;
    }
    const match = findByAlias(candidate);
    if (match !== undefined) {
      return match;
    }
  }
  return undefined;
};

const buildProfile = (key: string, source: TerminalProfile["source"]): TerminalProfile => {
  const descriptor = PROFILE_CATALOG[key] ?? PROFILE_CATALOG[DEFAULT_KEY];
  return {
    key,
    name: descriptor.name,
    bundleId: descriptor.bundleId,
    source
  };
};

export const resolveTerminalProfile = ({ explicitKey, bundleOverride, env }: ResolveInput): TerminalProfile => {
  if (typeof bundleOverride === "string" && bundleOverride.length > 0) {
    const byBundle = findByBundleId(bundleOverride);
    if (byBundle !== undefined) {
      return buildProfile(byBundle, "override");
    }
    return {
      key: "custom",
      name: bundleOverride,
      bundleId: bundleOverride,
      source: "override"
    };
  }

  if (typeof explicitKey === "string" && explicitKey.length > 0) {
    const byAlias = findByAlias(explicitKey);
    if (byAlias !== undefined) {
      return buildProfile(byAlias, "override");
    }

    const byBundle = findByBundleId(explicitKey);
    if (byBundle !== undefined) {
      return buildProfile(byBundle, "override");
    }

    return {
      key: "custom",
      name: explicitKey,
      bundleId: explicitKey,
      source: "override"
    };
  }

  const detected = detectFromEnv(env);
  if (typeof detected === "string" && detected.length > 0) {
    return buildProfile(detected, "env");
  }

  return buildProfile(DEFAULT_KEY, "default");
};

const buildFrontmostScript = (bundleId: string): string => `
tell application "System Events"
  try
    if name of processes contains "NotificationCenter" then
      tell process "NotificationCenter" to set frontmost to false
    end if
  end try
  repeat with proc in processes
    try
      if bundle identifier of proc is "${bundleId}" then
        set frontmost of proc to true
        exit repeat
      end if
    end try
  end repeat
end tell
`;

export const activateTerminal = async (bundleId: string): Promise<void> => {
  let primarySucceeded = false;

  try {
    await execa("/usr/bin/osascript", ["-e", `tell application id "${bundleId}" to activate`]);
    primarySucceeded = true;
  } catch {
    /* ignore – fall back to frontmost script */
  }

  try {
    await execa("/usr/bin/osascript", ["-e", buildFrontmostScript(bundleId)]);
  } catch (error) {
    if (!primarySucceeded) {
      throw error;
    }
  }
};

export const __internal = {
  buildFrontmostScript
};
