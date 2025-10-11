import { defineConfig } from "tsdown";

export default defineConfig({
  entry: ["src/cli.ts"],
  format: ["esm"],
  target: ["es2022"],
  outDir: "dist",
  splitting: false,
  clean: true,
  dts: false
});
