const readStdin = async () => {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(typeof chunk === "string" ? chunk : chunk.toString("utf8"));
  }
  return chunks.join("").trim();
};

const parsePackOutput = (raw) => {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`Failed to parse npm pack JSON output: ${error instanceof Error ? error.message : String(error)}`);
  }

  if (!Array.isArray(parsed) || parsed.length === 0) {
    throw new Error("npm pack JSON output did not include package metadata.");
  }

  return parsed[0];
};

const toFileMap = (pack) => {
  if (!Array.isArray(pack.files)) {
    throw new Error("npm pack JSON output did not include a files array.");
  }
  return new Map(pack.files.map((file) => [file.path, file]));
};

const assertRequiredFiles = (fileMap, requiredPaths) => {
  for (const requiredPath of requiredPaths) {
    if (!fileMap.has(requiredPath)) {
      throw new Error(`npm package is missing required file: ${requiredPath}`);
    }
  }
};

const assertExecutableBin = (fileMap, path) => {
  const file = fileMap.get(path);
  if (file === undefined || typeof file.mode !== "number") {
    throw new Error(`Unable to verify mode for ${path}`);
  }
  if ((file.mode & 0o111) === 0) {
    throw new Error(`CLI entrypoint is not executable in npm tarball: ${path} (mode=${file.mode})`);
  }
};

const assertNoUnexpectedSources = (pack, disallowedPrefixes) => {
  const leaked = pack.files
    .map((file) => file.path)
    .filter((path) => disallowedPrefixes.some((prefix) => path.startsWith(prefix)));

  if (leaked.length > 0) {
    throw new Error(`npm tarball includes unexpected source/control files: ${leaked.join(", ")}`);
  }
};

const main = async () => {
  const raw = await readStdin();
  if (raw.length === 0) {
    throw new Error("Received empty output from npm pack.");
  }

  const pack = parsePackOutput(raw);
  const fileMap = toFileMap(pack);

  assertRequiredFiles(fileMap, ["package.json", "README.md", "LICENSE", "dist/cli.js"]);
  assertExecutableBin(fileMap, "dist/cli.js");
  assertNoUnexpectedSources(pack, ["src/", "app/", ".github/", ".agents/", "tmp/"]);

  console.log(`npm pack check passed: ${pack.name}@${pack.version} (${pack.entryCount} files)`);
};

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(message);
  process.exit(1);
});
