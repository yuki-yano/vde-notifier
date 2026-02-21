export type CliMode = "notify" | "focus";

export type NotifierKind = "terminal-notifier" | "swiftdialog" | "vde-notifier-app";

export type CliOptions = {
  readonly mode: CliMode;
  readonly title?: string;
  readonly message?: string;
  readonly terminal?: string;
  readonly termBundleId?: string;
  readonly sound?: string;
  readonly notifier: NotifierKind;
  readonly codex: boolean;
  readonly skipCodexSubagent: boolean;
  readonly claude: boolean;
  readonly dryRun: boolean;
  readonly verbose: boolean;
  readonly logFile?: string;
  readonly payload?: string;
};

export type RuntimeInfo = {
  readonly nodeVersion?: string;
  readonly bunVersion?: string;
};

export type BinaryReport = {
  readonly tmux: string;
  readonly notifier: string;
  readonly notifierKind: NotifierKind;
  readonly osascript: string;
};

export type EnvironmentReport = {
  readonly runtime: RuntimeInfo;
  readonly binaries: BinaryReport;
};

export type TmuxContext = {
  readonly tmuxBin: string;
  readonly socketPath: string;
  readonly clientTTY: string;
  readonly sessionName: string;
  readonly windowId: string;
  readonly windowIndex: number;
  readonly paneId: string;
  readonly paneIndex: number;
  readonly paneCurrentCommand: string;
};

export type TerminalProfile = {
  readonly key: string;
  readonly name: string;
  readonly bundleId: string;
  readonly source: "override" | "env" | "default";
};

export type FocusPayload = {
  readonly tmux: TmuxContext;
  readonly terminal: TerminalProfile;
};

export type NotificationContent = {
  readonly title: string;
  readonly message: string;
  readonly sound?: string;
};

export type FocusCommand = {
  readonly command: string;
  readonly args: readonly string[];
  readonly executable: string;
  readonly payload: string;
};

export type NotificationOptions = {
  readonly title: string;
  readonly message: string;
  readonly notifierKind: NotifierKind;
  readonly notifierPath: string;
  readonly focusCommand: FocusCommand;
  readonly sound?: string;
};
